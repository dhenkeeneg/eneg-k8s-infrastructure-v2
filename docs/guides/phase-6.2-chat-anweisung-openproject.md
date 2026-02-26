# Handoff: Phase 6.2 — OpenProject Deployment

**Erstellt:** 26.02.2026
**Naechster Schritt:** Garage S3 Backup + OpenProject Deployment
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

Wir setzen Phase 6.2 fort. Bitte lies zuerst folgende Dokumente:
1. docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.3.md
2. docs/phases/phase-06-pilot-apps.md

Dann arbeite die folgenden Aufgaben der Reihe nach ab:

AUFGABE 1: Garage S3 Backup auf NAS10
- Garage S3 (In-Cluster) muss auf NAS10 QuObject S3 gesichert werden
- NAS10 S3 Endpoint: https://nas10.eneg.de:9000
- Ziel-Bucket auf NAS10: k8s-dev-garage-backup
- S3-Credentials fuer NAS10 liegen bereits als SOPS-Secret im Cluster
  (s3-credentials im databases Namespace)
- Pruefe ob Garage native Backup/Mirror-Funktionen hat oder ob wir
  einen CronJob mit rclone/mc (MinIO Client) brauchen
- Backup-Frequenz: taeglich, Retention: 30 Tage
- Loesung muss GitOps-konform sein (Manifests im Repository)

AUFGABE 2: OpenProject Deployment (Phase 6.2)
- OpenProject Community Edition deployen
- Datenbank: cnpg-erp Cluster (PostgreSQL, bereits vorhanden)
- S3 Storage: Garage (s3-dev-v2.eneg.de) fuer Attachments/Assets
- DNS: openproject-dev-v2.eneg.de (CNAME auf traefik-dev.eneg.de)
- Deployment-Pattern: Raw Kubernetes Manifests (wie n8n)
- Secrets: SOPS-verschluesselt (Zwei-Secret-Pattern: DB + App)
- Ingress: Certificate + IngressRoute im traefik Namespace

Bevor du mit der Implementierung beginnst:
- Recherchiere die aktuelle stable Version von OpenProject
- Pruefe das offizielle Docker Image und dessen Konfiguration
- Klaere S3-Integration (welche ENV-Variablen fuer Attachments)
- Stimme Versionen und Architektur mit mir ab
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

### ArgoCD Sync-Wave Reihenfolge (aktuell)

| Wave | Application | Namespace |
|---|---|---|
| 0 | argocd | argocd |
| 1 | metallb, traefik | metallb-system, traefik |
| 2 | cert-manager, ionos-webhook | cert-manager |
| 3 | longhorn, cnpg-operator, mariadb-operator | diverse |
| 4 | cnpg-secrets, garage-secrets | databases, garage |
| 5 | cnpg-shared, cnpg-erp, mariadb-galera, garage | databases, garage |
| 6 | cnpg-databases | databases |
| 7 | n8n-secrets | n8n |
| 8 | n8n | n8n |

### Garage S3 Details

- **S3 API Endpoint (intern):** http://garage-s3.garage.svc.cluster.local:3900
- **S3 API Endpoint (extern):** https://s3-dev-v2.eneg.de
- **WebUI:** https://s3-gui-dev-v2.eneg.de
- **Region:** eu-central-1
- **Addressing:** Path-Style (s3-dev-v2.eneg.de/bucketname)
- **Admin Token:** Im Secret garage-secrets (Namespace garage)
- **Node IDs:**
  - garage-0: 232bd5d527019e9f (10.42.2.35)
  - garage-1: 7bbe5485006dce78 (10.42.1.42)
  - garage-2: e54bdcd9e2001e96 (10.42.0.33)
- **Layout:** 3x 20GB, Zone dc1, Replication Factor 2

### NAS10 S3 Details (Backup-Ziel)

- **Endpoint:** https://nas10.eneg.de:9000
- **Bestehende Buckets:** k8s-backups-postgres, k8s-backups-mariadb, etc.
- **Neuer Bucket fuer Garage:** k8s-dev-garage-backup
- **Credentials:** Bereits als s3-credentials Secret im databases Namespace

### Etablierte Patterns

**Deployment-Pattern (Raw Manifests):**
```
kubernetes/base/apps/<app>/
  ├── namespace.yaml
  ├── deployment.yaml
  ├── service.yaml
  ├── ingress.yaml          # Certificate + IngressRoute (traefik NS)
  └── secrets/
      ├── kustomization.yaml
      ├── secret-generator.yaml
      ├── <app>-secrets.enc.yaml
      └── <app>-secrets.yaml.template
```

**Zwei-Secret-Pattern:**
1. DB-Credentials in databases Namespace (fuer CNPG managed.roles)
2. App-Secrets in App-Namespace (DB-Passwort Kopie + App-Keys)

**Ingress-Pattern:**
- Certificate + IngressRoute im traefik Namespace
- Cross-Namespace Service-Referenz zum Backend
- ClusterIssuer: letsencrypt-prod

### Dateien im Repository (Garage-bezogen)

```
kubernetes/base/garage/
├── namespace.yaml
├── configmap.yaml              # garage.toml
├── statefulset.yaml            # 3 Replicas, Init-Container
├── services.yaml               # Headless + S3 + Admin
├── webui-deployment.yaml       # WebUI + Service
├── ingress.yaml                # Certs + IngressRoutes
└── secrets/
    ├── kustomization.yaml
    ├── secret-generator.yaml
    ├── garage-secrets.enc.yaml
    └── garage-secrets.yaml.template

kubernetes/environments/dev/infrastructure/
├── garage-secrets-app.yaml     # Wave 4
└── garage-app.yaml             # Wave 5
```

---

## Offene Entscheidungen fuer den neuen Chat

1. **Garage Backup-Methode:** Garage hat kein natives Cross-S3-Backup.
   Optionen: CronJob mit rclone oder MinIO Client (mc) im Cluster.
   -> Im neuen Chat recherchieren und absprechen.

2. **OpenProject Version:** Aktuelle stable Version recherchieren.
   Community Edition hat S3-Unterstuetzung (fog/aws gem).

3. **OpenProject S3-Config:** ENV-Variablen fuer Attachment Storage
   auf Garage S3 (interner Endpoint, Bucket, Access Keys).

4. **OpenProject Datenbank:** Nutzt cnpg-erp Cluster. Neue Rolle +
   Database CRD erstellen (wie bei n8n auf cnpg-shared).

5. **Bucket-Erstellung in Garage:** Fuer OpenProject Attachments
   muss ein Bucket + Access Key in Garage erstellt werden
   (via WebUI oder CLI).

---

## Checkliste Phase 6.2

- [ ] Garage Backup CronJob auf NAS10 S3 einrichten
- [ ] Garage Bucket fuer OpenProject erstellen (z.B. "openproject-attachments")
- [ ] Garage Access Key fuer OpenProject erstellen
- [ ] OpenProject DB-Rolle auf cnpg-erp erstellen
- [ ] OpenProject Database CRD erstellen
- [ ] OpenProject SOPS-Secrets (DB + App + S3)
- [ ] OpenProject Deployment Manifest
- [ ] OpenProject Service + Ingress
- [ ] DNS CNAME: openproject-dev-v2.eneg.de -> traefik-dev.eneg.de
- [ ] Testen: Web-UI, Login, Attachment-Upload (S3)
- [ ] Dokumentation aktualisieren

---

*Dieses Dokument dient als Handoff-Anleitung und kann nach Abschluss
von Phase 6.2 archiviert werden.*
