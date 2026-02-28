# Handoff: Phase 6.3 — Odoo 18 CE Deployment

**Erstellt:** 28.02.2026
**Naechster Schritt:** Odoo 18 Community Edition deployen
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Kontext fuer neuen Chat

Kopiere den folgenden Block als Startprompt in einen neuen Chat:

---

### Startprompt (kopieren)

```
Wir arbeiten gemeinsam an diesem Projekt "eNeG K8s Infrastruktur OpenTofuAnsible".
Es gibt drei verschiedenen Arbeitsumgebungen auf denen ich die Konfigurationen
fuer die Server anpasse:
- Einen Windows-Laptop mit Windows 11
- Einen MacMini
- Ein MacBook
Auf allen drei Umgebungen ist der Desktop-Commander eingerichtet und du hast
Terminalzugriff und Dateizugriff direkt auf mein geclontes Git Repository.
Pfad bei Windows ist: "C:\Users\dhenke\git\eneg-k8s-infrastructure-v2"
Der Pfad bei MacBook und MacMini ist jeweils:
"/Users/danielhenke/git/eneg-k8s-infrastructure-v2"
Erstelle noetige Dateien und Aenderungen eigenstaendig ueber Desktop-Commander
aber in Absprache mit mir.

Wir arbeiten an der DEV Umgebung mit den folgenden Servern:
k8s-dev-21, k8s-dev-22, k8s-dev-23

Du hast keinen direkten SSH Zugriff auf die Server. Dafuer arbeiten wir per
DevOps ueber GitHub und das lokale Repository.
Du fuehrst keine Commit und Push Befehle selbst aus.
Du fuehrst keine Befehle auf dem Management-Server
(k8s-mgmt-10 - 192.168.180.10) selbst aus.
Der Pfad zum Repository auf dem Managementserver ist:
"~/git/eneg-k8s-infrastructure-v2"
Im Repository gibt es den /docs-Pfad mit der gesamten Dokumentation.

Wir setzen Phase 6 fort mit Schritt 6.3: Odoo 18 CE Deployment.
Bitte lies zuerst folgende Dokumente:
1. docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.3.md
2. docs/phases/phase-06-pilot-apps.md
3. docs/guides/phase-6.4-chat-anweisung-odoo.md

Dann deploye Odoo 18 CE gemaess der unten beschriebenen Architektur.
```

---
## Aktueller Infrastruktur-Stand

### Laufende Komponenten

| Komponente | Version | Namespace | Status |
|---|---|---|---|
| K3s | v1.35.1+k3s1 | - | 3 Nodes Running |
| ArgoCD | v3.3.0 | argocd | Synced + Healthy |
| MetalLB | v0.15.3 | metallb-system | Active |
| Traefik | v3.6.7 | traefik | Active (192.168.180.100) |
| Cert-Manager | v1.17.2 | cert-manager | Ready |
| Longhorn | v1.9.2 | longhorn-system | 3x ~380GB |
| CNPG Operator | 1.28.1 | databases | Running |
| PostgreSQL (cnpg-shared) | 17 | databases | 3 Instanzen |
| PostgreSQL (cnpg-erp) | 17 | databases | 3 Instanzen |
| MariaDB Galera | 11.8.6 | databases | 3 Nodes |
| Garage S3 | v2.2.0 | garage | 3 Nodes, ~30GB eff. |
| Garage WebUI | 1.1.0 | garage | Running |
| n8n | 2.8.4 | n8n | Running |
| OpenProject | 17.1.2-slim | openproject | Running |
| Hocuspocus | latest | openproject | Running |
| Memcached | 1.6.40-alpine | openproject | Running |

### ArgoCD Sync-Wave Reihenfolge (aktuell)

| Wave | Application | Namespace |
|---|---|---|
| 0 | argocd | argocd |
| 1 | metallb, traefik | metallb-system, traefik |
| 2 | cert-manager, ionos-webhook | cert-manager |
| 3 | longhorn, cnpg-operator, mariadb-operator | diverse |
| 4 | cnpg-secrets, garage-secrets, garage-backup-secrets | databases, garage |
| 5 | cnpg-shared, cnpg-erp, mariadb-galera, garage | databases, garage |
| 6 | cnpg-databases, garage-backup | databases, garage |
| 7 | n8n-secrets, openproject-secrets | n8n, openproject |
| 8 | n8n, openproject | n8n, openproject |

