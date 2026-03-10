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
| 6.3 | Odoo 18 CE: DB-Rolle + Database + Deployment + Ingress + Filestore-Backup | ✅ Abgeschlossen |
| 6.4 | Keycloak: DB-Rolle + Database + Deployment + Ingress | ✅ Abgeschlossen |
| 6.4b | Keycloak: Realm, AD-Anbindung, SSO-Clients | ✅ Abgeschlossen |
| 6.4c | App-Authentifizierung: OpenProject LDAP, Odoo/n8n SSO-Vorbereitung | 🔄 In Bearbeitung |
| 6.5 | i-doit Open 37: Eigenes Docker Image, MariaDB Galera, Deployment + Ingress | ✅ Abgeschlossen |
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
| 6 | mariadb-idoit-databases | MariaDB User + Grant CRDs fuer i-doit |
| 7 | n8n-secrets | App-Secrets: Encryption Key + DB-Passwort (KSOPS) |
| 7 | openproject-secrets | App-Secrets: SECRET_KEY_BASE, Hocuspocus, DB-URL, S3-Keys (KSOPS) |
| 7 | odoo-secrets | App-Secrets: Admin-Passwort + DB-Passwort (KSOPS) |
| 7 | odoo-backup-secrets | Backup-Credentials: NAS10 S3-Keys (KSOPS) |
| 7 | garage-backup-secrets | Backup-Credentials: Garage + NAS10 S3-Keys (KSOPS) |
| 7 | keycloak-secrets | App-Secrets: DB-Passwort + Admin-Passwort (KSOPS) |
| 7 | idoit-secrets | App-Secrets: DB-Passwort + Admin-Passwort + ghcr.io Pull Secret (KSOPS) |
| 8 | n8n | App-Deployment: Namespace, Deployment, Service, PVC, Ingress |
| 8 | openproject | App-Deployment: Namespace, Web, Worker, Memcached, Hocuspocus, PVC, Ingress |
| 8 | odoo | App-Deployment: Namespace, Deployment, Service, PVC, ConfigMap, Ingress |
| 8 | keycloak | App-Deployment: Namespace, Deployment, Service, Ingress |
| 8 | idoit | App-Deployment: Namespace, Deployment (eigenes Image), Service, PVC, Ingress |
| 8 | garage-backup | CronJob: Taegliches rclone Backup Garage -> NAS10 |
| 9 | odoo-backup | CronJob: Taegliches rclone Backup Odoo Filestore -> NAS10 |

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
| odoo-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | Odoo 18 CE | ✅ Aktiv |
| keycloak-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | Keycloak | ✅ Aktiv |
| idoit-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | i-doit | ✅ Aktiv |

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
│       ├── openproject/
│       │   ├── namespace.yaml
│       │   ├── deployment.yaml            # PVC, Memcached, Hocuspocus, Web, Worker, Seeder
│       │   ├── service.yaml
│       │   ├── ingress.yaml               # Certificate + IngressRoute (inkl. WebSocket)
│       │   └── secrets/
│       │       ├── kustomization.yaml
│       │       ├── secret-generator.yaml
│       │       ├── openproject-secrets.enc.yaml
│       │       └── openproject-secrets.yaml.template
│       └── odoo/
│           ├── namespace.yaml
│           ├── configmap.yaml             # odoo.conf (Multi-Process)
│           ├── deployment.yaml            # 1 Replica, Init-Container, PVC
│           ├── service.yaml               # Port 8069 + 8072
│           ├── ingress.yaml               # Certificate + IngressRoute (inkl. WebSocket)
│           ├── backup/
│           │   ├── cronjob.yaml           # rclone CronJob + ConfigMap, podAffinity
│           │   └── secrets/
│           │       ├── kustomization.yaml
│           │       ├── secret-generator.yaml
│           │       ├── odoo-backup-credentials.enc.yaml
│           │       └── odoo-backup-credentials.yaml.template
│           └── secrets/
│               ├── kustomization.yaml
│               ├── secret-generator.yaml
│               ├── odoo-secrets.enc.yaml
│               └── odoo-secrets.yaml.template
│       └── keycloak/
│           ├── namespace.yaml
│           ├── deployment.yaml            # Production-Mode, ENV-Konfiguration
│           ├── service.yaml               # Port 8080
│           ├── ingress.yaml               # Certificate + IngressRoute
│           └── secrets/
│               ├── kustomization.yaml
│               ├── secret-generator.yaml
│               ├── keycloak-secrets.enc.yaml
│               └── keycloak-secrets.yaml.template
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
            ├── odoo-secrets-app.yaml      # ArgoCD App (Wave 7)
            ├── odoo-backup-secrets-app.yaml # ArgoCD App (Wave 7)
            ├── keycloak-secrets-app.yaml   # ArgoCD App (Wave 7)
            ├── n8n-app.yaml               # ArgoCD App (Wave 8)
            ├── openproject-app.yaml       # ArgoCD App (Wave 8)
            ├── odoo-app.yaml              # ArgoCD App (Wave 8)
            ├── keycloak-app.yaml          # ArgoCD App (Wave 8)
            ├── odoo-backup-app.yaml       # ArgoCD App (Wave 9)
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

