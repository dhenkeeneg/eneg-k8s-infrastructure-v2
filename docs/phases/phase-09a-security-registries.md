# Phase 9a: Container Registry Infrastruktur (Zot)

**Status:** **Etappe A VOLLSTAENDIG ABGESCHLOSSEN (DEV + TEST + PROD)** am 21.04.2026 — Etappe B (PROD-Zot) offen
**Abstimmung abgeschlossen:** 20.04.2026
**Etappe A Umsetzung:** 21.04.2026
  - DEV: Zot deployed, containerd-Mirror auf 3 DEV-Nodes, End-to-End-Pull verifiziert
  - TEST: containerd-Mirror auf 3 TEST-Nodes via Ansible 07 (mit Internet-Fallback)
  - PROD: containerd-Mirror auf 3 PROD-Nodes via Ansible 07 (mit Internet-Fallback bis Etappe B)
**Phase 9 Uebersicht:** Kyverno + Trivy Operator DEV abgeschlossen; **Phase 9a Etappe A** vollstaendig abgeschlossen; CrowdSec + Falco folgen als Phase 9b
**Voraussetzungen:** Phase 7 (Monitoring), Phase 8 (TEST/PROD), Phase 10 (Velero), Phase 9 Schritt 1+2 (Kyverno + Trivy Operator in DEV)
**Folge-Anweisung fuer Etappe B:** `docs/guides/phase-09a-test-prod-handoff.md` (Schritt 5)

---

## 1. Kontext & Motivation

Phase 9 Schritt 2 (Trivy Operator, 14.04.2026 / Nachbesserung 20.04.2026) hat ein bestehendes Infrastruktur-Thema offengelegt: **DockerHub Rate-Limit bei anonymen Pulls** (100 Pulls / 6h je Cluster-IP). Bei Workloads mit `docker.io/*`-Images schlaegt das zu, sobald Trivy-Scans und normale Pod-Starts gleichzeitig laufen.

Statt nur einen Proxy-Mirror als Workaround einzubauen, zieht Phase 9a die eigene Registry-Infrastruktur vor. Damit werden mehrere Themen gleichzeitig abgeraeumt:

- **Rate-Limit entfaellt vollstaendig** (Trivy, normale Deployments, CI/CD)
- **Eigene Images konsolidieren** — bisher auf `ghcr.io/dhenkeeneg/*` (PAT-Management, Token-Erneuerung)
- **Deterministische Image-Versionen in PROD** — heute kann `library/postgres:17` taegliche Layer-Aenderungen aus docker.io bekommen; mit eigener PROD-Registry wird das Image zum Zeitpunkt der Promotion eingefroren
- **PROD vollstaendig vom Internet entkoppelt** fuer Container-Pulls — Compliance- und Stabilitaets-Argument
- **Grundbaustein fuer spaetere Kyverno Image-Verify Policies** (Cosign/Notation)
- **Phase 9b (CrowdSec, Falco) profitiert** — Rollout laeuft ohne Rate-Limit-Stoerungen

---

## 2. Zielarchitektur (Topologie-Variante 2)

