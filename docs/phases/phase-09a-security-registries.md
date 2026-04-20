# Phase 9a: Container Registry Infrastruktur (Zot)

**Status:** Vorbereitet, zur Umsetzung freigegeben
**Abstimmung abgeschlossen:** 20.04.2026
**Phase 9 Uebersicht:** Kyverno + Trivy Operator DEV abgeschlossen; **Phase 9a (dieses Dokument)** eingeschoben; CrowdSec + Falco folgen als Phase 9b
**Voraussetzungen:** Phase 7 (Monitoring), Phase 8 (TEST/PROD), Phase 10 (Velero), Phase 9 Schritt 1+2 (Kyverno + Trivy Operator in DEV)

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
