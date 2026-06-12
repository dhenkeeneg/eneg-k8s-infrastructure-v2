# Runbook: Registry (Zot) CA-Bundle fuer NAS20 bauen

**Kategorie:** Registry / TLS / S3-Migration
**Erstellt:** 12.06.2026 (Phase 14a, Zot-Cutover NAS10 -> NAS20)
**Stichworte:** Zot, S3-Driver, SSL_CERT_FILE, kombiniertes CA-Bundle, Sectigo, Leaf-only

---

## Wann dieses Runbook?

- Zot-Registry-Cutover auf NAS20 in einer neuen Umgebung (TEST/PROD)
- Erneuerung des Wildcard-Zertifikats *.eneg.de (Ablauf 12.09.2026) -> Bundle neu bauen
- Zot-Pods zeigen nach Cutover x509-Fehler beim S3-Zugriff ODER bei Sync-Upstreams

## Hintergrund (warum ein kombiniertes Bundle?)

Der Zot S3-Storage-Driver (distribution/distribution, Go) kennt KEIN `ca_file`-Feld
- nur `secure` (HTTPS an/aus) und `skipverify`. Fuer verifiziertes TLS muss das
CA-Bundle ueber Gos `SSL_CERT_FILE` eingebunden werden.

WICHTIG: `SSL_CERT_FILE` ERSETZT den System-Trust-Store (Go-Verhalten, siehe
crypto/x509/root_unix.go: "If set this overrides the system default"). Es ist
NICHT additiv. Daher MUSS das Bundle BEIDES enthalten:
1. System-CAs (oeffentliche Roots) - fuer die Sync-Upstreams docker.io, quay.io,
   ghcr.io, registry.k8s.io (alle mit tlsVerify:true)
2. Sectigo-Kette (Intermediate DV R36 + Root R46) - fuer NAS20, da QuObjects auf
   8010 nur das Leaf-Zert sendet (kein AIA-Fetching im Go-Client)

Ein Bundle nur mit Sectigo wuerde die Sync-Upstreams brechen.
Ein Bundle nur mit System-CAs wuerde NAS20 brechen (Leaf-only).

## Voraussetzungen

- kubectl-Zugriff (Kontext k8s-<env>)
- Sectigo-Bundle (R36 + R46) auf mgmt-10 unter /tmp/nas20-ca-bundle.pem
  (oder neu von crt.sectigo.com: SectigoPublicServerAuthenticationCADVR36 + RootR46)
- Cluster-Egress fuer apt im Test-Pod (Debian zieht ca-certificates nach)

---

## Schritt 1 - System-CA-Bundle extrahieren

Debian-slim hat ca-certificates NICHT vorinstalliert -> Pod starten, nachinstallieren.

```bash
kubectl --context k8s-<env> -n registry run ca-build --restart=Never \
  --image=debian:13-slim --command -- sleep 1800
kubectl --context k8s-<env> -n registry wait --for=condition=Ready pod/ca-build --timeout=60s

kubectl --context k8s-<env> -n registry exec ca-build -- sh -c \
  'apt-get update -qq && apt-get install -y -qq ca-certificates openssl >/dev/null 2>&1 && \
   grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt'
# Erwartet: ~140-150
```

Bundle herauskopieren (kubectl cp, NICHT Stdout-Streaming - das ist unzuverlaessig):

```bash
kubectl --context k8s-<env> -n registry cp ca-build:/etc/ssl/certs/ca-certificates.crt /tmp/system-ca.crt
grep -c "BEGIN CERTIFICATE" /tmp/system-ca.crt
```

## Schritt 2 - Kombiniertes Bundle bauen

```bash
# Sectigo-Kette pruefen (erwartet: 2)
grep -c "BEGIN CERTIFICATE" /tmp/nas20-ca-bundle.pem

# Kombinieren: System-CAs + Sectigo
cat /tmp/system-ca.crt /tmp/nas20-ca-bundle.pem > /tmp/combined-ca.crt
grep -c "BEGIN CERTIFICATE" /tmp/combined-ca.crt
# Erwartet: System-Zahl + 2 (z.B. 152)
```

## Schritt 3 - Beide Verify-Pfade testen (PFLICHT vor Cutover)