### 6.3 — Odoo 18 CE ERP-System ✅

**Abgeschlossen am:** 28.02.2026
**URL:** https://odoo-dev-v2.eneg.de
**Version:** odoo:18 (Community Edition, 18.0-20260217)
**Default-Login:** admin / admin (Passwortaenderung beim ersten Login)

#### Architektur

Odoo wird als Single-Replica Multi-Process Deployment betrieben:

```
Browser (https://odoo-dev-v2.eneg.de)
    |
Traefik (TLS-Terminierung)
    |
    ├── /websocket → odoo:8072 (Gevent/WebSocket)
    └── /* → odoo:8069 (HTTP-Worker)
                  |
                  ├── PostgreSQL (cnpg-erp-rw:5432) — Datenbank
                  └── PVC /var/lib/odoo — Filestore (Attachments)
                                |
                          rclone CronJob (taeglich 05:00)
                                |
                          NAS10 S3 (k8s-dev-odoo-backup)
```

**Multi-Process Modus (workers=2):**
- 2 HTTP-Worker (Port 8069)
- 1 Gevent-Worker fuer WebSocket/Live-Chat (Port 8072)
- 1 Cron-Worker (max_cron_threads=1)

**Warum nur 1 Replica:**
Odoo ist nicht horizontal skalierbar (In-Memory Sessions, Cron-Locks,
ORM-Cache, Filestore RWO). Skalierung erfolgt vertikal ueber mehr
Worker-Prozesse und CPU/Memory.

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| Database CRD | databases | odoo | ✅ Erstellt |
| Managed Role | databases | odoo (auf cnpg-erp) | ✅ Login aktiv |
| Secret (DB) | databases | odoo-db-credentials | ✅ SOPS/KSOPS |
| Namespace | odoo | odoo | ✅ Erstellt |
| Secret (App) | odoo | odoo-secrets | ✅ SOPS/KSOPS |
| Secret (Backup) | odoo | odoo-backup-credentials | ✅ SOPS/KSOPS |
| ConfigMap | odoo | odoo-config | ✅ odoo.conf |
| ConfigMap | odoo | odoo-backup-config | ✅ rclone.conf + backup.sh |
| PVC | odoo | odoo-filestore (10Gi Longhorn) | ✅ Bound |
| Deployment | odoo | odoo (1 Replica, Multi-Process) | ✅ Running |
| Service | odoo | odoo (ClusterIP:8069 + 8072) | ✅ Active |
| CronJob | odoo | odoo-backup | ✅ 0 5 * * * (Europe/Berlin) |
| Certificate | traefik | odoo-tls | ✅ Ready (Let's Encrypt) |
| IngressRoute | traefik | odoo | ✅ Active (inkl. WebSocket) |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| odoo-secrets | Synced | Healthy | 7 |
| odoo-backup-secrets | Synced | Healthy | 7 |
| odoo | Synced | Healthy | 8 |
| odoo-backup | Synced | Healthy | 9 |

#### Odoo Konfiguration (odoo.conf)

| Parameter | Wert |
|---|---|
| db_host | cnpg-erp-rw.databases.svc.cluster.local |
| db_port | 5432 |
| db_user | odoo |
| db_name | odoo |
| dbfilter | ^odoo$ |
| list_db | False |
| proxy_mode | True |
| workers | 2 |
| max_cron_threads | 1 |
| gevent_port | 8072 |
| data_dir | /var/lib/odoo |

#### Filestore-Backup

| Parameter | Wert |
|---|---|
| Tool | rclone/rclone:1.73.1 |
| Frequenz | Taeglich 05:00 Europe/Berlin |
| Quelle | PVC odoo-filestore (/var/lib/odoo) |
| Ziel | NAS10 S3 (k8s-dev-odoo-backup) |
| Retention | 32 Tage (--backup-dir Pattern) |
| podAffinity | Erzwingt gleichen Node wie Odoo-Pod (RWO-PVC) |

#### Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 500m | 2 |
| Memory | 512Mi | 2Gi |
| PVC Filestore | 10Gi (Longhorn) | - |

#### Secrets (SOPS-verschluesselt)

| Secret | Namespace | Keys |
|---|---|---|
| odoo-db-credentials | databases | username, password |
| odoo-secrets | odoo | db-password, admin-password |
| odoo-backup-credentials | odoo | NAS10_ACCESS_KEY_ID, NAS10_SECRET_ACCESS_KEY |

#### DB-Initialisierung (einmalig)

Odoo benoetigt eine einmalige DB-Initialisierung bevor `/web/health`
funktioniert. Das wird als separater Pod ohne HTTP-Server ausgefuehrt:

```bash
kubectl run odoo-init -n odoo --rm -it --restart=Never \
  --image=odoo:18 \
  --overrides='{
    "spec": {
      "securityContext": {"fsGroup": 101, "runAsUser": 101, "runAsGroup": 101},
      "containers": [{
        "name": "odoo-init",
        "image": "odoo:18",
        "args": ["-i", "base", "--stop-after-init", "--no-http"],
        "volumeMounts": [
          {"name": "config", "mountPath": "/config", "readOnly": true},
          {"name": "filestore", "mountPath": "/var/lib/odoo"}
        ],
        "env": [
          {"name": "ODOO_RC", "value": "/config/odoo.conf"},
          {"name": "HOST", "value": "cnpg-erp-rw.databases.svc.cluster.local"},
          {"name": "PORT", "value": "5432"},
          {"name": "USER", "value": "odoo"},
          {"name": "PASSWORD", "valueFrom": {"secretKeyRef": {"name": "odoo-secrets", "key": "db-password"}}}
        ]
      }],
      "volumes": [
        {"name": "config", "configMap": {"name": "odoo-config"}},
        {"name": "filestore", "persistentVolumeClaim": {"claimName": "odoo-filestore"}}
      ]
    }
  }'
```

#### Key Learnings Odoo

1. **ODOO_RC Environment-Variable:** Das offizielle Odoo Docker-Entrypoint-Script
   liest die Config aus `ODOO_RC` (Default: `/etc/odoo/odoo.conf`). Wenn die
   Config an einem anderen Pfad liegt, muss ODOO_RC explizit gesetzt werden.
   Ohne ODOO_RC findet das Script die DB-Werte nicht und faellt auf den
   Default-Host `db` zurueck.

2. **Entrypoint-Script und check_config:** Das Entrypoint liest `db_host`,
   `db_port`, `db_user`, `db_password` aus der Config (via grep) und uebergibt
   sie als CLI-Argumente. ENV-Variablen `HOST`, `PORT`, `USER`, `PASSWORD`
   dienen als Fallback wenn die Config-Werte fehlen.

3. **DB-Init vor erstem Start:** Odoo startet nicht ohne Datenbankschema.
   `/web/health` gibt 500 mit `KeyError: 'ir.http'` zurueck. Loesung:
   Einmaliger Init-Pod mit `-i base --stop-after-init --no-http`.

4. **Init-Pod: args statt command:** Bei `kubectl run --overrides` muss `args`
   (nicht `command`) verwendet werden, damit das Entrypoint-Script ausgefuehrt
   wird. Mit `command` wird das Entrypoint umgangen und ENV-Variablen wie
   `HOST`/`PASSWORD` werden nicht in CLI-Argumente umgewandelt.

5. **Longhorn RWO und Backup-CronJob:** Der Backup-Pod muss auf demselben Node
   wie der Odoo-Pod laufen, da Longhorn PVCs ReadWriteOnce sind und nicht
   cross-node gemountet werden koennen. Loesung: `podAffinity` mit
   `requiredDuringSchedulingIgnoredDuringExecution` auf Label
   `app.kubernetes.io/name: odoo`.

---

### 6.4 — Keycloak Identity Management ✅

**Abgeschlossen am:** 04.03.2026
**URL:** https://keycloak-dev-v2.eneg.de
**Version:** quay.io/keycloak/keycloak:26.5.4
**Modus:** Production (`start`, nicht `start-dev`)
**Default-Login:** admin / (SOPS-verschluesseltes Passwort)

#### Architektur

```
Browser (https://keycloak-dev-v2.eneg.de)
    |
Traefik (TLS-Terminierung)
    |
    └── /* → keycloak:8080 (HTTP)
                  |
                  ├── PostgreSQL (cnpg-shared-rw:5432) — Datenbank
                  └── Active Directory (ldap://dc01/dc02/dc03:389)
```

**Proxy-Konfiguration:**
- Keycloak laeuft im Edge-Modus hinter Traefik
- TLS wird von Traefik terminiert, intern HTTP auf Port 8080
- Management-Port 9000 fuer Health/Metrics Endpoints (Keycloak 26+)

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| Database CRD | databases | keycloak | ✅ Erstellt |
| Managed Role | databases | keycloak (auf cnpg-shared) | ✅ Reconciled |
| Secret (DB) | databases | keycloak-db-credentials | ✅ SOPS/KSOPS |
| Namespace | keycloak | keycloak | ✅ Erstellt |
| Secret (App) | keycloak | keycloak-secrets | ✅ SOPS/KSOPS |
| Deployment | keycloak | keycloak (1 Replica) | ✅ Running |
| Service | keycloak | keycloak (ClusterIP:8080) | ✅ Active |
| Certificate | traefik | keycloak-tls | ✅ Ready (Let's Encrypt) |
| IngressRoute | traefik | keycloak | ✅ Active |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| keycloak-secrets | Synced | Healthy | 7 |
| keycloak | Synced | Healthy | 8 |

#### Keycloak Umgebungsvariablen

| Variable | Wert | Quelle |
|---|---|---|
| KC_DB | postgres | Env |
| KC_DB_URL_HOST | cnpg-shared-rw.databases.svc.cluster.local | Env |
| KC_DB_URL_PORT | 5432 | Env |
| KC_DB_URL_DATABASE | keycloak | Env |
| KC_DB_USERNAME | keycloak | Env |
| KC_DB_PASSWORD | (verschluesselt) | Secret: keycloak-secrets/db-password |
| KC_PROXY_HEADERS | xforwarded | Env |
| KC_HTTP_ENABLED | true | Env |
| KC_HOSTNAME | keycloak-dev-v2.eneg.de | Env |
| KC_HEALTH_ENABLED | true | Env |
| KC_METRICS_ENABLED | true | Env |
| KC_BOOTSTRAP_ADMIN_USERNAME | admin | Env |
| KC_BOOTSTRAP_ADMIN_PASSWORD | (verschluesselt) | Secret: keycloak-secrets/admin-password |

#### Secrets (SOPS-verschluesselt)

| Secret | Namespace | Keys |
|---|---|---|
| keycloak-db-credentials | databases | username, password |
| keycloak-secrets | keycloak | db-password, admin-password |

#### Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 500m | 2 |
| Memory | 512Mi | 1Gi |

#### Key Learnings Keycloak

1. **Health-Probes auf Management-Port 9000:** Keycloak 26+ verschiebt die
   Health/Metrics-Endpoints (`/health/started`, `/health/live`, `/health/ready`)
   auf einen separaten Management-Port (9000) statt Port 8080. Probes muessen
   auf den named port `management` (9000) zeigen, nicht auf `http` (8080).

2. **Production-Mode Command als args:** `start` muss als `args` (nicht `command`)
   im Container-Spec uebergeben werden, damit der Keycloak-Entrypoint erhalten
   bleibt. Beim ersten Start fuehrt Keycloak automatisch eine DB-Schema-Migration
   und Quarkus-Augmentation durch (dauert ca. 18 Sekunden).

3. **Startup-Probe grosszuegig:** failureThreshold=30, periodSeconds=10 gibt
   Keycloak 300 Sekunden fuer den ersten Start (DB-Migration + Augmentation).

4. **CNPG managed.roles Duplikat-Fehler:** Beim Hinzufuegen neuer Rollen
   sorgfaeltig pruefen, dass keine doppelten Eintraege entstehen. CNPG
   Webhook lehnt Duplikate mit "Role name is duplicate of another" ab.

---

### 6.4b — Keycloak Realm und AD-Anbindung ✅

**Abgeschlossen am:** 04.03.2026
**Realm:** eneg
**AD-Anbindung:** LDAP (Port 389) gegen DC01/DC02/DC03

#### Realm-Konfiguration

| Parameter | Wert |
|---|---|
| Realm Name | eneg |
| AD Connection | ldap://dc01.eneg.de ldap://dc02.eneg.de ldap://dc03.eneg.de |
| Bind DN | CN=svc-k8s-keycloak,OU=K8s,OU=Sys-Accounts,OU=eNeG Benutzer,DC=eneg,DC=de |
| Users DN | OU=eNeG Benutzer,DC=eneg,DC=de |
| Search Scope | Subtree |
| Edit Mode | READ_ONLY |
| User Sync | Full sync taeglich, Changed users alle 5 Minuten |
| Group Mapping | Flat (Preserve Group Inheritance: Off) |
| Groups DN | OU=eNeG Gruppen,DC=eneg,DC=de |

#### SSO-Clients (Keycloak)

| Client ID | App | Typ | Status |
|---|---|---|---|
| openproject | OpenProject | OpenID Connect | ✅ Erstellt (nicht nutzbar, CE-Limitation) |
| n8n | n8n | OpenID Connect | ✅ Erstellt (nicht nutzbar, CE-Limitation) |
| odoo | Odoo 18 | OpenID Connect | ✅ Erstellt (Integration ausstehend) |

#### Key Learnings AD-Anbindung

1. **AD-Gruppen mit verschachtelten Parents:** Keycloak kann keine Gruppen mit
   mehreren uebergeordneten Gruppen abbilden (Fehler: `GroupsMultipleParents`).
   Loesung: `Preserve Group Inheritance: Off` im Group-LDAP-Mapper setzen,
   damit Gruppen flach importiert werden.

2. **User Groups Retrieve Strategy:** `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE` fuer
   Active Directory verwenden, da AD das `member`-Attribut auf Gruppen nutzt.

---

### 6.4c — App-Authentifizierung ✅

**Abgeschlossen am:** 04.03.2026

#### Authentifizierungs-Matrix

| App | Methode | Status | Bemerkung |
|---|---|---|---|
| OpenProject CE | LDAP direkt gegen AD | ✅ Funktioniert | OIDC nur Enterprise |
| Odoo 18 CE | Keycloak OIDC (geplant) | 🔲 Offen | Community-Modul erforderlich |
| n8n CE | Keine SSO-Option | ❌ Nicht moeglich | OIDC/SAML nur Enterprise |
| Keycloak | AD/LDAP Federation | ✅ Funktioniert | Realm "eneg" |

#### OpenProject LDAP-Konfiguration

OpenProject Community Edition unterstuetzt kein OIDC/SSO (Enterprise-only).
Stattdessen wird LDAP direkt gegen Active Directory konfiguriert:

| Parameter | Wert |
|---|---|
| Name | Active Directory |
| Host | dc01.eneg.de |
| Port | 389 |
| LDAPS | Nein |
| Account (Bind DN) | CN=svc-k8s-keycloak,OU=K8s,OU=Sys-Accounts,OU=eNeG Benutzer,DC=eneg,DC=de |
| Base DN | OU=eNeG Benutzer,DC=eneg,DC=de |
| Login-Attribut | mail |
| Vorname-Attribut | givenName |
| Nachname-Attribut | sn |
| E-Mail-Attribut | mail |
| On-the-fly-Erstellung | Nein (User werden manuell angelegt) |

**Login:** User melden sich mit ihrer **E-Mail-Adresse** (z.B. `D.Henke@eneg.de`)
und dem AD-Passwort an. Der Login-Wert in OpenProject muss exakt mit dem
`mail`-Attribut im AD uebereinstimmen.

**OIDC ENV-Variablen:** Im Deployment sind vorbereitend OIDC-Umgebungsvariablen
fuer Keycloak enthalten (`OPENPROJECT_OPENID__CONNECT_KEYCLOAK_*`). Diese sind
aktuell wirkungslos (Enterprise-Gate im Code), bleiben aber fuer eine spaetere
Enterprise-Aktivierung erhalten.

#### Key Learnings App-Authentifizierung

1. **OpenProject OIDC ist Enterprise-only:** Der Seeder erstellt den Provider
   in der Datenbank und markiert ihn als `available: true`, aber die OmniAuth-
   Middleware registriert die Route `/auth/keycloak` nicht. Die Login-Seite
   zeigt keinen SSO-Button. Log-Meldung: "OmniAuth SSO strategy
   OpenProject::Plugins::AuthPlugin is only available for Enterprise Editions."

2. **OpenProject LDAP Base DN erforderlich:** Ohne Base DN in der LDAP-
   Konfiguration kann OpenProject keine User im AD finden. Anmeldung schlaegt
   mit "invalid credentials" fehl.

3. **sAMAccountName vs. mail als Login:** Der `sAMAccountName` im AD (z.B.
   `dhenke`) entspricht nicht unbedingt dem gewuenschten Login-Format.
   Durch Umstellung des Login-Attributs auf `mail` koennen User sich mit
   ihrer E-Mail-Adresse anmelden. Der Login-Wert im OpenProject-User muss
   exakt dem AD-`mail`-Attribut entsprechen.

4. **n8n CE hat kein SSO:** OIDC/SAML ist nur in der n8n Enterprise Edition
   verfuegbar. Die Community Edition unterstuetzt nur lokale Authentifizierung.

5. **Odoo CE hat kein natives OIDC:** Fuer SSO wird ein Community-Modul
   benoetigt (z.B. `auth_oauth`). Integration ist vorbereitet aber noch
   nicht implementiert.

---

### 6.5 — i-doit Open 37 IT-Dokumentation / CMDB ✅

**Abgeschlossen am:** 05.03.2026
**URL:** https://idoit-dev-v2.eneg.de
**Version:** i-doit Open 37 (eigenes Docker Image: ghcr.io/dhenkeeneg/idoit-open:37)
**Basis-Image:** php:8.3-apache (Debian Bookworm)
**Default-Login:** admin / admin (Passwortaenderung empfohlen)

#### Architektur

i-doit ist die erste Anwendung auf der MariaDB Galera Datenbank.
Im Gegensatz zu den PostgreSQL-basierten Apps (n8n, OpenProject, Odoo,
Keycloak) werden hier MariaDB Operator CRDs (User, Grant) verwendet.

```
Browser (https://idoit-dev-v2.eneg.de)
    |
Traefik (TLS-Terminierung)
    |
    └── /* → idoit:80 (HTTP/Apache)
                  |
                  ├── MariaDB Galera (mariadb-galera-primary:3306)
                  │   ├── idoit_system (System-DB)
                  │   └── idoit_data (Mandant-DB)
                  └── PVC /var/www/html/i-doit/upload (Longhorn)
```

**Besonderheit: Eigenes Docker Image**
Es gibt kein offizielles oder gepflegtes Community-Docker-Image fuer
i-doit Open 35+. Das Image wird selbst gebaut aus:
- Basis: `php:8.3-apache` (Debian Bookworm)
- i-doit Open 37 ZIP von SourceForge
- PHP-Extensions: bcmath, gd, ldap, mysqli, pdo, pdo_mysql, pgsql,
  soap, sockets, xml, zip, imagick, memcached
- Registry: GitHub Container Registry (ghcr.io, privat)

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| User CRD | databases | idoit (auf mariadb-galera) | ✅ Created |
| Grant CRD | databases | idoit-grant-system (ALL on idoit_system) | ✅ Created |
| Grant CRD | databases | idoit-grant-data (ALL on idoit_data) | ✅ Created |
| Secret (DB) | databases | idoit-db-credentials | ✅ SOPS/KSOPS |
| Namespace | idoit | idoit | ✅ Erstellt |
| Secret (App) | idoit | idoit-secrets | ✅ SOPS/KSOPS |
| Secret (Registry) | idoit | ghcr-pull-secret | ✅ SOPS/KSOPS |
| PVC | idoit | idoit-data (10Gi Longhorn) | ✅ Bound |
| Deployment | idoit | idoit (1 Replica) | ✅ Running |
| Service | idoit | idoit (ClusterIP:80) | ✅ Active |
| Certificate | traefik | idoit-tls | ✅ Ready (Let's Encrypt) |
| IngressRoute | traefik | idoit | ✅ Active |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| mariadb-idoit-databases | Synced | Healthy | 6 |
| idoit-secrets | Synced | Healthy | 7 |
| idoit | Synced | Healthy | 8 |

#### Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 250m | 1 |
| Memory | 256Mi | 1Gi |
| PVC | 10Gi (Longhorn) | - |

#### Secrets (SOPS-verschluesselt)

| Secret | Namespace | Keys |
|---|---|---|
| idoit-db-credentials | databases | password |
| idoit-secrets | idoit | db-password, admin-password |
| ghcr-pull-secret | idoit | .dockerconfigjson (ghcr.io) |

#### Docker Image Build

```bash
# Auf k8s-mgmt-10 (Docker Engine installiert):
cd ~/git/eneg-k8s-infrastructure-v2/docker/idoit
docker build -t ghcr.io/dhenkeeneg/idoit-open:37 .
echo $GHCR_TOKEN | docker login ghcr.io -u dhenkeeneg --password-stdin
docker push ghcr.io/dhenkeeneg/idoit-open:37
```

#### Key Learnings i-doit

1. **Kein offizielles Docker Image:** Community-Images (migoller/idoit,
   bheisig/idoit) sind veraltet (max. i-doit 1.19). Eigenes Dockerfile
   mit php:8.3-apache Basis und SourceForge-ZIP ist die beste Loesung.

2. **MariaDB Operator Database CRDs vs. i-doit Setup-Wizard:** i-doit
   erwartet leere Datenbanknamen und erstellt das Schema selbst. Vorab
   erstellte Datenbanken fuehren zu "EXISTS. PLEASE DROP IT". Loesung:
   Keine Database CRDs verwenden, nur User + Grant CRDs. i-doit verwaltet
   seine Datenbanken (idoit_system, idoit_data) eigenstaendig.

3. **MariaDB Operator CRD metadata.name vs. DB-Name:** Kubernetes erlaubt
   keine Unterstriche in metadata.name. Der MariaDB Operator nutzt
   standardmaessig metadata.name als DB-Name. Fuer DB-Namen mit
   Unterstrichen muss `spec.name` explizit gesetzt werden.

4. **MariaDB Operator User CRD:** Das Feld `maxConnections` existiert
   nicht in der aktuellen CRD-Version (Operator 25.10.4). Fuehrt zu
   "field not declared in schema" bei ServerSideApply.

5. **PHP sockets Extension:** i-doit 37 benoetigt die PHP sockets
   Extension, die nicht standardmaessig im php:8.3-apache Image
   enthalten ist. Muss explizit via docker-php-ext-install gebaut werden.

6. **imagePullPolicy: Always:** Bei eigenem ghcr.io Image mit festem
   Tag (z.B. :37) muss imagePullPolicy auf Always stehen, damit
   Image-Updates nach einem Rebuild gezogen werden.

7. **MariaDB 11.8.6 Kompatibilitaet:** i-doit 37 listet offiziell nur
   MariaDB bis 11.4. MariaDB 11.8.6 Galera funktioniert problemlos,
   der Setup-Wizard zeigt lediglich eine Warnung.

8. **GitHub Container Registry (ghcr.io):** Privates Image erfordert
   ein imagePullSecret (kubernetes.io/dockerconfigjson) mit GitHub PAT
   (read:packages Berechtigung). Docker Engine auf k8s-mgmt-10 fuer
   Image-Builds installiert.

9. **config.inc.php Persistenz:** i-doit speichert die Konfiguration
   (DB-Verbindung, Mandanten, Crypto-Keys) in `/var/www/html/i-doit/src/config.inc.php`.
   Dieses Verzeichnis muss persistent sein, sonst geht die Konfiguration bei
   Pod-Restarts verloren und der Setup-Wizard startet erneut. Loesung:
   Init-Container kopiert den src-Ordner beim ersten Start aus dem Image
   in den PVC (`subPath: src`). Bei weiteren Restarts bleibt die config erhalten.

---

## Naechste Schritte

- Odoo SSO/OIDC ueber Keycloak (Community-Modul erforderlich)
- n8n SSO (nur Enterprise Edition, CE nicht unterstuetzt)
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
| 28.02.2026 | Odoo 18 CE erfolgreich deployed (Schritt 6.3 abgeschlossen) |
| 04.03.2026 | Keycloak 26.5.4 deployed (Schritt 6.4 abgeschlossen) |
| 04.03.2026 | Keycloak Realm "eneg", AD-Anbindung, SSO-Clients (Schritt 6.4b abgeschlossen) |
| 04.03.2026 | OpenProject LDAP-Authentifizierung gegen AD (Schritt 6.4c) |
| 04.03.2026 | Erkenntnis: OpenProject OIDC und n8n SSO sind Enterprise-only |
| 10.03.2026 | i-doit Open 37 deployed (Schritt 6.5 abgeschlossen), eigenes Docker Image auf ghcr.io, MariaDB Operator CRDs |