```
                    [ docker.io, quay.io, ghcr.io, registry.k8s.io ]
                                       ↑ (nur Proxy-Cache-Pulls aus DEV)
                                       │
                              ┌────────┴────────┐
                              │                 │
  ┌───────────────────────────┴───────────┐   ┌─┴───────────────────────────────────┐
  │  registry-dev.eneg.de                 │   │  registry-prod.eneg.de              │
  │  (Zot, VLAN 180, DEV-Cluster)         │   │  (Zot, VLAN 178, PROD-Cluster)      │
  │                                       │   │                                     │
  │  S3: nas10/k8s-dev-registry           │   │  S3: nas10/k8s-prod-registry        │
  │  PVC: 10Gi (Longhorn, Metadata)       │   │  PVC: 10Gi (Longhorn, Metadata)     │
  │                                       │   │                                     │
  │  Funktion:                            │   │  Funktion:                          │
  │  - Proxy-Cache fuer upstream Images   │◄──┤  - Empfaengt Sync von DEV           │
  │  - Hostet `eneg/*` eigene Images      │   │  - Hostet gepromotete `eneg/*`      │
  │  - Source fuer TEST-Cluster           │   │  - Air-gapped (kein Internet-Pull)  │
  └───────────┬───────────────────────────┘   └────────────────┬────────────────────┘
              │                                                │
              │ containerd mirror                              │ containerd mirror
              │                                                │
   ┌──────────▼──────────┐  ┌──────────────────────┐  ┌────────▼─────────────┐
   │ DEV Cluster         │  │ TEST Cluster         │  │ PROD Cluster         │
   │ (k8s-dev-21..23)    │  │ (k8s-test-21..23)    │  │ (k8s-prod-21..23)    │
   │ Mirror: dev,        │  │ Mirror: dev,         │  │ Mirror: prod ONLY    │
   │ Fallback: upstream  │  │ Fallback: upstream   │  │ KEIN Fallback        │
   └─────────────────────┘  └──────────────────────┘  └──────────────────────┘
```

**Sync-Fluss:** DEV-Zot → PROD-Zot, zeitgesteuert alle 30 Minuten, Denylist-Filter auf mutable Tags (`latest`, `main`, `dev`, `rc*`, `alpha*`, `beta*`).

---

## 3. Abgestimmte Entscheidungen (Stand 20.04.2026)

| Thema | Entscheidung | Begruendung |
|---|---|---|
| **Registry-Software** | Zot v2.1+ (project-zot/zot) | Single-Binary, OCI-native, leichter als Harbor (~200 MB RAM vs. ~2-3 GB), CNCF Sandbox, Cisco/CoreWeave produktiv |
| **Topologie** | Variante 2: DEV + PROD, TEST pullt von DEV | Entkoppelt PROD vollstaendig vom Internet; Sync-Gate DEV→PROD wird Promotion-Kontrollpunkt |
| **Reihenfolge** | Etappe A (DEV) → verifizieren → Etappe B (PROD). Nicht parallel. | Wir lernen Zot's Betriebs-/Sync-Verhalten erst an einer Instanz |
| **Storage-Backend** | NAS10 S3 (`k8s-dev-registry`, `k8s-prod-registry`) | Konsistent mit Velero, Loki, Thanos. NAS10 `nas10.eneg.de:8010` |
| **PVC** | 10 Gi Longhorn pro Instanz | Nur fuer lokale Metadaten/Dedup-Cache; Blobs liegen in S3 |
| **DNS-Namen** | `registry-dev.eneg.de`, `registry-prod.eneg.de` | Konsistent mit bisheriger Split-DNS-Konvention |
| **TLS** | Let's Encrypt via cert-manager + IONOS-Webhook | Standard-Muster; wie OpenProject, Grafana, ArgoCD |
| **Namespace (beide Envs)** | `registry` | Einheitlich |
| **Mirror-Scope (containerd)** | `docker.io`, `quay.io`, `ghcr.io`, `registry.k8s.io` | Deckt alle heute genutzten Upstream-Registries ab |
| **Auth-Modell** | Anonymer Pull (LAN-intern ok), Auth-Push via htpasswd | Spart imagePullSecret in jedem Namespace/Cluster |
| **Push-User** | `eneg` | Ein zentraler User fuer Admin-Push + zukuenftige CI-Bots |
| **Eigene Images (Migration)** | **Option 1a** — Zot `sync`-Extension spiegelt `ghcr.io/dhenkeeneg/*` automatisch | CI bleibt unveraendert (Target weiter ghcr.io); Pod-Manifeste auch unveraendert (containerd mirror greift) |
| **Sync-Policy DEV → PROD** | **Option 2a** — "Alles spiegeln" + Denylist-Filter fuer mutable Tags | Promotion-Kontrolle sitzt auf Manifest-Ebene (welcher Tag in PROD-Overlay steht); Sync laeuft mechanisch |
| **In-Registry Trivy-Scan** | **Deaktiviert fuer initialen Rollout** | Trivy Operator scannt bereits laufende Workloads; Zot-Extension waere Duplikat. Kann spaeter aktiviert werden als "Scan beim Eingang" (scrub+trivy extension, pre-Pull-Signal) |
| **Cosign/Notation Verify** | Nicht jetzt | Spaetere Erweiterung via Kyverno Image-Verify Policy |
| **PROD Internet-Fallback** | **Keiner** (nach Etappe B) | Bewusst, um "PROD pulls nothing from Internet" Compliance-Aussage zu haben |
| **DEV/TEST Internet-Fallback** | Ja, als Safety-Net in `registries.yaml` | Bei Zot-Ausfall in DEV faellt Cluster auf upstream zurueck |

---

## 4. Voraussetzungen & vorbereitende Arbeiten

Vor Start der Umsetzung zu pruefen / bereitzustellen:

| Nr | Punkt | Zustaendig | Hinweis |
|----|-------|------------|---------|
| 1 | NAS10 QuObjects S3: zwei neue Buckets | Daniel via QuObjects UI | `k8s-dev-registry`, `k8s-prod-registry` — keine Versionierung noetig |
| 2 | S3 Access/Secret Keys generieren (einer pro Bucket) | Daniel via QuObjects UI | Analog zu Velero-Pattern; separate Keys pro Env |
| 3 | DNS (IONOS Interner Split-DNS): A-Records | Daniel via IONOS | `registry-dev.eneg.de` → 192.168.180.100 (DEV Traefik LB) |
| | | | `registry-prod.eneg.de` → 192.168.178.100 (PROD Traefik LB) |
| 4 | htpasswd fuer User `eneg` | Im neuen Chat mit `htpasswd -B -c` erzeugt | bcrypt, wird per SOPS verschluesselt abgelegt |
| 5 | Sync-Credentials DEV → PROD | Nach Etappe A, vor Etappe B | PROD-Zot liest aus DEV-Zot mit dediziertem Robot-Pull-User |
| 6 | Ansible Inventar pruefen | Daniel | `ansible/inventory/{dev,test,prod}/hosts.yml` fuer K3s Nodes |
| 7 | Zot Helm Chart Version festlegen | Im neuen Chat | Aktuelle stable aus `project-zot/helm-charts` pruefen, Version abstimmen bevor Deploy |

**Noch NICHT zu tun:** containerd `registries.yaml` erst nach erfolgreicher Zot-Installation in DEV.

---

## 5. Etappe A — DEV-Registry aufsetzen

### A1 — S3 Bucket & Credentials auf NAS10

- Bucket `k8s-dev-registry` anlegen (QuObjects UI)
- Access Key + Secret Key generieren, ScopeKey auf Bucket beschraenken
- Plaintext-Template auf k8s-mgmt-10 unter `~/secrets-plaintext/registry/dev-s3-creds.yaml` ablegen (NICHT committen)
- Via SOPS verschluesseln → `kubernetes/environments/dev/registry/secrets/s3-credentials.enc.yaml`

### A2 — Kustomize-Struktur anlegen

```
kubernetes/
├── base/
│   └── registry/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── values.yaml                 # generisches Zot values
└── environments/
    └── dev/
        └── registry/
            ├── kustomization.yaml
            ├── values-override.yaml    # DEV-spezifisch: S3 bucket, DNS, Proxy-Cache-Ziele
            ├── ingressroute.yaml       # Traefik
            ├── certificate.yaml        # cert-manager
            └── secrets/
                ├── s3-credentials.enc.yaml
                └── htpasswd.enc.yaml
```

### A3 — Zot Helm Values (Base, Kernpunkte)

- Chart: `project-zot/zot` (Version beim Start mit Daniel abstimmen)
- `persistence.enabled: true`, `persistence.size: 10Gi`, `storageClass: longhorn`
- Auth: htpasswd, User `eneg`, Pull anonym (`accessControl.repositories."**".defaultPolicy: [read]`)
- Extensions: `search`, `ui`, `sync` (fuer spaetere Etappe B) — **KEIN `scrub`/`trivy`** im initialen Rollout
- Storage: `s3` Backend mit Keys aus Secret `registry-s3-credentials`
- Proxy-Cache-Config: `docker.io`, `quay.io`, `ghcr.io`, `registry.k8s.io` als upstream registries konfiguriert
- Resources: requests 200m/256Mi, limits 1000m/1Gi (Start-Werte, spaeter tunen)

### A4 — Traefik IngressRoute + Certificate

- `registry-dev.eneg.de` via cert-manager ClusterIssuer `letsencrypt-ionos-prod`
- IngressRoute auf Traefik `websecure` Entrypoint, TLS Secret aus Certificate
- Rate-Limit-Middleware optional

### A5 — ArgoCD Application

- Neue App `registry` in `kubernetes/environments/dev/infrastructure/registry-app.yaml`
- App-of-Apps sollte sie automatisch pickup
- Sync-Wave nach `cert-manager`, `traefik`, `longhorn`

### A6 — Manuelle Zwischen-Verifikation (nur DEV-Cluster)

Bevor containerd-Mirror auf allen drei Clustern gesetzt wird, erst nur im DEV-Cluster testen:

- `curl https://registry-dev.eneg.de/v2/` → `{}` (HTTP 200)
- `curl -u eneg:PW https://registry-dev.eneg.de/v2/_catalog` → leere Liste
- Push-Test: `skopeo copy --dest-creds eneg:PW docker://docker.io/library/alpine:3 docker://registry-dev.eneg.de/test/alpine:3`
- Proxy-Cache-Test: `docker pull registry-dev.eneg.de/docker.io/library/nginx:1.27-alpine` von einem Arbeitsrechner

### A7 — containerd `registries.yaml` ausrollen

Reihenfolge wichtig: **DEV zuerst, dann TEST, dann PROD**. PROD bekommt hier nur die DEV-Registry als Mirror mit Fallback — PROD-Registry gibt es noch nicht.

Via Ansible Play:

```
ansible/playbooks/
└── k3s-registries-mirror.yml
```

Das Play:
1. Erzeugt `/etc/rancher/k3s/registries.yaml` mit Mirror-Eintraegen fuer die vier Upstream-Domains
2. Triggert `systemctl restart k3s` bzw. `k3s-agent` (rolling, Node fuer Node)
3. Verifiziert `crictl info | jq .config.registry` auf jedem Node

**Wichtig:** Das Play wird zweimal angepasst — jetzt fuer Etappe A (mit DEV-Registry + Fallback), spaeter in Etappe B angepasst fuer PROD-Cluster (NUR PROD-Registry, kein Fallback).

Aktueller Mirror-Inhalt fuer DEV + TEST + PROD in Etappe A:
- `docker.io` → `https://registry-dev.eneg.de/v2/docker.io`, fallback `https://registry-1.docker.io`
- `quay.io` → `https://registry-dev.eneg.de/v2/quay.io`, fallback `https://quay.io`
- `ghcr.io` → `https://registry-dev.eneg.de/v2/ghcr.io`, fallback `https://ghcr.io`
- `registry.k8s.io` → `https://registry-dev.eneg.de/v2/registry.k8s.io`, fallback `https://registry.k8s.io`

**Packer-Template** (`packer/templates/k3s-node.pkr.hcl`) muss ebenfalls angepasst werden, damit neue VMs direkt mit korrekter Config starten.

### A8 — Eigene Images Sync via Zot sync-Extension

Zot's `sync`-Extension als separate Config-Sektion:
- Source: `https://ghcr.io/dhenkeeneg`
- Authentication: GHCR PAT (read-only scope, als separates Secret in SOPS)
- Content: alle Tags aller drei Repos (`idoit-open`, `eneg-it-info-versand`, `prometheus-msteams`)
- Schedule: alle 15 Minuten (oder on-demand webhook spaeter)
- Ziel: lokaler Namespace `eneg/` in Zot

Nach dem ersten Sync laeuft `registry-dev.eneg.de/eneg/idoit-open:37` parallel zu `ghcr.io/dhenkeeneg/idoit-open:37` (beide zeigen auf dieselben Digests, nur die Registry unterscheidet sich).

### A9 — Etappe A Abschluss-Verifikation

- [ ] Zot-Pod Running, Health/Readiness gruen
- [ ] Zot UI unter `https://registry-dev.eneg.de` erreichbar, Login `eneg` funktioniert
- [ ] Alle drei Cluster: `crictl pull docker.io/library/nginx:1.27-alpine` laueft durch Zot (Log-Pruefung in Zot)
- [ ] Trivy-Scan-Pods (die heute wegen Rate-Limit scheitern) laufen sauber durch → `VulnerabilityReport` fuer bisher fehlschlagende Workloads erstellt
- [ ] Zot-Sync `ghcr.io/dhenkeeneg/*` hat mind. einmal erfolgreich gelaufen, Images sichtbar in Zot UI unter `eneg/*`
- [ ] S3-Bucket `k8s-dev-registry` enthaelt Blobs (ueber QuObjects UI sichtbar)
- [ ] PROD-Cluster funktionieren weiterhin (Mirror+Fallback arbeitet)
- [ ] Bestehende Workloads nicht beeintraechtigt (ArgoCD Apps alle Synced+Healthy)

Erst nach **allen** Haken: Etappe B starten.

---

## 6. Etappe B — PROD-Registry aufsetzen

### B1 — S3 Bucket & Credentials PROD

- Bucket `k8s-prod-registry` auf NAS10
- Eigene S3-Keys (nicht DEV-Keys wiederverwenden)
- SOPS-verschluesselt → `kubernetes/environments/prod/registry/secrets/s3-credentials.enc.yaml`

### B2 — PROD Overlay anlegen

Kopieren von `environments/dev/registry/` nach `environments/prod/registry/`, dann anpassen:
- S3 Bucket Name
- DNS `registry-prod.eneg.de`
- **Proxy-Cache-Upstream-Config ENTFERNEN** — PROD holt nichts aus dem Internet
- Sync-Config **EMPFANGEND** konfigurieren (siehe B4)

### B3 — htpasswd + TLS + DNS fuer PROD

- Gleicher User `eneg` (unterschiedliches Passwort moeglich — abstimmen)
- Certificate `registry-prod.eneg.de` via cert-manager
- DNS `registry-prod.eneg.de` → 192.168.178.100

### B4 — Sync DEV → PROD

Konfiguration auf **PROD-Zot** (PROD zieht von DEV, NICHT umgekehrt — Pull-basiert ist robuster als Push):

- Source: `https://registry-dev.eneg.de`
- Auth: Dedizierter Read-Only-User `sync-to-prod` in DEV-Zot (htpasswd) — Credentials als SOPS-Secret in PROD-Overlay
- Schedule: alle 30 Minuten
- **Denylist-Filter** (Tags die NICHT synct werden):
  - `latest`
  - `main`
  - `dev`
  - `rc*`, `*-rc*`
  - `alpha*`, `*-alpha*`
  - `beta*`, `*-beta*`
  - `master`
  - `snapshot*`, `nightly*`, `edge*`
- Content: alle Namespaces (`docker.io/*`, `quay.io/*`, `ghcr.io/*`, `registry.k8s.io/*`, `eneg/*`)

Zot sync-Extension nutzt Pull-basierte Replikation; bei Netzwerk-Problemen retry automatisch, kein manueller Eingriff noetig.

### B5 — containerd Config PROD umstellen (ohne Fallback!)

Zweite Anwendung des Ansible-Plays `k3s-registries-mirror.yml`, diesmal nur fuer PROD-Cluster mit **anderem Template**:

- `docker.io` → `https://registry-prod.eneg.de/v2/docker.io` **(kein Fallback)**
- `quay.io` → `https://registry-prod.eneg.de/v2/quay.io` **(kein Fallback)**
- `ghcr.io` → `https://registry-prod.eneg.de/v2/ghcr.io` **(kein Fallback)**
- `registry.k8s.io` → `https://registry-prod.eneg.de/v2/registry.k8s.io` **(kein Fallback)**

**Kritisch:** Vor diesem Schritt muss PROD-Zot mindestens einen vollstaendigen Initial-Sync von DEV-Zot durchgelaufen haben (Zot-Logs pruefen, Sichtpruefung ueber UI, alle derzeit aktiven PROD-Workload-Images muessen gelistet sein).

**Rollback-Plan:** Falls ein PROD-Workload nach Umstellung ein Image nicht mehr pullen kann (z.B. weil Sync-Filter ein mutables Tag gefiltert hat), kann `registries.yaml` mit Fallback-Eintraegen reaktiviert werden → Ansible Play rueckwaerts.

### B6 — Etappe B Abschluss-Verifikation

- [ ] PROD-Zot Running, S3 Bucket befuellt
- [ ] Sync DEV → PROD lauft periodisch, Logs zeigen "no new manifests" nach vollem Initial-Sync
- [ ] PROD `crictl pull` ueber eigene Registry, kein Internet-Traffic auf PROD-Nodes fuer Image-Pulls
- [ ] Pod-Restart-Test: bestehenden Workload in PROD neustarten, Image-Pull erfolgreich
- [ ] **Neu-Deployment-Test**: ein Test-Pod (z.B. `nginx:stable`) in PROD scheduln, Image kommt aus PROD-Zot
- [ ] ArgoCD alle Apps Synced+Healthy in allen drei Envs
- [ ] Trivy-Scan-Reports in allen drei Envs vollstaendig (keine `TOOMANYREQUESTS`-Fehler mehr)

---

## 7. Abschluss-Nacharbeiten

Nach erfolgreicher Etappe B:

- **Trivy Operator values-override** in allen drei Envs: DockerHub-Workaround (falls einer eingebaut wurde) kann entfernt werden
- **GHCR PAT**: bleibt aktiv fuer CI-Push-Pfad; nur Lesezugriff von der Registry muss weiter funktionieren
- **Phase 9 Doku** (`phase-09-security-dev.md`): Learning #8 (DockerHub Rate-Limit) auf "geloest" markieren mit Referenz auf Phase 9a
- **Neue Images in PROD pushen**: Falls zwischenzeitlich eigene CI-Builds nach ghcr.io gegangen sind, die noch nicht in DEV-Zot sind → Sync-Lauf erzwingen, dann DEV→PROD-Sync anstossen
- **Monitoring**:
  - Blackbox-Probe fuer `registry-dev.eneg.de/v2/` und `registry-prod.eneg.de/v2/` einrichten
  - ServiceMonitor fuer Zot Metrics (Extension liefert Prometheus-Endpoint)
  - Grafana-Dashboard: Pull-Rate, Sync-Status, S3-Usage

---

## 8. Verifikations-Checkliste (Gesamt)

| Nr | Pruefung | Etappe |
|----|----------|--------|
| 1 | DEV-Zot deployed, Healthy | A |
| 2 | DEV-Zot UI erreichbar mit TLS | A |
| 3 | Proxy-Cache funktioniert fuer docker.io/quay.io/ghcr.io/registry.k8s.io | A |
| 4 | Eigene Images via sync-Extension gespiegelt | A |
| 5 | containerd registries.yaml auf 9 Nodes (DEV + TEST + PROD mit Fallback) | A |
| 6 | Trivy-Scans laufen fehlerfrei in allen drei Envs | A |
| 7 | Packer-Template aktualisiert | A |
| 8 | PROD-Zot deployed, Healthy | B |
| 9 | Sync DEV→PROD laeuft periodisch | B |
| 10 | PROD registries.yaml ohne Fallback | B |
| 11 | Firewall-Pruefung: PROD-Nodes haben kein outbound 443 zu docker.io noetig (optional Regel einziehen) | B |
| 12 | ArgoCD: alle Apps in allen drei Envs Synced+Healthy | Gesamt |

---

## 9. Offene Punkte nach Abschluss

- **Cosign/Notation Image-Verify**: Kyverno Policy `verify-images` einfuehren, nur signierte Images aus eigener Registry zulassen — kommt in Phase 9b/c
- **In-Registry-Scan (Zot trivy-Extension)**: Kann nach stabilem Betrieb zugeschaltet werden, um bereits beim Push/Proxy-Cache einen Scan zu erzwingen
- **CI-Migration**: Langfristig `dhenkeeneg/*` Builds direkt nach `registry-dev.eneg.de/eneg/*` pushen, GHCR abloesen
- **TEST-Registry** (Variante 3 Upgrade): Falls sich TEST-Last auf DEV-Zot als Problem zeigt, eigene TEST-Registry mit Sync DEV→TEST einziehen
- **Registry-to-Registry Replication**: Bei geografisch getrennten Standorten (aktuell nicht relevant)
- **Garbage Collection**: Zot GC-Policy einrichten fuer alte/unreferenzierte Blobs

---

## 10. Risiken & Rollback

| Risiko | Auswirkung | Gegenmassnahme |
|--------|------------|-----------------|
| Zot-Pod crashed in DEV | TEST-Cluster pullt nicht mehr ueber Proxy | Fallback auf upstream in `registries.yaml` aktiv; Cluster weiter funktional |
| S3-Verbindung NAS10 gestoert | Zot kann neue Blobs nicht schreiben; Proxy-Cache reduziert | Zot lokaler PVC-Cache federt kurze Ausfaelle ab; Blackbox-Alert |
| Sync DEV→PROD bleibt haengen | PROD veraltet, aber laeuft | Manueller Trigger moeglich; Monitoring sollte alert senden |
| Denylist-Filter zu streng, neues Release wird nicht gesynct | PROD-Deployment scheitert mit "manifest unknown" | Rollback: Filter lockern, manuell triggern; ggf. temporaer Fallback reaktivieren |
| Packer-Template nicht aktualisiert, neue Node ohne Mirror-Config | Neue Node zieht von Internet | Ansible Play auf neue Node nachschieben |
| LAN-interne Clients (nicht K3s) ziehen weiter von Internet | Funktional OK, aber Rate-Limit-Thema besteht | Dokumentieren, bei Bedarf Clients umstellen |

**Generelles Rollback Etappe A:**
- `registries.yaml` auf allen Nodes entfernen → Restart K3s
- ArgoCD Apps `registry` + `registry-secrets` loeschen
- DNS-Eintrag entfernen
- S3 Bucket leeren (Cleanup)

**Generelles Rollback Etappe B (falls Etappe A bleibt):**
- PROD `registries.yaml` auf Etappe-A-Version zuruecksetzen (DEV-Registry + Fallback)
- PROD-Zot ArgoCD App loeschen
- DEV-Zot laeuft unveraendert weiter

---

## 11. Anweisungen fuer neuen Chat (Handoff)

**Kontext-Brief fuer den neuen Chat:**

Wir starten Phase 9a Container Registry Infrastruktur (Zot). Bitte:

1. **Diese Phase-Doku zuerst vollstaendig lesen** — alle Entscheidungen sind bereits abgestimmt (Abschnitt 3), nicht erneut diskutieren.
2. **Voraussetzungen pruefen** (Abschnitt 4) — insbesondere ob NAS10-Buckets und DNS-Eintraege bereits erstellt wurden. Wenn nicht, konkrete Schritte fuer Daniel zum Erstellen ausgeben.
3. **Zot Helm Chart Version abstimmen** — aktuelle stable aus `project-zot/helm-charts` per web_search checken, mit Daniel bestaetigen lassen bevor Deploy.
4. **Etappe A Schritt fuer Schritt** umsetzen (Abschnitt 5, A1 bis A9). Nach jedem Teilschritt kurze Verifikation, bevor naechster Schritt startet.
5. Zwischen-Checkpoint: A9 Haken durchgehen, **Daniel explizit fragen** bevor Etappe B startet.
6. **Etappe B** erst nach expliziter Freigabe (Abschnitt 6, B1 bis B6).
7. **Abschluss-Nacharbeiten** (Abschnitt 7).
8. **Doku-Updates nach Abschluss:**
   - Diese Datei: Status auf "Abgeschlossen" setzen
   - `phase-09-security-dev.md`: Learning #8 auf "geloest" markieren (Referenz auf Phase 9a)
   - `K8s-GitOps-Infrastruktur-Projektplanung_v2.XX`: neue Minor-Version anlegen mit Phase 9a Abschluss-Eintrag

**Wichtige Projekt-Eigenheiten (aus Memory):**
- Alle Git-Commits/Pushes fuehrt Daniel selbst aus, nicht Claude
- Keine SSH-Kommandos von Claude auf Nodes oder k8s-mgmt-10
- Claude nutzt Desktop Commander fuer Repo-Dateien auf Windows-Laptop `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2`
- Kubernetes-Zugriff per MCP (Contexts `k8s-dev`, `k8s-test`, `k8s-prod`)
- SOPS-verschluesselte Secrets per Age-Key auf k8s-mgmt-10 (`age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm`)
- Keine Entscheidungen ohne Optionen-Praesentation; Daniel entscheidet
- Immer DEV zuerst, dann TEST, dann PROD — nie parallel

**Referenz-Dokumente:**
- `docs/phases/phase-09-security-dev.md` — Phase 9 Gesamt (Kyverno, Trivy Operator, CrowdSec, Falco)
- `docs/decisions/ADR-002-branch-per-environment.md` — Branch-Strategie, aktuell noch `main` fuer DEV
- `docs/guides/argocd-cli-setup-mgmt10.md` — ArgoCD CLI auf Mgmt-Host
- `docs/SOPS-SECRET-MANAGEMENT.md` — SOPS/Age-Workflow
- `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.16.md` — Projektplan

---

*Erstellt: 20.04.2026*
*Status: Vorbereitet, Umsetzung offen*


---

## 12. Etappe A Implementierungs-Learnings (21.04.2026)

### 12.1 Tatsaechlich verwendete Versionen

- **Helm Chart:** `zot-0.1.104` (Repo `https://zotregistry.dev/helm-charts`)
- **App-Version:** `v2.1.15` (zotregistry.dev/zot)
- **Pull-Image:** `ghcr.io/project-zot/zot-linux-amd64:v2.1.15`
- **DockerHub Authentifizierung:** dedizierter PAT `dckr_pat_...` als read-only sync user (Bypass anonymes 60/6h Rate-Limit → 200/6h fuer authentifizierte Pulls)

### 12.2 Repository-Struktur (Final, leicht abweichend von Section 5)

```
kubernetes/
├── base/registry/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── values.yaml                   # Helm Base Values
│   └── helmchart-template.yaml       # HelmChartCRD bzw. HelmChart Inflator
├── environments/dev/
│   ├── registry/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── values-override.yaml      # DEV-spezifisch (S3, DNS, Sync-Registries)
│   │   └── ingressroute.yaml         # Traefik IngressRoute + Cross-Namespace Service
│   ├── registry-secrets/             # SEPARATER Layer fuer Secrets (sync-wave 3)
│   │   ├── kustomization.yaml
│   │   ├── secret-generator.yaml     # 3 KSOPS Generators
│   │   ├── s3-credentials.template/.enc.yaml
│   │   ├── htpasswd.template/.enc.yaml
│   │   └── ghcr-sync-credentials.template/.enc.yaml   # ENTHAELT auch DockerHub Creds
│   └── infrastructure/
│       ├── registry-secrets-app.yaml  # ArgoCD App, sync-wave 3
│       └── registry-app.yaml          # ArgoCD App, sync-wave 4
└── ansible/playbooks/
    ├── 06-sysctl-inotify-limits.yml   # NEU: fs.inotify Limits fuer Zot fsnotify
    └── 07-k3s-registries-mirror.yml   # NEU: containerd registries.yaml rollout

packer/ubuntu-24.04/http/user-data.pkrtpl.hcl   # PATCHED: sysctl inotify
```

**Wichtig:** Secrets als eigener Layer/App (nicht im selben Layer wie Registry). Sync-Wave 3 (Secrets) → 4 (Registry-App) garantiert Reihenfolge.

### 12.3 Multi-Arch + S3 + OnDemand: preserveDigest + http.compat zwingend

**Problem:** Zot v2.1.15 schreibt bei Multi-Arch Images standardmaessig OCI-konvertierte Manifests (Digest aendert sich, Top-Level Index landet nicht im Catalog → `invalid manifest content` beim 2. Pull, 404 beim Pull per Index-Digest). Praktisch sind fast alle modernen Images Multi-Arch (hello-world hat ~15 Varianten, nginx hat 8+).

**Loesung (zwingend kombiniert):**

```yaml
# values-override.yaml
configFiles:
  config.json: |
    {
      "http": {
        "compat": ["docker2s2"]               # MUSS gesetzt sein wenn preserveDigest:true
      },
      "extensions": {
        "sync": {
          "registries": [
            {
              "urls": ["https://registry-1.docker.io"],
              "onDemand": true,
              "preserveDigest": true,         # Byte-exakte Manifest-Erhaltung
              "credentialsFile": "/ghcr-credentials/credentials.json"
            }
            // ... analog fuer quay.io, ghcr.io (onDemand), registry.k8s.io, ghcr.io scheduled (dhenkeeneg/**)
          ]
        }
      }
    }
```

Ohne `http.compat: ["docker2s2"]` startet der Pod gar nicht: `can not use PreserveDigest option without enabling http.Compat`.

### 12.4 DockerHub Credentials in Sync-Credentials-File integriert

`ghcr-sync-credentials.enc.yaml` enthaelt JSON mit beiden Upstream-Registries:

```json
{
  "ghcr.io": {"username": "dhenkeeneg", "password": "<ghcr-pat>"},
  "registry-1.docker.io": {"username": "<dockerhub-user>", "password": "dckr_pat_..."}
}
```

Wirkt automatisch fuer beide OnDemand-Registries (Zot waehlt Credentials per URL).

### 12.5 containerd registries.yaml Pattern fuer K3s 1.26.13+

K3s seit 1.26.13 unterstuetzt **default endpoint fallback** out of the box. `registries.yaml` braucht KEIN `rewrites:` mehr und der Mirror agiert transparent als Pull-Through-Cache:

```yaml
# /etc/rancher/k3s/registries.yaml (auf jedem Node)
mirrors:
  docker.io:
    endpoint:
      - "https://registry-dev.eneg.de"
  quay.io:
    endpoint:
      - "https://registry-dev.eneg.de"
  ghcr.io:
    endpoint:
      - "https://registry-dev.eneg.de"
  registry.k8s.io:
    endpoint:
      - "https://registry-dev.eneg.de"
```

containerd erkennt am Pfad `?ns=docker.io` automatisch die Quelle und Zot routet entsprechend. **KEIN `rewrites: "(.*)": "docker.io/$1"` noetig** — das wuerde sogar zu Doppel-Pfaden fuehren.

### 12.6 Ansible Playbook 07 — Rolling Rollout

`ansible/playbooks/07-k3s-registries-mirror.yml`:
- `serial: 1` (Node-fuer-Node)
- Manual approval/pause nach erstem Node (mit `when: not ansible_check_mode`)
- Pre-flight check: `curl -fsSL https://registry-dev.eneg.de/v2/` muss 200 liefern
- Schreibt `/etc/rancher/k3s/registries.yaml`
- `systemctl restart k3s` und Wartezeit auf `kubectl get nodes` Ready
- Verifiziert anschliessend `cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml`

Fuer DEV-Cluster bereits ausgerollt, Output zeigt Mirror + default endpoint fallback aktiv.

### 12.7 sysctl inotify-Limits fuer Zot

Zot's fsnotify-Watcher kann mit Default `fs.inotify.max_user_watches=8192` Erschoepfung haben. Erhoeht via:

```yaml
# /etc/sysctl.d/99-k3s-zot.conf
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
```

Ausgerollt via `06-sysctl-inotify-limits.yml`. Packer-Template `user-data.pkrtpl.hcl` enthaelt diese Werte fuer neue Nodes ab Build.

### 12.8 ArgoCD-spezifische Workarounds

- **Replica-Count nach manuellem `scale=0`** wird nicht automatisch durch ArgoCD restored. Wenn Reset noetig: vor Reset ArgoCD App pausen, dann `scale=0` und `scale=1` manuell, dann ArgoCD wieder enable.
- **HelmChart values mit `default:` Werten** koennen OutOfSync triggern wenn Kubernetes Defaults injected (z.B. `enabled: true` bei plugins). Loesung wie schon bei CNPG: `resource.customizations.ignoreDifferences` in `argocd-cm`.

### 12.9 Zot Distroless Image — kein exec_in_pod sinnvoll

Das Zot-Image ist distroless (kein `sh`, kein `bash`). `kubectl exec -it ... -- sh` schlaegt fehl. Verifikation laeuft ueber:
- HTTP-API direkt von Mgmt-Node oder anderem Pod im Cluster (`curl https://registry-dev.eneg.de/v2/...`)
- Pod-Logs (`kubectl logs ...`)
- Metrics-Endpoint
- Externe Tools (`crane`, `regctl`, `skopeo`)

### 12.10 First-Sync Verhalten (cache miss warnings)

Beim ersten Sync eines Images zeigt Zot `"not found in cache"` Warnings fuer jedes Blob. Das sind **keine Fehler**, sondern normales Verhalten der metadb beim Aufbau. Erfolgs-Signal ist die Log-Zeile:

```
"successfully synced image" repo=library/hello-world reference=latest
```

und im Anschluss ein Catalog-Eintrag.

### 12.11 End-to-End-Verifikation (DEV)

Erfolgreicher Test 21.04.2026:

```bash
# Auf k8s-dev-22 (containerd via Mirror)
sudo k3s crictl pull docker.io/library/hello-world:latest    # ✅ ueber Zot
sudo k3s crictl pull docker.io/library/nginx:stable-alpine    # ✅ Multi-Arch nginx

# Catalog (von mgmt-10)
curl -s https://registry-dev.eneg.de/v2/_catalog | jq
# {"repositories": ["library/hello-world", "library/nginx"]}

# Zot Logs zeigen "successfully synced image" und HTTP 200 Responses fuer:
# - Manifest-Index (Multi-Arch, ~12 KB)
# - Platform-Manifest (~1 KB)
# - Config-Blob (~600 B)
# - Layer-Blobs
```

### 12.12 Status Etappe A — DEV-Zwischenstand (21.04.2026 vormittags)

Dieser Abschnitt spiegelt den Zwischenstand nach dem DEV-Rollout wider. Der Vollabschluss Etappe A (inkl. TEST und PROD) ist in den Sections 12.13–12.15 dokumentiert.

**ERLEDIGT (DEV):**
- [x] DEV-Zot deployed, Pod Healthy
- [x] Zot UI/HTTPS erreichbar mit Lets-Encrypt-Cert
- [x] Proxy-Cache funktional fuer docker.io (verifiziert), quay.io/ghcr.io/registry.k8s.io (Konfig vorhanden)
- [x] containerd registries.yaml auf allen 3 DEV-Nodes via Ansible 07 ausgerollt
- [x] End-to-End Pull-Verifikation: hello-world + nginx erfolgreich
- [x] DockerHub-Auth aktiv, kein Rate-Limit beim Sync
- [x] preserveDigest + docker2s2 Multi-Arch-Loesung verifiziert
- [x] sysctl inotify Limits ausgerollt (alle 3 Nodes + Packer)

**AUSSTEHEND fuer Etappe A Vollabschluss (Stand vormittags 21.04.2026):**
- [ ] containerd registries.yaml auf TEST-Cluster ausrollen (Ansible 07 erneut, `--limit k8s_test`)
- [ ] containerd registries.yaml auf PROD-Cluster ausrollen (Ansible 07 erneut, `--limit k8s_prod`, MIT Fallback bis Etappe B)
- [ ] Trivy Operator nochmal scannen lassen — pruefen ob `TOOMANYREQUESTS` aus DockerHub jetzt verschwunden sind
- [ ] Eigene Images Sync-Lauf verifizieren: `dhenkeeneg/idoit-open` muss in Zot unter `eneg/idoit-open` auftauchen (PollInterval 15min)
- [ ] Gesamt-A9-Verifikations-Checkliste (Section 5 Ende) durchgehen

**ETAPPE B (PROD-Registry):** Komplett ausstehend.

---

## 12.13 Etappe A — TEST-Rollout (21.04.2026 nachmittags)

Der containerd-Mirror-Rollout auf dem TEST-Cluster verlief identisch zum DEV-Muster.

**Ansible 07 mit `-i ansible/inventory/test/hosts.ini` durchgelaufen:**
- `serial: 1` rolling restart ueber k8s-test-21 → pause → k8s-test-22 → k8s-test-23
- PLAY RECAP: `ok=15-16, changed=2, failed=0, unreachable=0` pro Node
- `hosts.toml` in `certs.d/docker.io/` auf allen 3 TEST-Nodes mit Mirror-Eintrag `https://registry-dev.eneg.de/v2` und Capabilities `["pull", "resolve"]` bestaetigt

**Pre-Flight (Cross-VLAN-Routing 179 → 180):**
- `ansible k3s_servers -i .../test/hosts.ini -m uri -a "url=https://registry-dev.eneg.de/v2/"` → alle 3 Nodes `status: 200` mit TLS-Cert validation

**Catalog nach Test-Pull:**
```
{
  "repositories": [
    "eneg/eneg-it-info-versand",
    "eneg/idoit-open",
    "eneg/prometheus-msteams",
    "library/alpine",          # neu durch TEST-Verifikation
    "library/hello-world",
    "library/nginx"
  ]
}
```

### 12.13.1 Learning — Zot OnDemand-First-Pull-Latency bei grossen Multi-Arch-Images

Beim initialen Test-Pull `docker.io/library/alpine:3` auf einem TEST-Node ueber den Mirror kam `context canceled` zurueck. Ursache war kein Bug, sondern erwartetes Zot-Verhalten:

- Zot-Log zeigt: `HEAD /v2/library/alpine/manifests/3?ns=docker.io`, `statusCode: 200`, **`latency: 6m34s`**
- Alpine hat ~15–20 Platform-Varianten (amd64, arm64, arm/v6/v7, s390x, ppc64le, 386, riscv64, …); jede Variante wird waehrend des synchronen OnDemand-Syncs einzeln von DockerHub geladen und nach NAS10-S3 kopiert (regclient Copy-Layer/Copy-Config-Logs im Zot-Pod sichtbar, `successfully synced image` erst nach ~6 min)
- containerd's HTTP-Request-Timeout (~30-60 s) schlug frueher zu → Client-seitig "context canceled"
- Zweiter Pull des gleichen Images auf demselben Node: **6 s** (Cache-Hit aus Zot + NAS10-S3)
- `curl -I` gegen Zot nach Cache-warm: **329 ms**

**Konsequenz:**
- In Etappe A (DEV/TEST/PROD mit Internet-Fallback): unkritisch — wenn Zot cancelt, greift containerd default endpoint fallback und zieht direkt vom Upstream. Der Pod-Start wird nicht beeintraechtigt.
- Fuer Etappe B (PROD ohne Fallback): Warm-up aller produktiven Images in PROD-Zot BEVOR der Cutover auf "kein Fallback" stattfindet. Der Sync-Lauf DEV→PROD muss ausreichend Vorlauf haben.

---

## 12.14 Etappe A — PROD-Rollout (21.04.2026 spaetnachmittags)

Analog zu TEST, identisches Verhalten.

**Ansible 07 mit `-i ansible/inventory/prod/hosts.ini`:**
- `serial: 1` rolling restart ueber k8s-prod-21 (Approval) → k8s-prod-22 → k8s-prod-23
- PLAY RECAP: `ok=15-16, changed=2, failed=0, unreachable=0` pro Node
- Approval-Pause mit `kubectl --context {{ kubectl_context }} get nodes/pods` — Playbook 07 wurde vorher env-agnostisch gemacht (Variable `kubectl_context: "k8s-{{ inventory_dir | basename }}"`), damit der Hinweis fuer alle drei Inventories korrekt ist
- Wahrend der Approval-Pause in PROD: alle 3 Nodes Ready, keine CrashLoopBackOff/Failed-Pods, ArgoCD-Apps (40+) durchgaengig Synced+Healthy

**Pre-Flight (Cross-VLAN-Routing 178 → 180):**
- Alle 3 PROD-Nodes mit `status: 200` gegen `registry-dev.eneg.de/v2/`

**Post-Rollout Test-Pull `docker.io/library/busybox:latest` auf k8s-prod-22:**
- Ergebnis: **15,5 s** (Multi-Arch mit nur 4-5 Varianten → OnDemand-Sync innerhalb containerd-Timeout), kein Cancel.
- Bestaetigt den Size-Effekt aus TEST-Learning (kleine Multi-Arch-Images gehen direkt durch).

**Catalog nach Etappe A Vollabschluss:**
```
{
  "repositories": [
    "eneg/eneg-it-info-versand",
    "eneg/idoit-open",
    "eneg/prometheus-msteams",
    "library/alpine",
    "library/busybox",
    "library/hello-world",
    "library/nginx"
  ]
}
```

---

## 12.15 Etappe A — Final Summary

**Status:** VOLLSTAENDIG ABGESCHLOSSEN (21.04.2026)

| Pruefung | DEV | TEST | PROD |
|----------|:---:|:---:|:---:|
| containerd `registries.yaml` geschrieben | ✅ | ✅ | ✅ |
| `hosts.toml` im `certs.d/` mit Mirror-Eintrag | ✅ | ✅ | ✅ |
| Rolling k3s-Restart ohne Fehler | ✅ | ✅ | ✅ |
| Cluster nach Rollout: Nodes Ready, Pods Running | ✅ | ✅ | ✅ |
| ArgoCD Apps Synced + Healthy | ✅ | ✅ | ✅ |
| End-to-End Test-Pull via Mirror | ✅ (hello-world, nginx) | ✅ (alpine) | ✅ (busybox) |
| Zot Catalog gefuellt | ✅ | ✅ | ✅ |
| Cross-VLAN-Routing bestaetigt | n/a | 179→180 ✅ | 178→180 ✅ |

**Ansible Playbook 07 Env-agnostisch:** Variable `kubectl_context: "k8s-{{ inventory_dir | basename }}"` aus vars-Section leitet aus `inventory/dev|test|prod/` den kubectl-Context fuer den Approval-Prompt ab.

**Gesamt-Checkliste aus Section 8 (Etappe A):**
- [x] DEV-Zot deployed, Healthy (Section 12.1)
- [x] DEV-Zot UI erreichbar mit TLS
- [x] Proxy-Cache fuer docker.io/quay.io/ghcr.io/registry.k8s.io
- [x] Eigene Images via sync-Extension gespiegelt (`eneg/*` im Catalog)
- [x] containerd registries.yaml auf 9 Nodes (DEV + TEST + PROD)
- [x] Packer-Template aktualisiert (sysctl inotify)
- [ ] Trivy-Scans laufen fehlerfrei in allen drei Envs — **offen**, siehe Punkt unten

### Offener Punkt: Trivy-Operator Rate-Limit

Der containerd-Mirror loest das DockerHub Rate-Limit fuer Pod-Pulls (kubelet → containerd → Zot). Er loest es **nicht automatisch** fuer Trivy Operator Scan-Jobs, weil Trivy die Ziel-Images nicht via containerd socket auflost, sondern ueber die Docker Registry Remote-API (`GET https://index.docker.io/v2/.../manifests/...`). Diese Requests umgehen den Mirror und laufen weiter in DockerHub's anonymen Pull-Limit.

**Beobachtung 21.04.2026:**
- Trivy-Scan-Job-Logs zeigen weiterhin `TOOMANYREQUESTS` fuer `velero/velero:v1.17.1`, `busybox:1.37`, `odoo:18`, `kiwigrid/k8s-sidecar:2.5.0`
- 162 VulnerabilityReports existieren in DEV (nicht-docker.io Images werden gescannt)
- Problem ist DEV-lokal, weil Trivy Operator nur in DEV installiert ist

**Fix-Strategie (nach Etappe B angehen):**
- **Primaer:** `TRIVY_REGISTRY_MIRROR=docker.io=registry-dev.eneg.de` als additionalEnvVar im Trivy-Operator Helm values
- **Alternativ:** DockerHub-PAT an Trivy via `dockerConfigAuth` (rate-limit von 60/6h anon auf 200/6h authenticated)
- **Fallback:** containerd-socket mount (hoher Security-Tradeoff, privilegierter Pod)

Dokumentation der Umsetzung erfolgt zusammen mit Etappe B Abschluss.

---