Bundle in den Pod kopieren und mit openssl gegen BEIDE Anforderungen pruefen:

```bash
kubectl --context k8s-<env> -n registry cp /tmp/combined-ca.crt ca-build:/tmp/combined-ca.crt

# Test 1: NAS20 (braucht Sectigo-Teil)
kubectl --context k8s-<env> -n registry exec ca-build -- sh -c \
  'echo | openssl s_client -connect nas20.eneg.de:8010 -servername nas20.eneg.de \
   -CAfile /tmp/combined-ca.crt 2>/dev/null | grep "Verify return code"'

# Test 2: ghcr.io (braucht System-Teil)
kubectl --context k8s-<env> -n registry exec ca-build -- sh -c \
  'echo | openssl s_client -connect ghcr.io:443 -servername ghcr.io \
   -CAfile /tmp/combined-ca.crt 2>/dev/null | grep "Verify return code"'
```

BEIDE muessen `Verify return code: 0 (ok)` zeigen. Sonst NICHT fortfahren.

## Schritt 4 - ConfigMap generieren (ins Repo)

```bash
kubectl create configmap registry-ca-bundle \
  --from-file=ca-certificates.crt=/tmp/combined-ca.crt \
  --namespace registry --dry-run=client -o yaml \
  > ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/<env>/registry/registry-ca-bundle.yaml

# Verifizieren
grep -c "BEGIN CERTIFICATE" \
  ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/<env>/registry/registry-ca-bundle.yaml
```

ConfigMap ist OEFFENTLICH (nur CA-Zerts) -> KEIN SOPS. Als resources-Eintrag in
die registry/kustomization.yaml aufnehmen (Git-Directory-Source der App).

## Schritt 5 - values-override.yaml (Helm)

Im Zot-DEV/TEST/PROD-Override:

```yaml
env:
  # ... AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY ...
  - name: SSL_CERT_FILE
    value: /etc/ssl-ca/ca-certificates.crt
extraVolumes:
  - name: ca-bundle
    configMap:
      name: registry-ca-bundle
extraVolumeMounts:
  - name: ca-bundle
    mountPath: /etc/ssl-ca
    readOnly: true
configFiles:
  config.json: |-
    # storageDriver: regionendpoint nas20.eneg.de:8010, secure:true, skipverify:false
```

## Schritt 6 - Cutover-Reihenfolge

1. ConfigMap MUSS existieren, BEVOR das StatefulSet sie mountet:
   - erst registry-secrets + registry (Git-Source) syncen
   - `kubectl -n registry get configmap registry-ca-bundle` -> muss DATA 1 zeigen
2. Dann greift der Helm-Rollout (StatefulSet, ordinal von hoechster Replica)
3. 3-Replica-Rollout dauert; Startup-Scan (S3-Bucket + Sync-Upstreams) bis ~5 min

## Schritt 7 - Verifikation (End-to-End Pull)

```bash
# Catalog (Metadaten von NAS20)
curl -sk -u eneg:<pw> https://registry-<env>.eneg.de/v2/_catalog | head -c 500

# Blob-Pull (echte Layer-Daten von NAS20) - echten Digest aus Manifest einsetzen!
curl -sk -u eneg:<pw> -o /dev/null -w "%{http_code}\n" \
  "https://registry-<env>.eneg.de/v2/library/hello-world/blobs/sha256:<layer-digest>"
# Erwartet: 200
```

## Aufraeumen

```bash
kubectl --context k8s-<env> -n registry delete pod ca-build --ignore-not-found
# /tmp/system-ca.crt /tmp/combined-ca.crt auf mgmt-10 koennen bleiben oder weg
```

## Fallstricke (aus DEV-Cutover 12.06.2026)

- `cat` im distroless Zot-Image unbrauchbar (gibt still 0 zurueck) -> Image NICHT
  per exec inspizieren, Bundle extern (Debian-Pod) bauen.
- `SSL_CERT_FILE` ersetzt System-Trust -> Bundle MUSS beide Teile haben (s.o.).
- Platzhalter <layer-digest> im curl-Test wirklich ersetzen, sonst HTTP 500
  (kein NAS20-Problem, sondern ungueltiger Digest).
- ca-certificates fehlt in debian:13-slim -> apt-get install noetig.
