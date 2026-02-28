# Phase 6: Pilot-App Deployment

**Status:** 🔄 In Bearbeitung
**Gestartet am:** 25.02.2026
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Zusammenfassung

Phase 6 baut auf der in Phase 5 erstellten Datenbank-Infrastruktur auf und
deployt die ersten Pilot-Anwendungen in den DEV-Cluster. Als Infrastruktur-
Vorbereitung wurde zunaechst Garage S3 Object Storage im Cluster deployed,
um spaetere Anwendungen (OpenProject, Odoo) mit S3-kompatiblem Speicher zu
versorgen. Jede App erhaelt eine eigene Datenbank, einen dedizierten DB-User
mit eigenem Secret und eine vollstaendige Ingress-Konfiguration mit TLS-
Zertifikat. Das Deployment erfolgt GitOps-konform ueber ArgoCD mit Raw
Kubernetes Manifests.

---

## Architektur-Entscheidungen

### Deployment-Methode: Raw Kubernetes Manifests (kein Helm)

**Entscheidung:** Alle Pilot-Apps werden als Raw Manifests deployed.

**Begruendung:**
- n8n hat kein offizielles Helm Chart; Community-Charts (8gears) nutzen
  OCI-Registry und haben Kompatibilitaetsluecken mit n8n 2.x
- Raw Manifests geben volle Kontrolle ueber alle Ressourcen
- Konsistent mit dem bestehenden Ingress/Certificate-Pattern aus Phase 4
- Einfacher zu debuggen und anzupassen als Helm-Templates
- Spaeterer Wechsel auf Helm ist jederzeit moeglich

### DB-User-Strategie: Dedizierte Rollen pro App

**Entscheidung:** Jede App erhaelt einen eigenen PostgreSQL-User bzw.
MariaDB-User mit eigenem SOPS-verschluesseltem Secret — in allen
Umgebungen (DEV, TEST, PROD).

**Begruendung:**
- Least-Privilege-Prinzip: Jede App kann nur ihre eigene Datenbank sehen
- Sicherheit: Kompromittierte App-Credentials gefaehrden nicht andere DBs
- Audit: Datenbankzugriffe sind pro App nachvollziehbar
- Konsistenz: Gleiche Architektur in DEV, TEST und PROD

**Implementierung PostgreSQL (CNPG):**
- Rollen werden deklarativ ueber `managed.roles` in der Cluster-CRD definiert
- Passwoerter werden als SOPS-verschluesselte Kubernetes Secrets gespeichert
- CNPG referenziert die Secrets ueber `passwordSecret` in der Rollen-Definition
- Database CRD setzt die Rolle als Owner der jeweiligen Datenbank

**Implementierung MariaDB (Galera):**
- `Database`, `User` und `Grant` CRDs des mariadb-operator
- Passwoerter als SOPS-verschluesselte Kubernetes Secrets

### Ingress-Pattern: Standard aus Phase 4

Alle Apps folgen dem etablierten Pattern:
- Certificate + IngressRoute im **traefik** Namespace
- Backend-Service wird **cross-namespace** referenziert
- TLS-Terminierung durch Traefik, Backend laeuft auf HTTP

### Secrets-Pattern: Zwei getrennte Secrets pro App

**Entscheidung:** Jede App benoetigt zwei SOPS-verschluesselte Secrets:

1. **DB-Credentials** (Namespace: `databases`) — fuer CNPG managed.roles
2. **App-Secrets** (Namespace: `<app>`) — DB-Passwort (Kopie) + App-spezifische Keys

**Begruendung:** Kubernetes erlaubt keine Cross-Namespace Secret-Referenzen.
Das DB-Passwort muss sowohl im `databases` Namespace (fuer CNPG Role) als
auch im App-Namespace (fuer die App-Umgebungsvariablen) vorliegen. Beide
Secrets werden getrennt mit SOPS verschluesselt und via KSOPS deployed.

---

## Deployment-Reihenfolge