---
## Odoo 18 CE — Geplante Architektur

### Eckdaten

| Parameter | Wert |
|---|---|
| Version | Odoo 18.0 Community Edition |
| Docker Image | `odoo:18` (offizielles Image) |
| Datenbank | cnpg-erp Cluster (PostgreSQL 17) |
| DB-User | odoo (neue managed.role auf cnpg-erp) |
| DB-Name | odoo |
| Modus | Multi-Process (`workers=2`, gevent Port 8072) |
| Replicas | 1 Pod (horizontale Skalierung nicht moeglich bei Odoo) |
| Filestore | PVC (Longhorn, `/var/lib/odoo`, 10Gi) |
| Filestore-Backup | CronJob (rclone -> NAS10 S3, taeglich) |
| DNS | odoo-dev-v2.eneg.de (CNAME auf traefik-dev.eneg.de) |
| Ingress | 2 Routen: `/*` -> 8069, `/websocket` -> 8072 |
| ArgoCD Waves | 7 (Secrets), 8 (App) |

### Warum kein S3 fuer Attachments

Odoo Community Edition hat kein natives S3-Attachment-Backend. Die
verfuegbaren Community-Module (OCA fs_attachment_s3 etc.) erfordern ein
Custom-Docker-Image mit zusaetzlichen Python-Bibliotheken (boto3 etc.),
was bei jedem Odoo-Update Pflege bedeutet. Fuer DEV wird daher ein
PVC-Filestore verwendet, der ueber einen taeglich rclone-CronJob auf
NAS10 gesichert wird.

### Warum nur 1 Replica

Odoo ist nicht fuer horizontale Skalierung (mehrere Pods) ausgelegt:
- In-Memory Session-Handling (kein shared Session-Store)
- Cron-Worker mit DB-Locks (Race Conditions bei mehreren Pods)
- In-Memory ORM-Cache (inkonsistente Caches zwischen Pods)
- Filestore nicht shared (Longhorn RWO, kein RWX)

Skalierung erfolgt vertikal: Mehr Worker-Prozesse innerhalb eines Pods,
mehr CPU/Memory. Das ist auch das offizielle Production-Pattern von Odoo.

### Warum Multi-Process statt Single-Process

Multi-Process (`workers > 0`) startet intern mehrere Prozesse:
- HTTP-Worker (Anzahl = `workers` Parameter, hier 2)
- Gevent-Worker auf Port 8072 (WebSocket/Live-Chat)
- Cron-Worker (max_cron_threads, default 2)

Vorteile gegenueber Single-Process:
- Echte Parallelitaet (kein Python GIL-Bottleneck)
- Dedizierter Gevent-Worker fuer WebSocket-Verbindungen
- Prozess-Isolation: Ein abgestuerzter Worker killt nicht alles
- Entspricht dem empfohlenen Production-Setup

---
## Architektur-Diagramm

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
                          rclone CronJob (taeglich)
                                |
                          NAS10 S3 (Backup)
```

---

## Deployment-Schritte (Reihenfolge)

### Schritt 1: Datenbank vorbereiten

1. Neue managed.role `odoo` auf cnpg-erp Cluster hinzufuegen
2. SOPS-Secret `odoo-db-credentials` in databases Namespace
3. Database CRD `odoo` mit Owner `odoo`
4. cnpg-erp.yaml anpassen (managed.roles erweitern)
5. cnpg-databases erweitern (odoo-database.yaml)
6. CNPG-Secrets erweitern (odoo-db-credentials)

### Schritt 2: App-Secrets erstellen

1. SOPS-Secret `odoo-secrets` in odoo Namespace:
   - `db-password` (identisch mit DB-Credentials)
   - `admin-password` (Odoo Master-Passwort fuer DB-Management)
2. ArgoCD Application `odoo-secrets` (Wave 7)

### Schritt 3: Odoo Deployment erstellen

Dateien unter `kubernetes/base/apps/odoo/`:
- `namespace.yaml`
- `configmap.yaml` (odoo.conf)
- `deployment.yaml` (1 Replica, Multi-Process)
- `service.yaml` (Port 8069 + 8072)
- `ingress.yaml` (Certificate + IngressRoute mit WebSocket-Route)

### Schritt 4: Filestore-Backup einrichten

CronJob mit rclone analog zu Garage-Backup:
- Quelle: PVC /var/lib/odoo (gemountet im rclone-Pod)
- Ziel: NAS10 S3 Bucket `k8s-dev-odoo-backup`
- Frequenz: Taeglich 05:00 Europe/Berlin
- Retention: 32 Tage

### Schritt 5: ArgoCD Applications

- `odoo-secrets-app.yaml` (Wave 7)
- `odoo-app.yaml` (Wave 8)
- `odoo-backup-app.yaml` (Wave 8 oder 9)

### Schritt 6: DNS + Test

1. CNAME `odoo-dev-v2.eneg.de` -> `traefik-dev.eneg.de` (IONOS)
2. Warten auf Certificate (Let's Encrypt)
3. Odoo Web-UI aufrufen, Datenbank initialisieren
4. Live-Chat/WebSocket testen

---
## Odoo Konfiguration (odoo.conf)

```ini
[options]
; Datenbank
db_host = cnpg-erp-rw.databases.svc.cluster.local
db_port = 5432
db_user = odoo
db_name = odoo
db_password = (aus Secret)
db_sslmode = disable
db_maxconn = 64
dbfilter = ^odoo$
list_db = False

