# Phase 9a — Anweisung fuer neuen Chat (TEST-Mirror + Etappe B PROD)

**Stand:** 21.04.2026 — Etappe A (DEV) ABGESCHLOSSEN, naechste Schritte folgen
**Vorgaenger-Doku (Pflichtlektuere):** `docs/phases/phase-09a-security-registries.md` insbesondere Sektion 12 (Implementierungs-Learnings)

---

## Kontext-Brief fuer den neuen Chat

Phase 9a Container Registry Infrastruktur (Zot) ist in DEV erfolgreich abgeschlossen. Multi-Arch-Pulls (hello-world, nginx) laufen end-to-end ueber `registry-dev.eneg.de`, NAS10 S3 ist befuellt, containerd-Mirror auf allen 3 DEV-Nodes aktiv. Der Multi-Arch-Bug wurde mit `preserveDigest: true` + `http.compat: ["docker2s2"]` geloest. DockerHub-Authentifizierung ist aktiv (Rate-Limit-Bypass).

**Was jetzt ausstehend ist:**

1. containerd-Mirror-Rollout auf TEST + PROD (gleicher Mirror-Endpoint `registry-dev.eneg.de` mit Internet-Fallback)
2. Etappe B: PROD-Zot komplett aufsetzen (eigene Registry, Sync DEV→PROD, kein Internet-Fallback)
3. Cleanup-Pruefungen (Trivy Rate-Limits weg, eigene Images via sync gespiegelt)

---

## Pflicht-Lesereihenfolge zu Beginn des neuen Chats

1. `docs/phases/phase-09a-security-registries.md` (Sections 1-3 fuer Architektur/Entscheidungen, **Section 12 fuer Implementierungs-Learnings**, Section 5 Etappe A, Section 6 Etappe B)
2. `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.17.md` (insbesondere Aenderungshistorie)
3. Diese Datei (Folge-Anweisung)

---

## Konkrete naechste Schritte (Reihenfolge!)

### Schritt 1 — TEST-Cluster containerd-Mirror

```bash
# Auf k8s-mgmt-10
cd ~/git/eneg-k8s-infrastructure-v2
git pull origin main
ansible-playbook -i ansible/inventory/test.yml ansible/playbooks/07-k3s-registries-mirror.yml
```

Das Playbook ist rolling (serial: 1), pausiert nach erstem Node fuer manuelle Pruefung. Endpoint ist `https://registry-dev.eneg.de` (mit Internet-Fallback).

**Verifikation pro Node:**
```bash
ssh admin-ubuntu@k8s-test-21 'sudo cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml'
ssh admin-ubuntu@k8s-test-22 'sudo k3s crictl pull docker.io/library/alpine:3'
# Pull muss durchlaufen, in Zot-Catalog (https://registry-dev.eneg.de/v2/_catalog) sollte alpine auftauchen
```

### Schritt 2 — PROD-Cluster containerd-Mirror (mit Fallback bis Etappe B)

Analog zu Schritt 1, jedoch mit dem PROD-Inventory:

```bash
ansible-playbook -i ansible/inventory/prod.yml ansible/playbooks/07-k3s-registries-mirror.yml
```

**WICHTIG:** Ansible-Playbook 07 ist aktuell mit `registry-dev.eneg.de` als Endpoint hardcoded. Fuer PROD ist das in Etappe A noch korrekt (PROD nutzt DEV-Registry mit Fallback). Erst in Etappe B wird das Playbook angepasst auf `registry-prod.eneg.de` ohne Fallback (siehe Schritt 5).

**Test-Pull:**
```bash
ssh admin-ubuntu@k8s-prod-22 'sudo k3s crictl pull docker.io/library/busybox:latest'
```

### Schritt 3 — Trivy Rate-Limit-Aufloesung verifizieren

Trivy Operator scannt regelmaessig. Pruefen ob `TOOMANYREQUESTS`-Fehler verschwunden sind:

```bash
kubectl --context k8s-dev -n trivy-system logs -l app.kubernetes.io/name=trivy-operator --tail=200 | grep -i "TOOMANYREQUESTS\|rate.limit" || echo "Keine Rate-Limit-Fehler"
kubectl --context k8s-dev -n trivy-system get vulnerabilityreports -A | wc -l   # Sollte deutlich mehr Reports geben als vorher
```

Falls noch Fehler: pruefen ob Trivy-Pods nach dem Mirror-Rollout neugestartet wurden (sonst greift Mirror nicht beim laufenden Container).

### Schritt 4 — Eigene Images Sync (`dhenkeeneg/*`) verifizieren

In `values-override.yaml` ist eine 5. Sync-Registry konfiguriert:
- Source: `https://ghcr.io`
- OnDemand: false (scheduled, PollInterval 15min)
- Content: `dhenkeeneg/**` → Destination `/eneg`, StripPrefix true
- Erwartung: Catalog enthaelt `eneg/idoit-open`, `eneg/eneg-it-info-versand`, `eneg/prometheus-msteams`

```bash
curl -s https://registry-dev.eneg.de/v2/_catalog | jq
# Erwartung: {"repositories": ["eneg/idoit-open", "eneg/eneg-it-info-versand", "eneg/prometheus-msteams", ...]}

# Falls leer: Logs pruefen
kubectl --context k8s-dev -n registry logs registry-zot-0 | grep -iE "syncing image.*ghcr|dhenkeeneg" | tail -20
```

### Schritt 5 — Etappe B starten (PROD-Registry)

**Erst nach Schritte 1-4 erfolgreich.** Vorgehen siehe `phase-09a-security-registries.md` Section 6 (B1-B6). Kurzform:

1. **B1:** Bucket `k8s-prod-registry` auf NAS10 erstellen, eigene S3-Keys generieren (separate von DEV)
2. **B2:** Kopiere `kubernetes/environments/dev/registry/` nach `kubernetes/environments/prod/registry/`, anpassen:
   - S3-Bucket-Name → `k8s-prod-registry`
   - DNS → `registry-prod.eneg.de` (192.168.178.100)
   - Sync-Config: **NUR EINE** Source `https://registry-dev.eneg.de` mit Denylist-Filter (siehe Section 6 B4 fuer Tag-Liste)
   - **KEINE Proxy-Cache OnDemand-Registries** (PROD darf nichts aus dem Internet ziehen)
3. **B3:** Analog `registry-secrets/` mit eigenen Keys
4. **B4:** ArgoCD-Apps `prod/infrastructure/registry-secrets-app.yaml` und `registry-app.yaml`
5. **B5:** Initial-Sync abwarten (Logs, Catalog), dann Ansible 07 anpassen fuer PROD: Endpoint `registry-prod.eneg.de`, KEIN Fallback. Erneut ausrollen NUR auf PROD-Cluster.
6. **B6:** Verifikation laut Section 6 B6 Checkliste

### Schritt 6 — Doku-Update nach Etappe B Abschluss

- `phase-09a-security-registries.md` Section 12 ergaenzen mit Etappe-B-Learnings, Status auf "VOLLSTAENDIG ABGESCHLOSSEN"
- `phase-09-security-dev.md` Learning #8 (DockerHub Rate-Limit) auf "geloest" markieren mit Referenz auf Phase 9a
- Neue Projektplan-Version `K8s-GitOps-Infrastruktur-Projektplanung_v2.18.md` mit Phase 9a Vollabschluss
- Naechste Phase: 9b (CrowdSec + Falco)

---

## Wichtige Projekt-Eigenheiten (KOPIE aus Memory)

- Alle Git-Commits/Pushes fuehrt Daniel selbst aus, nicht Claude
- Keine SSH-Kommandos von Claude auf Nodes oder k8s-mgmt-10
- Claude nutzt Desktop Commander fuer Repo-Dateien auf Windows-Laptop `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2`
- Kubernetes-Zugriff per MCP (Contexts `k8s-dev`, `k8s-test`, `k8s-prod`)
- SOPS-verschluesselte Secrets per Age-Key auf k8s-mgmt-10 (`age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm`)
- Keine Entscheidungen ohne Optionen-Praesentation; Daniel entscheidet
- Immer DEV zuerst, dann TEST, dann PROD — nie parallel
- Schritt-fuer-Schritt vorgehen, Zwischen-Checkpoints, Daniel sagt "weiter" / "los" / "OK weiter"