| Schritt | Beschreibung | Status |
|---|---|---|
| 6.1 | n8n: DB-Rolle + Database + Secrets + Deployment + Ingress | ✅ Abgeschlossen |
| 6.1b | Garage S3: In-Cluster Object Storage (3-Node, Replication 2) | ✅ Abgeschlossen |
| 6.1c | Garage S3 Backup: Taegliches Backup auf NAS10 via rclone | ✅ Abgeschlossen |
| 6.2 | OpenProject: DB-Rolle + Database + Deployment + Ingress + S3 + Hocuspocus | ✅ Abgeschlossen |
| 6.3 | Odoo 18 CE: DB-Rolle + Database + Deployment + Ingress + Filestore-Backup | 🔄 In Vorbereitung |
| 6.4 | Keycloak: DB-Rolle + Database + Deployment + Ingress | 🔲 Offen |
| 6.5 | Weitere Apps nach Bedarf | 🔲 Offen |
| 6.6 | Validierung + Dokumentation | 🔲 Offen |

---

## Architektur pro App

```
                    ┌──────────────────────────┐
                    │  traefik namespace        │
                    │  ├── Certificate          │
                    │  └── IngressRoute         │
                    │       (<app>-dev-v2.eneg.de)│
                    └──────────┬───────────────┘
                               │ cross-namespace (HTTP)
                    ┌──────────▼───────────────┐
                    │  <app> namespace          │
                    │  ├── Deployment           │
                    │  ├── Service (ClusterIP)  │
                    │  ├── PVC (Longhorn)       │
                    │  └── Secret (SOPS)        │
                    │       (db-password +      │
                    │        app-specific keys) │
                    └──────────┬───────────────┘
                               │ TCP :5432 / :3306
                    ┌──────────▼───────────────┐
                    │  databases namespace      │
                    │  ├── Database CRD         │
                    │  ├── Role (managed.roles) │
                    │  └── Password Secret      │
                    │       (SOPS, fuer CNPG)   │
                    └──────────────────────────┘
```

---

## ArgoCD Sync-Wave Reihenfolge

| Wave | Application | Beschreibung |
|---|---|---|
| 4 | cnpg-secrets | DB-Passwoerter + S3-Credentials (KSOPS) |
| 4 | garage-secrets | RPC Secret, Admin Token, Metrics Token, WebUI Auth (KSOPS) |
| 5 | cnpg-cluster | PostgreSQL Cluster + managed.roles |
| 5 | garage | Garage S3 StatefulSet, Services, WebUI, Ingress |
| 6 | cnpg-databases | Database CRDs (n8n, etc.) |
| 7 | n8n-secrets | App-Secrets: Encryption Key + DB-Passwort (KSOPS) |
| 7 | openproject-secrets | App-Secrets: SECRET_KEY_BASE, Hocuspocus, DB-URL, S3-Keys (KSOPS) |
| 7 | odoo-secrets | App-Secrets: Admin-Passwort + DB-Passwort (KSOPS) |
| 7 | garage-backup-secrets | Backup-Credentials: Garage + NAS10 S3-Keys (KSOPS) |
| 8 | n8n | App-Deployment: Namespace, Deployment, Service, PVC, Ingress |
| 8 | openproject | App-Deployment: Namespace, Web, Worker, Memcached, Hocuspocus, PVC, Ingress |
| 8 | odoo | App-Deployment: Namespace, Deployment, Service, PVC, ConfigMap, Ingress |
| 8 | garage-backup | CronJob: Taegliches rclone Backup Garage -> NAS10 |

---

## Abgeschlossene Deployments

### 6.1 — n8n Workflow-Automation ✅