; HTTP
http_port = 8069
proxy_mode = True

; Multi-Process
workers = 2
max_cron_threads = 1
gevent_port = 8072

; Limits (DEV-Werte)
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_time_cpu = 600
limit_time_real = 1200
limit_request = 8192

; Filestore
data_dir = /var/lib/odoo

; Admin
admin_passwd = (aus Secret)

; Logging
log_level = info
```

## Geplante Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 500m | 2 |
| Memory | 512Mi | 2Gi |
| PVC Filestore | 10Gi (Longhorn) | - |

## Secrets (SOPS-verschluesselt)

### odoo-db-credentials (databases Namespace)

| Key | Beschreibung | Generierung |
|---|---|---|
| password | PostgreSQL Passwort fuer User odoo | `openssl rand -hex 24` |

### odoo-secrets (odoo Namespace)

| Key | Beschreibung | Generierung |
|---|---|---|
| db-password | PostgreSQL Passwort (Kopie) | identisch mit odoo-db-credentials |
| admin-password | Odoo Master-Passwort (DB-Management) | `openssl rand -hex 24` |

---

## Etablierte Patterns (Referenz)

**Deployment-Pattern (Raw Manifests):**
```
kubernetes/base/apps/odoo/
  ├── namespace.yaml
  ├── configmap.yaml          # odoo.conf
  ├── deployment.yaml          # 1 Replica, Multi-Process
  ├── service.yaml             # Port 8069 + 8072
  ├── ingress.yaml             # Certificate + IngressRoute (traefik NS)
  ├── backup/
  │   ├── cronjob.yaml         # rclone CronJob + ConfigMap
  │   └── secrets/
  │       ├── kustomization.yaml
  │       ├── secret-generator.yaml
  │       ├── odoo-backup-credentials.enc.yaml
  │       └── odoo-backup-credentials.yaml.template
  └── secrets/
      ├── kustomization.yaml
      ├── secret-generator.yaml
      ├── odoo-secrets.enc.yaml
      └── odoo-secrets.yaml.template
```

**Zwei-Secret-Pattern:**
1. DB-Credentials in databases Namespace (fuer CNPG managed.roles)
2. App-Secrets in odoo Namespace (DB-Passwort Kopie + Admin-Passwort)

**SOPS Verschluesselung:**
- Age Key: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
- Verschluesselung immer auf k8s-mgmt-10

**Git Workflow:**
1. Windows/Mac: Dateien erstellen/aendern
2. git add, commit, push
3. k8s-mgmt-10: git pull, SOPS encrypt, commit, push (nur fuer Secrets)
4. ArgoCD: auto-sync

---

## Key Learnings aus vorherigen Deployments (relevant fuer Odoo)

1. **DB-Passwoerter nur alphanumerisch:** `openssl rand -hex 24`
2. **CNPG Managed Roles Defaults explizit:** connectionLimit, ensure, inherit
3. **Longhorn PVC + Non-Root:** securityContext mit fsGroup noetig
4. **Proxy-Mode:** Odoo muss `proxy_mode = True` haben wenn hinter Traefik
5. **dbfilter + list_db:** Sicherheit: Nur eine DB erlauben, DB-Manager deaktivieren
6. **Multi-Process auf Linux only:** Docker-Container laufen auf Linux, daher kein Problem

---

*Dieses Dokument dient als Handoff-Anleitung fuer den naechsten Chat.*