---

## Kritische Learnings aus Etappe A (NICHT vergessen!)

1. **Multi-Arch + S3 + OnDemand braucht `preserveDigest: true` + `http.compat: ["docker2s2"]`** — beides muss zusammen gesetzt sein, sonst Pod-CrashLoop oder `invalid manifest content`. Fuer PROD-Sync (kein OnDemand, sondern scheduled) gilt das gleiche, weil DockerHub-Manifests vom DEV-Zot byte-exakt nach PROD propagieren muessen.

2. **DockerHub-Authentifizierung muss in PROD-Sync **nicht** noetig sein**, weil PROD nur von DEV-Zot zieht (kein DockerHub-Kontakt). Aber DEV braucht weiterhin DockerHub-PAT.

3. **K3s containerd default endpoint fallback** funktioniert seit 1.26.13 ohne `rewrites:`. NICHT `rewrites:` einfuegen — verursacht Doppelpfade.

4. **ArgoCD Replica-State** wird nach manuellem `scale=0` nicht zurueckgesetzt; bei Reset-Operationen muss man manuell wieder `scale=1` machen.

5. **Zot ist distroless** — `kubectl exec ... -- sh` schlaegt fehl. Verifikation laeuft via HTTP-API von extern.

6. **Sync-Credentials JSON-Format** kann mehrere Upstream-Registries enthalten; eine einzige Datei reicht fuer ghcr.io + DockerHub + ggf. mehr.

7. **Erste Sync-Iteration zeigt `cache miss` Warnings** — das ist normal, nicht Fehler. Erfolgs-Signal ist `successfully synced image`.

8. **First-pull cache miss ist erwartetes Verhalten** — bei zweitem Pull ist der Manifest-Index im Catalog und keine Warnings mehr.

---

## Wenn etwas schiefgeht

**Pod startet nicht (CrashLoopBackOff):**
- `kubectl --context k8s-dev -n registry logs registry-zot-0 --previous`
- Pruefen ob `preserveDigest` ohne `http.compat` konfiguriert ist (Fehlermeldung `can not use PreserveDigest option without enabling http.Compat`)

**`invalid manifest content` Fehler:**
- Multi-Arch-Bug. `preserveDigest: true` + `http.compat: ["docker2s2"]` setzen, dann State-Reset (Bucket leeren, PVC loeschen)

**State-Reset Procedure (NUR im Notfall):**
1. ArgoCD App `registry` pausieren
2. `kubectl scale -n registry sts/registry-zot --replicas=0`
3. `kubectl delete pvc -n registry registry-pvc-registry-zot-0`
4. NAS10 Bucket `k8s-dev-registry` leeren via QuObjects UI
5. `kubectl scale -n registry sts/registry-zot --replicas=1` (NICHT 0 lassen — ArgoCD restored das nicht!)
6. ArgoCD App wieder enable

**containerd Mirror funktioniert nicht:**
- `cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml` — pruefen
- `crictl pull --debug docker.io/library/alpine:3` — sehen wo es haengt
- Default endpoint fallback sollte aktiv sein, sonst funktioniert auch `nginx:latest` nicht ohne Mirror

---

## Erste Aktion im neuen Chat

Anweisung an Claude:

> Wir machen mit Phase 9a Etappe A (Mirror-Rollout auf TEST und PROD) und Etappe B (PROD-Zot) weiter. Lies bitte zuerst `docs/phases/phase-09a-security-registries.md` Section 12 sowie diese Anweisung `docs/guides/phase-09a-test-prod-handoff.md` komplett. Dann praesentiere mir die naechsten konkreten Schritte mit Optionen.