**Abgeschlossen am:** 25.02.2026
**URL:** https://n8n-dev-v2.eneg.de
**Version:** n8nio/n8n:2.8.4 (Community Edition)

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| Database CRD | databases | n8n | ✅ Erstellt |
| Managed Role | databases | n8n (auf cnpg-shared) | ✅ Login aktiv |
| Secret (DB) | databases | n8n-db-credentials | ✅ SOPS/KSOPS |
| Namespace | n8n | n8n | ✅ Erstellt |
| Secret (App) | n8n | n8n-secrets | ✅ SOPS/KSOPS |
| PVC | n8n | n8n-data (5Gi Longhorn) | ✅ Bound |
| Deployment | n8n | n8n (1 Replica) | ✅ Running |
| Service | n8n | n8n (ClusterIP:5678) | ✅ Active |
| Certificate | traefik | n8n-tls | ✅ Ready (Let's Encrypt) |
| IngressRoute | traefik | n8n | ✅ Active |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| cnpg-databases | Synced | Healthy | 6 |
| n8n-secrets | Synced | Healthy | 7 |
| n8n | Synced | Healthy | 8 |

#### n8n Umgebungsvariablen

| Variable | Wert | Quelle |
|---|---|---|
| DB_TYPE | postgresdb | Env |
| DB_POSTGRESDB_HOST | cnpg-shared-rw.databases.svc.cluster.local | Env |
| DB_POSTGRESDB_PORT | 5432 | Env |
| DB_POSTGRESDB_DATABASE | n8n | Env |
| DB_POSTGRESDB_USER | n8n | Env |
| DB_POSTGRESDB_PASSWORD | (verschluesselt) | Secret: n8n-secrets/db-password |
| N8N_ENCRYPTION_KEY | (verschluesselt) | Secret: n8n-secrets/encryption-key |
| N8N_HOST | n8n-dev-v2.eneg.de | Env |
| N8N_PROTOCOL | https | Env |
| N8N_PORT | 5678 | Env |
| N8N_EDITOR_BASE_URL | https://n8n-dev-v2.eneg.de | Env |
| WEBHOOK_URL | https://n8n-dev-v2.eneg.de | Env |
| GENERIC_TIMEZONE | Europe/Berlin | Env |
| TZ | Europe/Berlin | Env |

#### n8n Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 250m | 1 |
| Memory | 256Mi | 512Mi |
| PVC | 5Gi (Longhorn) | - |

#### n8n Hinweise

- **Community Edition:** Nur ein User (Owner) moeglich, keine Team-Features
- **securityContext:** Erforderlich wegen n8n User `node` (UID/GID 1000),
  Longhorn Volumes werden standardmaessig als root gemountet
- **Deployment-Strategie:** `Recreate` (nicht RollingUpdate) da PVC
  mit ReadWriteOnce nur von einem Pod gleichzeitig gemountet werden kann

---

### 6.1b — Garage S3 Object Storage ✅

**Abgeschlossen am:** 26.02.2026
**S3 API:** https://s3-dev-v2.eneg.de
**WebUI:** https://s3-gui-dev-v2.eneg.de
**Version:** dxflrs/garage:v2.2.0 (AGPL v3)
**WebUI-Version:** khairul169/garage-webui:1.1.0

#### Hintergrund und Entscheidung

Garage wurde als In-Cluster S3-kompatibler Object Storage deployed, um
spaetere Anwendungen (OpenProject, Odoo, Nextcloud) mit S3-Speicher zu
versorgen. Im Gegensatz zum externen NAS (nas10.eneg.de/QuObject) laeuft
Garage direkt im Cluster und ist damit Teil der GitOps-verwalteten
Infrastruktur.

**Warum Garage statt MinIO:**
- Leichtgewichtig: Weniger Ressourcen, ideal fuer DEV/TEST
- Einfache Konfiguration ueber TOML
- Multi-Node Replication ohne komplexe Erasure-Coding-Konfiguration
- AGPL v3 Lizenz, aktiv gepflegt

#### Cluster-Konfiguration

| Parameter | DEV/TEST | PROD |
|---|---|---|
| Replicas | 3 | 3 |
| Replication Factor | 2 | 3 |
| Storage (Data/Pod) | 20Gi | 100Gi |
| Storage (Meta/Pod) | 1Gi | 5Gi |
| Region | eu-central-1 | eu-central-1 |
| Addressing | Path-Style | Path-Style |
| Effective Capacity | ~30 GB | ~300 GB |

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| Namespace | garage | garage | ✅ Erstellt |
| ConfigMap | garage | garage-config | ✅ garage.toml |
| StatefulSet | garage | garage (3 Replicas) | ✅ Running |
| Service (Headless) | garage | garage-headless | ✅ Active |
| Service (S3 API) | garage | garage-s3 (Port 3900) | ✅ Active |
| Service (Admin API) | garage | garage-admin (Port 3903) | ✅ Active |
| Secret | garage | garage-secrets | ✅ SOPS/KSOPS |
| Deployment | garage | garage-webui (1 Replica) | ✅ Running |
| Service | garage | garage-webui (Port 3909) | ✅ Active |
| Certificate | traefik | garage-s3-tls | ✅ Ready |
| Certificate | traefik | garage-webui-tls | ✅ Ready |
| IngressRoute | traefik | garage-s3 | ✅ Active |
| IngressRoute | traefik | garage-webui | ✅ Active |
| PVC (x3) | garage | garage-data-garage-{0,1,2} (20Gi) | ✅ Bound |
| PVC (x3) | garage | garage-meta-garage-{0,1,2} (1Gi) | ✅ Bound |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| garage-secrets | Synced | Healthy | 4 |
| garage | Synced | Healthy | 5 |

#### Secrets (SOPS-verschluesselt)

| Key | Beschreibung | Generierung |
|---|---|---|
| RPC_SECRET | Inter-Node Kommunikation | `openssl rand -hex 32` |
| ADMIN_TOKEN | Admin API / CLI | `openssl rand -hex 32` |
| METRICS_TOKEN | Prometheus Metrics | `openssl rand -hex 32` |
| WEBUI_ADMIN_PASSWORD | WebUI Basic Auth | htpasswd bcrypt |

#### Architektur: StatefulSet mit Init-Container

Das Garage-Image (`dxflrs/garage:v2.2.0`) ist minimal und enthaelt keine
DNS-Resolution-Libraries. Daher wird ein Init-Container (busybox:1.37)
verwendet, der:

1. Die ConfigMap-Vorlage kopiert und Platzhalter ersetzt
2. DNS-Lookups fuer alle Peer-Hostnamen durchfuehrt und zu IPs aufloest
3. Die Pod-IP via Downward API in `rpc_public_addr` einsetzt

```
Pod-Startup:
  init-config (busybox:1.37)
    -> Kopiert garage.toml von ConfigMap
    -> Loest DNS: garage-{0,1,2}.garage-headless -> IP
    -> Ersetzt Platzhalter (__POD_IP__, Hostnames -> IPs)
    -> Schreibt finale Config nach /etc/garage/garage.toml
  garage (dxflrs/garage:v2.2.0)
    -> Liest /etc/garage/garage.toml
    -> Verbindet sich zu Peers ueber bootstrap_peers (IPs)
```

#### Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 100m | 1 |
| Memory | 128Mi | 512Mi |
| PVC Data | 20Gi (Longhorn) | - |
| PVC Meta | 1Gi (Longhorn) | - |

#### Einmaliges Cluster-Setup (nach erstem Deployment)

Nach dem ersten Start muessen die Nodes manuell verbunden und das Layout
zugewiesen werden:

```bash
# Node IDs abfragen
kubectl exec -n garage garage-{0,1,2} -- /garage node id

# Nodes verbinden (von garage-0 aus)
kubectl exec -n garage garage-0 -- /garage node connect <NODE_ID>@<IP>:3901

# Layout zuweisen
kubectl exec -n garage garage-0 -- /garage layout assign <SHORT_ID> -z dc1 -c 20GB
kubectl exec -n garage garage-0 -- /garage layout apply --version 1
```

#### Key Learnings Garage

1. **Minimal Container Images:** Statisch kompilierte Rust-Binaries haben oft
   keine DNS-Resolution-Libraries. Init-Container mit busybox fuer DNS-Lookups.
2. **publishNotReadyAddresses:** Essentiell fuer StatefulSet Peer-Discovery
   bei Headless Services, da DNS-Eintraege sonst erst nach Readiness verfuegbar.
3. **Downward API fuer Pod-IP:** `rpc_public_addr` muss die Pod-IP enthalten,
   nicht den Hostnamen, da Garage selbst keine DNS-Aufloesung kann.
4. **ArgoCD VolumeClaimTemplate Drift:** Kubernetes ergaenzt automatisch
   `apiVersion` und `kind` in VCTs. Loesung: `ignoreDifferences` in der
   ArgoCD Application fuer StatefulSet VolumeClaimTemplates.

---

## DNS-Eintraege

| Hostname | Typ | Ziel | App | Status |
|---|---|---|---|---|
| n8n-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | n8n | ✅ Aktiv |
| s3-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | Garage S3 API | ✅ Aktiv |
| s3-gui-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | Garage WebUI | ✅ Aktiv |
| openproject-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | OpenProject | ✅ Aktiv |
| odoo-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | Odoo 18 CE | 🔲 Vorbereitet |
| idoit-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | i-doit | 🔲 Vorbereitet |

---

## Backup-Abdeckung

Alle neuen Datenbanken sind automatisch durch die bestehende Backup-Strategie
aus Phase 5 abgedeckt:

| Backup-Typ | Abdeckung | Begruendung |
|---|---|---|
| WAL-Archivierung | ✅ Automatisch | Laeuft auf Cluster-Ebene |
| Physical Backup (Barman) | ✅ Automatisch | ScheduledBackup auf Cluster-Ebene |
| Logical Backup (pg_dumpall) | ✅ Automatisch | Dumpt alle DBs inkl. neuer |

**Keine Konfigurationsaenderung an den Backups noetig.**

---

## Key Learnings

### 1. Longhorn Volumes und Non-Root Container

Longhorn Volumes werden standardmaessig mit Root-Ownership gemountet.
Apps die als Non-Root User laufen (z.B. n8n als UID 1000) erhalten
`EACCES: permission denied`. **Loesung:** `securityContext` im Pod-Spec:

```yaml
spec:
  securityContext:
    fsGroup: 1000
    runAsUser: 1000
    runAsGroup: 1000
```

### 2. Cross-Namespace Secrets nicht moeglich

Kubernetes erlaubt keine Secret-Referenzen ueber Namespace-Grenzen.
Wenn eine DB-Rolle (databases NS) und eine App (eigener NS) dasselbe
Passwort brauchen, muss das Secret in beiden Namespaces existieren.
Pattern: Zwei getrennte SOPS-Secrets mit identischem Passwort.

### 3. CNPG Managed Roles — Defaults explizit angeben

CNPG ergaenzt Default-Werte (`connectionLimit: -1`, `ensure: present`,
`inherit: true`) automatisch. Bei ServerSideApply fuehrt das zu einem
permanenten OutOfSync in ArgoCD. **Loesung:** Defaults explizit in
der Cluster-CRD angeben.

### 4. ServerSideApply und --force sind inkompatibel

ArgoCD mit `ServerSideApply=true` kann nicht mit `--force` gesynct werden.
Fehlermeldung: `--force cannot be used with --server-side`. Bei OutOfSync
durch Default-Werte stattdessen die Manifeste anpassen.

### 5. SOPS Age-Key Symlink auf Management-Server

SOPS sucht den Age-Key im Standard-Pfad `~/.config/sops/age/keys.txt`.
Wenn der Key an anderer Stelle liegt (z.B. im Repo unter `.age/key.txt`),
einen Symlink setzen:

```bash
mkdir -p ~/.config/sops/age/
ln -s ~/git/eneg-k8s-infrastructure-v2/.age/key.txt ~/.config/sops/age/keys.txt
```

### 6. ArgoCD Cache bei neuen KSOPS-Secrets

Wenn ein neues SOPS-verschluesseltes Secret zum Repository hinzugefuegt wird,
erkennt ArgoCD die Datei moeglicherweise nicht sofort. **Loesung:** Hard Refresh
auf der betroffenen Application erzwingen:

```bash
kubectl -n argocd patch application <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### 7. Minimal Container Images und DNS-Resolution

Statisch kompilierte Binaries (z.B. Rust/Garage) bringen keine System-DNS-
Libraries mit. Hostnamen in Konfigurationsdateien werden nicht aufgeloest.
**Loesung:** Init-Container mit busybox fuer DNS-Lookups, Ergebnisse (IPs)
werden in die Konfigurationsdatei eingesetzt.

### 8. StatefulSet Headless Service: publishNotReadyAddresses

Headless Services veroeffentlichen DNS-Eintraege erst wenn Pods Ready sind.
Fuer Peer-Discovery bei StatefulSets (Henne-Ei-Problem) muss
`publishNotReadyAddresses: true` gesetzt werden.

### 9. ArgoCD ignoreDifferences fuer StatefulSet VolumeClaimTemplates

Kubernetes ergaenzt automatisch `apiVersion` und `kind` in VolumeClaimTemplates.
Das fuehrt zu permanentem OutOfSync in ArgoCD. **Loesung:**

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /spec/volumeClaimTemplates
```

---

## Dateistruktur (aktuell)

```
kubernetes/
├── base/
│   ├── cloudnative-pg/
│   │   ├── cluster/
│   │   │   ├── cnpg-shared.yaml          # + managed.roles: n8n
│   │   │   └── cnpg-erp.yaml
│   │   ├── databases/
│   │   │   └── n8n-database.yaml          # Database CRD
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml      # KSOPS: s3 + n8n-db
│   │       ├── s3-credentials.enc.yaml
│   │       ├── n8n-db-credentials.enc.yaml
│   │       └── *.yaml.template            # Vorlagen (nicht committet)
│   ├── garage/
│   │   ├── namespace.yaml
│   │   ├── configmap.yaml                 # garage.toml mit Platzhaltern
│   │   ├── statefulset.yaml               # 3 Replicas, Init-Container
│   │   ├── services.yaml                  # Headless + ClusterIP (S3, Admin)
│   │   ├── webui-deployment.yaml          # WebUI + Service
│   │   ├── ingress.yaml                   # Certificates + IngressRoutes
│   │   ├── backup/
│   │   │   ├── cronjob.yaml               # rclone CronJob + ConfigMap
│   │   │   └── secrets/
│   │   │       ├── kustomization.yaml
│   │   │       ├── secret-generator.yaml
│   │   │       ├── garage-backup-credentials.enc.yaml
│   │   │       └── garage-backup-credentials.yaml.template
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml      # KSOPS
│   │       ├── garage-secrets.enc.yaml
│   │       └── garage-secrets.yaml.template
│   └── apps/
│       ├── n8n/
│       │   ├── namespace.yaml
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── ingress.yaml               # Certificate + IngressRoute
│       │   └── secrets/
│       │       ├── kustomization.yaml
│       │       ├── secret-generator.yaml
│       │       ├── n8n-secrets.enc.yaml
│       │       └── n8n-secrets.yaml.template
│       └── openproject/
│           ├── namespace.yaml
│           ├── deployment.yaml            # PVC, Memcached, Hocuspocus, Web, Worker, Seeder
│           ├── service.yaml
│           ├── ingress.yaml               # Certificate + IngressRoute (inkl. WebSocket)
│           └── secrets/
│               ├── kustomization.yaml
│               ├── secret-generator.yaml
│               ├── openproject-secrets.enc.yaml
│               └── openproject-secrets.yaml.template
└── environments/
    └── dev/
        └── infrastructure/
            ├── garage-secrets-app.yaml    # ArgoCD App (Wave 4)
            ├── garage-backup-secrets-app.yaml # ArgoCD App (Wave 4)
            ├── garage-app.yaml            # ArgoCD App (Wave 5)
            ├── garage-backup-app.yaml     # ArgoCD App (Wave 6)
            ├── cnpg-databases-app.yaml    # ArgoCD App (Wave 6)
            ├── n8n-secrets-app.yaml       # ArgoCD App (Wave 7)
            ├── openproject-secrets-app.yaml # ArgoCD App (Wave 7)
            ├── n8n-app.yaml               # ArgoCD App (Wave 8)
            ├── openproject-app.yaml       # ArgoCD App (Wave 8)
            └── ... (bestehende Apps)
```

---

## Skalierung ueber Umgebungen (spaeter)

| Parameter | DEV | TEST | PROD |
|---|---|---|---|
| n8n Replicas | 1 | 1 | 1 (oder Queue Mode) |
| n8n CPU Request | 250m | 500m | 500m |
| n8n Memory Request | 256Mi | 512Mi | 512Mi |
| n8n PVC | 5Gi | 10Gi | 20Gi |

---

### 6.1c — Garage S3 Backup auf NAS10 ✅

**Abgeschlossen am:** 26.02.2026
**Backup-Frequenz:** Taeglich um 04:00 Uhr (Europe/Berlin)
**Backup-Ziel:** NAS10 QuObject S3 (http://nas10.eneg.de:8010)
**Ziel-Bucket:** k8s-dev-garage-backup
**Tool:** rclone/rclone:1.73.1

#### Architektur-Entscheidung

Garage hat kein natives Cross-S3-Backup. Stattdessen wird ein Kubernetes
CronJob mit rclone verwendet, der alle Garage-Buckets taeglich auf NAS10
QuObject S3 synchronisiert.

**Backup-Strategie:** `rclone sync` mit `--backup-dir` Pattern:
- Aktuelle Dateien: `nas10:k8s-dev-garage-backup/<bucket>/`
- Geaenderte/geloeschte Dateien: `nas10:k8s-dev-garage-backup/_backups/YYYY-MM-DD/<bucket>/`
- Retention: 32 Tage (aeltere Backup-Dirs werden automatisch geloescht)
- Checksum-basierter Vergleich (`--checksum`)

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| ConfigMap | garage | garage-backup-config | ✅ rclone.conf + backup.sh |
| CronJob | garage | garage-backup | ✅ 0 4 * * * |
| Secret | garage | garage-backup-credentials | ✅ SOPS/KSOPS |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| garage-backup-secrets | Synced | Healthy | 4 |
| garage-backup | Synced | Healthy | 6 |

#### Garage Keys fuer Backup

| Key Name | Key ID | Berechtigungen | Verwendung |
|---|---|---|---|
| garage-backup-readonly | GK809336104c0cff5a11f5e59c | Read | Backup liest alle Buckets |

#### Key Learnings Garage Backup

1. **rclone -v und --log-level sind inkompatibel:** Fuehrt zu sofortigem Crash.
   Nur eines von beiden verwenden.
2. **NAS10 S3 Endpoint:** Verwendet HTTP auf Port 8010 (nicht HTTPS:9000).
3. **BusyBox date:** Alpine/rclone Image nutzt BusyBox, das weder GNU
   `date -d "-32 days"` noch BSD `date -v-32d` unterstuetzt. Loesung:
   `date -d "@$(($(date +%s) - 32*86400))" +%Y-%m-%d`

---

### 6.2 — OpenProject Projektmanagement ✅

**Abgeschlossen am:** 26.02.2026
**URL:** https://openproject-dev-v2.eneg.de
**Version:** openproject/openproject:17.1.2-slim (Update 27.02.2026, vorher 17.1.1)
**Hocuspocus:** openproject/hocuspocus:latest (Collaborative Editing)
**Default-Login:** admin / admin (Passwortaenderung beim ersten Login)

#### Architektur

OpenProject wird als Multi-Container-Deployment betrieben:

```
Browser (wss://openproject-dev-v2.eneg.de/hocuspocus)
    |
    v
Traefik (TLS-Terminierung)
    |
    ├── /hocuspocus/* → openproject-hocuspocus:1234 (WebSocket)
    └── /* → openproject-web:8080 (HTTP)
                  |
                  ├── Memcached (localhost:11211) — Rails Cache
                  ├── PostgreSQL (cnpg-erp-rw:5432) — Datenbank
                  └── Garage S3 (garage-s3:3900) — Attachments
```

**Komponenten:**
- **Web:** Rails Application Server (Puma), Port 8080
- **Worker:** Background Jobs (E-Mails, Benachrichtigungen, Exports)
- **Memcached:** Rails Cache Store (eigenes Deployment)
- **Hocuspocus:** Real-Time Collaboration Server (separates Image), Port 1234
- **Seeder:** Einmaliger ArgoCD PostSync Hook (DB-Migration + Seed-Daten)

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| Database CRD | databases | openproject | ✅ Erstellt |
| Managed Role | databases | openproject (auf cnpg-erp) | ✅ Login aktiv |
| Secret (DB) | databases | openproject-db-credentials | ✅ SOPS/KSOPS |
| Namespace | openproject | openproject | ✅ Erstellt |
| Secret (App) | openproject | openproject-secrets | ✅ SOPS/KSOPS |
| PVC | openproject | openproject-tmp (5Gi Longhorn) | ✅ Bound |
| Deployment | openproject | openproject-web (1 Replica) | ✅ Running |
| Deployment | openproject | openproject-worker (1 Replica) | ✅ Running |
| Deployment | openproject | openproject-memcached (1 Replica) | ✅ Running |
| Deployment | openproject | openproject-hocuspocus (1 Replica) | ✅ Running |
| Service | openproject | openproject-web (ClusterIP:8080) | ✅ Active |
| Service | openproject | openproject-memcached (ClusterIP:11211) | ✅ Active |
| Service | openproject | openproject-hocuspocus (ClusterIP:1234) | ✅ Active |
| Certificate | traefik | openproject-tls | ✅ Ready (Let's Encrypt) |
| IngressRoute | traefik | openproject | ✅ Active (inkl. WebSocket) |
| Job (PostSync) | openproject | openproject-seeder | ✅ Completed |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| cnpg-databases | Synced | Healthy | 6 |
| openproject-secrets | Synced | Healthy | 7 |
| openproject | Synced | Healthy | 8 |

#### S3 Storage (Garage)

| Parameter | Wert |
|---|---|
| Bucket | openproject-assets |
| Key Name | openproject-app |
| Key ID | GK50841c65af761abbb7f9126c |
| Berechtigungen | Read + Write + Owner |
| Endpoint (intern) | http://garage-s3.garage.svc.cluster.local:3900 |
| Region | eu-central-1 |
| Path-Style | true |

#### OpenProject Secrets (SOPS-verschluesselt)

| Key | Beschreibung | Generierung |
|---|---|---|
| secret-key-base | Rails Secret Key | `openssl rand -hex 64` |
| hocuspocus-secret | Shared Secret Web ↔ Hocuspocus | `openssl rand -hex 32` |
| database-url | PostgreSQL Connection String | Manuell zusammengesetzt |
| s3-access-key-id | Garage Key ID | Garage CLI |
| s3-secret-access-key | Garage Secret Key | Garage CLI |

#### Resources (DEV)

| Komponente | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|
| Web | 500m | 2 | 1Gi | 2Gi |
| Worker | 250m | 1 | 512Mi | 1Gi |
| Memcached | 50m | 250m | 64Mi | 192Mi |
| Hocuspocus | 100m | 500m | 128Mi | 256Mi |

#### Key Learnings OpenProject

1. **Slim-Image hat kein Hocuspocus:** Das `-slim` Tag enthaelt nur die Rails-App.
   Hocuspocus muss als separates Image (`openproject/hocuspocus:latest`) deployed
   werden, nicht mit dem OpenProject-Image und `/app/docker/prod/hocuspocus`.

2. **Hocuspocus Port:** Das separate Hocuspocus-Image lauscht auf Port 1234
   (nicht 4000 wie in aelteren Versionen).

3. **WebSocket-Route noetig:** Die Hocuspocus-URL muss vom Browser erreichbar sein.
   Interne Cluster-URLs (`ws://...svc.cluster.local`) funktionieren nicht.
   Loesung: Dedizierte IngressRoute mit PathPrefix `/hocuspocus` in Traefik.

4. **DATABASE_URL Sonderzeichen:** Passwoerter mit `+`, `/`, `=` etc. muessen
   URL-encoded werden oder (einfacher) nur alphanumerische Passwoerter verwenden
   (`openssl rand -hex 24`).

5. **DB-Migration vor erstem Start:** OpenProject startet nicht ohne Datenbankschema.
   Der Seeder-Job (PostSync Hook) kann blockiert sein wenn die App nie healthy wird.
   Loesung: Einmalige manuelle Migration via `kubectl run`.

6. **CNPG Managed Role Passwort-Update:** Nach Passwortaenderung muss der
   CNPG-Cluster die neue Role uebernehmen. Status pruefbar ueber
   `kubectl get cluster cnpg-erp -n databases -o jsonpath='{.status.managedRolesStatus}'`

---

## Naechste Schritte

- Odoo 18 CE deployen (cnpg-erp, Multi-Process, PVC-Filestore mit Backup)
- Keycloak deployen (cnpg-shared)
- Weitere Apps nach Bedarf

---

## Aenderungshistorie

| Datum | Aenderung |
|---|---|
| 25.02.2026 | Initiale Version (Planungsdokument) |
| 25.02.2026 | n8n erfolgreich deployed (Schritt 6.1 abgeschlossen) |
| 26.02.2026 | Garage S3 v2.2.0 deployed (Schritt 6.1b abgeschlossen) |
| 26.02.2026 | Garage S3 Backup auf NAS10 via rclone (Schritt 6.1c abgeschlossen) |
| 26.02.2026 | OpenProject 17.1.1 deployed mit Hocuspocus (Schritt 6.2 abgeschlossen) |
| 27.02.2026 | OpenProject Update 17.1.1 -> 17.1.2-slim (Security-Fixes CVE-2026-27718 ff.) |
| 28.02.2026 | Odoo 18 CE Deployment vorbereitet (Phase 6.3, Chat-Anweisung erstellt) |
