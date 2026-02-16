# GitOps Kubernetes-Infrastruktur auf VMware vSphere

## Projektplanung - Version 1.3

**Erstellt:** 04.02.2026  
**Letzte Aktualisierung:** 16.02.2026  
**Standort:** Hamburg  
**Projekt:** eNeG K8s Infrastructure v2

---

## Inhaltsverzeichnis

1. [Executive Summary](#1-executive-summary)
2. [Infrastruktur-Ãœbersicht](#2-infrastruktur-Ã¼bersicht)
3. [Architektur-Entscheidungen](#3-architektur-entscheidungen)
4. [Netzwerk-Konfiguration](#4-netzwerk-konfiguration)
5. [Naming Conventions](#5-naming-conventions)
6. [Software-Stack](#6-software-stack)
7. [GitOps Workflow](#7-gitops-workflow)
8. [Datenbank-Strategie](#8-datenbank-strategie)
9. [Monitoring & Alerting](#9-monitoring--alerting)
10. [Backup-Strategie](#10-backup-strategie)
11. [Security](#11-security)
12. [SSL-Zertifikate](#12-ssl-zertifikate)
13. [Implementierungsplan](#13-implementierungsplan)
14. [Dokumentation](#14-dokumentation)

---

## 1. Executive Summary

### Projektziel

Aufbau einer vollstÃ¤ndig automatisierten, GitOps-basierten Kubernetes-Infrastruktur mit drei Umgebungen (DEV, TEST, PROD) auf VMware vSphere.

### Kernprinzipien

- **Infrastructure as Code:** Alle Ressourcen werden durch Code definiert (OpenTofu, Ansible, Kubernetes Manifests)
- **GitOps:** Git als Single Source of Truth, ArgoCD fÃ¼r automatische Synchronisation
- **Promotion Pipeline:** Ã„nderungen durchlaufen immer DEV â†’ TEST â†’ PROD
- **StabilitÃ¤t vor Geschwindigkeit:** Erprobte, stabile LÃ¶sungen haben Vorrang

### Technologie-Stack (KurzÃ¼bersicht)

| Bereich | Technologie |
|---------|-------------|
| Kubernetes | K3s HA-Cluster (3 Nodes) |
| OS | Ubuntu 24.04 LTS |
| IaC | OpenTofu 1.11, Ansible 2.20, Packer |
| GitOps | ArgoCD, Kustomize, SOPS + Age |
| Ingress | Traefik + MetalLB |
| Storage | Longhorn (Distributed Block Storage) |
| Datenbanken | CloudNativePG (PostgreSQL), MariaDB Galera |
| Monitoring | Prometheus, Grafana, Loki, AlertManager |
| Secrets | SOPS + Age (verschlÃ¼sselt in Git) |

---

## 2. Infrastruktur-Ãœbersicht

### VMware vSphere Umgebung

| vCenter | ESXi Version | Hardware | Datastore |
|---------|--------------|----------|-----------|
| vCenter-A | ESXi 8.0.3 | 3x Dell (48 Cores, 512GB RAM) | S2842_SSD_01_VMS, S2843_SSD_01_VMS, S3168_SSD_01_VMS |

**Hinweis:** Seit Februar 2026 gibt es nur noch vcenter-a.eneg.de. Das alte vCenter (vcenter.eneg.de, ESXi 6.7) wurde dekommissioniert. S2842 wurde neu aufgebaut mit ESXi 8.0.3.


### VMware Hosts in vSphere Umgebungen

| vcenter-Name | Host-Nr | Host-Name     | ESX-Version | Hardware                   | Datastore               |
|--------------|---------|---------------|-------------|----------------------------|-------------------------|
| vCenter-A    | HOST1   | s2842.eneg.de | ESXi 8.0.3  | Dell (48 Cores, 512GB RAM) | S2842_SSD_01_VMS        |
| vCenter-A    | HOST2   | s2843.eneg.de | ESXi 8.0.3  | Dell (48 Cores, 512GB RAM) | S2843_SSD_01_VMS        |
| vCenter-A    | HOST3   | s3168.eneg.de | ESXi 8.0.3  | Dell (48 Cores, 512GB RAM) | S3168_SSD_01_VMS        |
	

### VM-Ãœbersicht

```
+-----------------------------------------------------------------------------+
|                              MANAGEMENT                                      |
|  k8s-mgmt-10.eneg.de (192.168.180.10) - Ubuntu 24.04, 4 vCPU, 8GB RAM, 100GB|
|  Tools: OpenTofu, Ansible, kubectl, Helm, SOPS, Age, Git                    |
+-----------------------------------------------------------------------------+
        |
        +------------------------+------------------------+
        v                        v                        v
+-------------------+   +-------------------+   +-------------------+
|   DEV CLUSTER     |   |   TEST CLUSTER    |   |   PROD CLUSTER    |
|   VLAN 180        |   |   VLAN 179        |   |   VLAN 178        |
|                   |   |                   |   |                   |
| k8s-dev-21  .21   |   | k8s-test-21 .21   |   | k8s-prod-21 .21   |
| k8s-dev-22  .22   |   | k8s-test-22 .22   |   | k8s-prod-22 .22   |
| k8s-dev-23  .23   |   | k8s-test-23 .23   |   | k8s-prod-23 .23   |
|                   |   |                   |   |                   |
| 4 vCPU, 12GB RAM  |   | 6 vCPU, 16GB RAM  |   | 8 vCPU, 24GB RAM  |
| 384GB Disk        |   | 512GB Disk        |   | 768GB Disk        |
+-------------------+   +-------------------+   +-------------------+
```

### VM-Verteilung auf die Hosts

Aus jedem Environment soll jeweils eine VM auf einem Host landen. Jeder Host bekommt somit drei neue VMs

Beispiel:
Host1 - k8s-dev-21
Host2 - k8s-dev-22
Host3 - k8s-dev-23

Host1 - k8s-test-21
Host2 - k8s-test-22
Host3 - k8s-test-23

usw.


### Ressourcen-Dimensionierung

| Umgebung | Nodes | vCPU/Node | RAM/Node | Disk/Node | Gesamt RAM |
|----------|-------|-----------|----------|-----------|------------|
| DEV | 3 | 4 | 12 GB | 384 GB | 36 GB |
| TEST | 3 | 6 | 16 GB | 512 GB | 48 GB |
| PROD | 3 | 8 | 24 GB | 768 GB | 72 GB |
| Management | 1 | 4 | 8 GB | 100 GB | 8 GB |

---

## 3. Architektur-Entscheidungen

### Kubernetes-Distribution: K3s

**Entscheidung:** K3s statt MicroK8s

| Kriterium | K3s | MicroK8s |
|-----------|-----|----------|
| Kontrolle | Volle Kontrolle Ã¼ber alle Komponenten | Snap-basiert, eingeschrÃ¤nkt |
| GrÃ¶ÃŸe | ~40MB Binary | GrÃ¶ÃŸer durch Snap |
| OS-UnabhÃ¤ngigkeit | Funktioniert identisch auf allen Linux | Snap-AbhÃ¤ngigkeit |
| GitOps-Integration | Alle Komponenten selbst verwaltet | Einige Addons "black box" |
| Debugging | Separate Prozesse, einfacher | Komplexer |

### Betriebssystem: Ubuntu 24.04 LTS

**Entscheidung:** Ubuntu statt Debian

- Bessere Kubernetes-Dokumentation und Community-Support
- Neuere Kernel fÃ¼r VMware Tools KompatibilitÃ¤t
- 5 Jahre Support (10 mit Ubuntu Pro)
- Einfacher fÃ¼r Lernphase

### Datenbanken: Kubernetes-native

**Entscheidung:** CloudNativePG + MariaDB Galera innerhalb Kubernetes

- CNCF Sandbox Projekt (CloudNativePG)
- VollstÃ¤ndige GitOps-Integration
- Automatisches HA/Failover
- Native Backup-Integration

---

## 4. Netzwerk-Konfiguration

### VLANs und IP-Bereiche

| Umgebung | VLAN | Netzwerk | Gateway | DNS Server |
|----------|------|----------|---------|------------|
| DEV | 180 | 192.168.180.0/24 | .247 | 192.168.161.101-103 |
| TEST | 179 | 192.168.179.0/24 | .247 | 192.168.161.101-103 |
| PROD | 178 | 192.168.178.0/24 | .247 | 192.168.161.101-103 |

### IP-Zuweisung

| Rolle | DEV | TEST | PROD |
|-------|-----|------|------|
| Node 1 | 192.168.180.21 | 192.168.179.21 | 192.168.178.21 |
| Node 2 | 192.168.180.22 | 192.168.179.22 | 192.168.178.22 |
| Node 3 | 192.168.180.23 | 192.168.179.23 | 192.168.178.23 |
| Traefik LB | 192.168.180.100 | 192.168.179.100 | 192.168.178.100 |
| MetalLB Pool | .151-.199 | .151-.199 | .151-.199 |

### Management-VM

- **Hostname:** k8s-mgmt-10.eneg.de
- **IP:** 192.168.180.10
- **VLAN:** 180
- **vCenter:** vCenter-A (S2843)
- **Datastore:** S2843_SSD_01_VMS
- **Ordner:** eNeG-VM-Produktiv/k8s-mgmt-10
- **KompatibilitÃ¤t:** ESXi 8.0 U2 und hÃ¶her (VM-Version 21)

### DNS-EintrÃ¤ge (zu erstellen)

```
# Management
k8s-mgmt-10.eneg.de       -> 192.168.180.10

# DEV Cluster Nodes
k8s-dev-21.eneg.de        -> 192.168.180.21
k8s-dev-22.eneg.de        -> 192.168.180.22
k8s-dev-23.eneg.de        -> 192.168.180.23

# DEV Apps (Wildcard)
*-dev.eneg.de             -> 192.168.180.100

# TEST Cluster Nodes
k8s-test-21.eneg.de       -> 192.168.179.21
k8s-test-22.eneg.de       -> 192.168.179.22
k8s-test-23.eneg.de       -> 192.168.179.23

# TEST Apps (Wildcard)
*-test.eneg.de            -> 192.168.179.100

# PROD Cluster Nodes
k8s-prod-21.eneg.de       -> 192.168.178.21
k8s-prod-22.eneg.de       -> 192.168.178.22
k8s-prod-23.eneg.de       -> 192.168.178.23

# PROD Apps (ohne Suffix)
*.eneg.de                 -> 192.168.178.100
```

---

## 5. Naming Conventions

### Allgemeine Regeln

- Lowercase mit Bindestrichen
- Keine Umgebungs-Suffixe in Kubernetes-Ressourcen (da separate Cluster)
- Konsistent Ã¼ber alle Ebenen

### Schema

| Bereich | Schema | Beispiel |
|---------|--------|----------|
| VMs | `k8s-{env}-{nr}` | k8s-dev-21, k8s-prod-23 |
| Kubernetes Namespaces | `{app}` | n8n, odoo, monitoring |
| Helm Releases | `{app}` | n8n, traefik |
| Secrets | `{app}-credentials` | odoo-credentials |
| ConfigMaps | `{app}-config` | n8n-config |
| PVCs | `{app}-data` | odoo-data |
| Services | `{app}` | n8n, traefik |
| Ingress | `{app}` | odoo, grafana |

### Namespace-Struktur

```
namespaces:
â”œâ”€â”€ argocd              # GitOps Controller
â”œâ”€â”€ cert-manager        # SSL-Zertifikate
â”œâ”€â”€ traefik             # Ingress Controller
â”œâ”€â”€ metallb-system      # LoadBalancer
â”œâ”€â”€ longhorn-system     # Storage
â”œâ”€â”€ databases           # CloudNativePG + MariaDB Galera
â”œâ”€â”€ monitoring          # Prometheus, Grafana, Loki, AlertManager
â”œâ”€â”€ n8n                 # Workflow Automation
â”œâ”€â”€ odoo                # ERP System
â”œâ”€â”€ openproject         # Projektmanagement
â”œâ”€â”€ keycloak            # Identity Management
â”œâ”€â”€ nextcloud           # File Sharing (spÃ¤ter)
â”œâ”€â”€ gitea               # Git Repository (spÃ¤ter)
â””â”€â”€ ...                 # Weitere Apps
```


---

## 6. Software-Stack

### Layer 0: Virtualisierung & OS

| Komponente | Version | Beschreibung |
|------------|---------|--------------|
| VMware vSphere | 8.03 / 6.7 | Hypervisor |
| Ubuntu Server | 24.04 LTS | Betriebssystem |

### Layer 1: Kubernetes Core

| Komponente | Beschreibung |
|------------|--------------|
| K3s | Lightweight Kubernetes (HA mit 3 Server-Nodes) |
| Calico | CNI fÃ¼r Netzwerk und Network Policies |
| MetalLB | Bare-Metal LoadBalancer (Layer 2) |
| Traefik | Ingress Controller |
| Cert-Manager | SSL-Zertifikatsverwaltung |
| Longhorn | Distributed Block Storage |

### Layer 2: GitOps & Secrets

| Komponente | Beschreibung |
|------------|--------------|
| ArgoCD | GitOps Continuous Delivery |
| Kustomize | Kubernetes-native Configuration Management |
| SOPS + Age | Secret-VerschlÃ¼sselung in Git |
| GitHub | Git Repository (privat, Monorepo) |

### Layer 3: Datenbanken

| Komponente | Beschreibung |
|------------|--------------|
| CloudNativePG | PostgreSQL Operator (1 Cluster/Env, 3 Instanzen) |
| MariaDB Galera | Multi-Master MariaDB (1 Cluster/Env, 3 Nodes) |

### Layer 4: Monitoring & Observability

| Komponente | Beschreibung |
|------------|--------------|
| Prometheus | Metriken-Sammlung |
| Thanos | Langzeit-Metriken-Speicherung |
| Grafana | Dashboards & Visualisierung |
| AlertManager | Alert-Routing & Benachrichtigungen |
| Loki | Log-Aggregation |
| Promtail | Log-Collector |

### Layer 5: Security

| Komponente | Beschreibung |
|------------|--------------|
| Kyverno | Policy Engine |
| Falco | Runtime Security Monitoring |
| Trivy Operator | Vulnerability Scanning |

### Layer 6: Identity & Backup

| Komponente | Beschreibung |
|------------|--------------|
| Keycloak | SSO & Identity Management |
| Velero | Kubernetes Backup |
| Vaultwarden | Password Management (produktiv) |

### Layer 7: Business Applications

**Pilot-Anwendungen (PrioritÃ¤t 1):**

| App | Datenbank | User | Beschreibung |
|-----|-----------|------|--------------|
| n8n | PostgreSQL | 10 | Workflow Automation |
| OpenProject | PostgreSQL | 25 | Projektmanagement |
| Odoo | PostgreSQL | 50 | ERP System |

**Weitere Anwendungen (PrioritÃ¤t 2):**

| App | Datenbank | User | Beschreibung |
|-----|-----------|------|--------------|
| Nextcloud | MariaDB | 100 | File Sharing |
| i-doit | MariaDB | 30 | IT-Dokumentation |
| KixDesk | MariaDB | 10 | Ticketing |
| Papermerge | PostgreSQL | 20 | Document Management |
| Keycloak | PostgreSQL | - | Identity Management |
| Gitea | PostgreSQL | 20 | Git Repository |


---

## 7. GitOps Workflow

### Repository-Struktur (Monorepo)

```
k8s-infrastructure/
â”œâ”€â”€ README.md
â”œâ”€â”€ .sops.yaml                    # SOPS VerschlÃ¼sselungsregeln
â”œâ”€â”€ .gitignore
â”‚
â”œâ”€â”€ docs/                         # Dokumentation
â”‚   â”œâ”€â”€ architecture/
â”‚   â”œâ”€â”€ runbooks/
â”‚   â””â”€â”€ decisions/
â”‚
â”œâ”€â”€ terraform/                    # OpenTofu
â”‚   â”œâ”€â”€ modules/
â”‚   â”‚   â””â”€â”€ vm/
â”‚   â”œâ”€â”€ environments/
â”‚   â”‚   â”œâ”€â”€ dev/
â”‚   â”‚   â”œâ”€â”€ test/
â”‚   â”‚   â””â”€â”€ prod/
â”‚   â””â”€â”€ vcenter-credentials.enc.yaml
â”‚
â”œâ”€â”€ ansible/
â”‚   â”œâ”€â”€ inventory/
â”‚   â”œâ”€â”€ playbooks/
â”‚   â””â”€â”€ roles/
â”‚
â”œâ”€â”€ packer/
â”‚   â””â”€â”€ ubuntu-24.04/
â”‚
â””â”€â”€ kubernetes/
    â”œâ”€â”€ base/                     # Gemeinsame Basis
    â”‚   â”œâ”€â”€ argocd/
    â”‚   â”œâ”€â”€ metallb/
    â”‚   â”œâ”€â”€ traefik/
    â”‚   â”œâ”€â”€ cert-manager/
    â”‚   â”œâ”€â”€ longhorn/
    â”‚   â”œâ”€â”€ cloudnative-pg/
    â”‚   â”œâ”€â”€ mariadb-galera/
    â”‚   â”œâ”€â”€ monitoring/
    â”‚   â””â”€â”€ apps/
    â”‚
    â””â”€â”€ environments/
        â”œâ”€â”€ dev/
        â”‚   â”œâ”€â”€ kustomization.yaml
        â”‚   â”œâ”€â”€ patches/
        â”‚   â””â”€â”€ secrets/
        â”œâ”€â”€ test/
        â””â”€â”€ prod/
```

### Git Workflow: Single Branch + Kustomize

**Branch-Strategie:** Alle Ã„nderungen auf `main`

**Promotion-Pfad:** DEV â†’ TEST â†’ PROD

```
+------------------------------------------------------------------+
|                         main branch                              |
|                                                                  |
|  kubernetes/base/app/          Gemeinsame Definition             |
|       |                                                          |
|       +-- environments/dev/    Kustomize Overlay fÃ¼r DEV         |
|       |       |                                                  |
|       |       +-- ArgoCD DEV synct automatisch                   |
|       |                                                          |
|       +-- environments/test/   Kustomize Overlay fÃ¼r TEST        |
|       |       |                                                  |
|       |       +-- ArgoCD TEST synct automatisch                  |
|       |                                                          |
|       +-- environments/prod/   Kustomize Overlay fÃ¼r PROD        |
|               |                                                  |
|               +-- ArgoCD PROD synct automatisch                  |
+------------------------------------------------------------------+
```

### Deployment-Workflow

1. **Ã„nderung entwickeln:**
   - Ã„nderung in `kubernetes/base/` oder `environments/dev/`
   - Lokales Testen mit `kustomize build environments/dev/`

2. **Nach DEV deployen:**
   - `git commit && git push`
   - ArgoCD synct automatisch nach DEV-Cluster
   - Testen in DEV

3. **Nach TEST promoten:**
   - Overlay in `environments/test/` anpassen (falls nÃ¶tig)
   - `git commit && git push`
   - ArgoCD synct automatisch nach TEST-Cluster

4. **Nach PROD promoten:**
   - Overlay in `environments/prod/` anpassen (falls nÃ¶tig)
   - `git commit && git push`
   - ArgoCD synct automatisch nach PROD-Cluster


---

## 8. Datenbank-Strategie

### Architektur: Ein Cluster pro Umgebung

**Entscheidung:** Hybrid-Ansatz fÃ¼r Ressourceneffizienz

```
+------------------------------------------------------------------+
|                    DEV Environment                               |
|                                                                  |
|  +-----------------------------+  +-----------------------------+|
|  |   PostgreSQL (CloudNativePG)|  |   MariaDB (Galera)         ||
|  |   3 Instanzen, Sync Repl.   |  |   3 Nodes, Multi-Master    ||
|  |                             |  |                            ||
|  |   Databases:                |  |   Databases:               ||
|  |   - keycloak                |  |   - nextcloud              ||
|  |   - odoo                    |  |   - idoit                  ||
|  |   - openproject             |  |   - kixdesk                ||
|  |   - n8n                     |  |                            ||
|  |   - papermerge              |  |                            ||
|  |   - gitea                   |  |                            ||
|  +-----------------------------+  +-----------------------------+|
+------------------------------------------------------------------+
```

### CloudNativePG Cluster Definition

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-cluster
  namespace: databases
spec:
  instances: 3
  
  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "200"
      effective_cache_size: "768MB"
  
  storage:
    size: 50Gi
    storageClass: longhorn
  
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-backups/postgres/dev
      endpointURL: https://nas10.eneg.de:9000
      s3Credentials:
        accessKeyId:
          name: s3-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-credentials
          key: SECRET_ACCESS_KEY
    retentionPolicy: "30d"
```

### Backup-Arten

| Backup-Typ | Methode | Frequenz | Retention |
|------------|---------|----------|-----------|
| WAL-Archivierung | Kontinuierlich auf S3 | Echtzeit | 7 Tage |
| Physical Backup | Barman (Full Cluster) | TÃ¤glich 02:00 | 30 Tage |
| Logical Backup | pg_dump (ScheduledBackup) | TÃ¤glich 03:00 | 30 Tage |

### pg_dump ScheduledBackup

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: daily-logical-backup
  namespace: databases
spec:
  schedule: "0 3 * * *"
  backupOwnerReference: cluster
  cluster:
    name: cnpg-cluster
  method: dump
  target: prefer-standby
```


---

## 9. Monitoring & Alerting

### Architektur

```
+-------------+     +-------------+     +-------------+
| Prometheus  |---->| AlertManager|---->|   E-Mail    |
|  (Metriken) |     |  (Routing)  |     |   Teams     |
+-------------+     +-------------+     +-------------+
       |                   |
       |                   |
       v                   v
+-------------+     +-------------+
|   Grafana   |     |    Loki     |
| (Dashboard) |     |   (Logs)    |
+-------------+     +-------------+
```

### Alert-Schwellwerte

| Metrik | Warning | Critical |
|--------|---------|----------|
| RAM-Auslastung | 80% | 90% |
| Disk-Space | 80% | 90% |
| CPU-Auslastung | 85% (sustained) | 95% (sustained) |
| Backup-Space (NAS) | 85% | 95% |

**Hinweis:** CPU-Alerts nur bei anhaltender Last (>5 Min), nicht bei kurzen Spitzen.

### Alert-Routing

```yaml
# AlertManager Konfiguration
global:
  smtp_smarthost: 'smtp.eneg.de:587'
  smtp_from: 'alertmanager@eneg.de'

receivers:
  - name: 'email-primary'
    email_configs:
      - to: 'd.henke@eneg.de'
        send_resolved: true

  - name: 'teams-dev'
    msteams_configs:
      - webhook_url: 'https://outlook.office.com/webhook/dev-channel-webhook'

  - name: 'teams-test'
    msteams_configs:
      - webhook_url: 'https://outlook.office.com/webhook/test-channel-webhook'

  - name: 'teams-prod'
    msteams_configs:
      - webhook_url: 'https://outlook.office.com/webhook/prod-channel-webhook'

route:
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'email-primary'
  
  routes:
    - match:
        environment: dev
      receiver: 'teams-dev'
      continue: true
    
    - match:
        environment: test
      receiver: 'teams-test'
      continue: true
    
    - match:
        environment: prod
        severity: critical
      receiver: 'teams-prod'
      continue: true
```

### Teams-Integration Setup

**Pro Umgebung einen Kanal erstellen:**

1. `#k8s-alerts-dev` - Entwicklungs-Alerts
2. `#k8s-alerts-test` - Test-Alerts
3. `#k8s-alerts-prod` - Produktions-Alerts (nur critical)


---

## 10. Backup-Strategie

### Ãœbersicht

| Was | Wohin | Frequenz | Retention | Tool |
|-----|-------|----------|-----------|------|
| PostgreSQL (WAL) | S3 (QuObject) | Kontinuierlich | 7 Tage | CloudNativePG |
| PostgreSQL (Full) | S3 (QuObject) | TÃ¤glich 02:00 | 30 Tage | Barman |
| PostgreSQL (Dump) | S3 (QuObject) | TÃ¤glich 03:00 | 30 Tage | pg_dump |
| MariaDB | S3/NFS | TÃ¤glich 02:30 | 30 Tage | mariabackup |
| Kubernetes Resources | S3 (QuObject) | TÃ¤glich 04:00 | 14 Tage | Velero |
| Longhorn Volumes | S3/NFS | TÃ¤glich 05:00 | 14 Tage | Longhorn |
| OpenTofu State | S3 (QuObject) | Bei jedem Apply | Versioniert | S3 Backend |
| VMs | Veeam | Bestehend | Bestehend | Veeam |

### Backup-Ziele

- **PrimÃ¤r:** nas10.eneg.de (QuObject S3)
- **SekundÃ¤r:** Weitere Sicherung auf andere Medien (nicht Teil dieses Projekts)

### S3 Buckets (zu erstellen)

| Bucket | Inhalt |
|--------|--------|
| k8s-backups-postgres | PostgreSQL Backups |
| k8s-backups-mariadb | MariaDB Backups |
| k8s-backups-velero | Kubernetes Resource Backups |
| k8s-backups-longhorn | Longhorn Volume Backups |
| k8s-terraform-state | OpenTofu State |

### Restore-Verfahren

| Szenario | Verfahren |
|----------|-----------|
| App-Deployment fehlerhaft | ArgoCD: Git Revert -> Auto-Sync |
| Kubernetes Namespace gelÃ¶scht | Velero Restore |
| Datenbank-Korruption | CloudNativePG Point-in-Time Recovery |
| Einzelne Tabellen wiederherstellen | pg_dump Restore |
| VM ausgefallen | Veeam Restore |
| Cluster komplett defekt | Neu aufsetzen via OpenTofu + Velero Restore |

---

## 11. Security

### Zugriffskontrolle

| Zugriff | Methode | Details |
|---------|---------|---------|
| SSH auf VMs | SSH-Key (Ed25519) | Kein Passwort-Login |
| vCenter API | Service Account | Dedizierter User fÃ¼r OpenTofu |
| GitHub | Deploy Key (read-only) | FÃ¼r ArgoCD |
| kubectl | kubeconfig | Management-VM + Windows Laptop + MacBook |
| App-Login | Lokale Admins + Keycloak SSO | 1-3 lokale Admins pro App |

### kubectl Zugriff

- Management-VM: Direkt via kubeconfig
- Windows Laptop: Via SSH MCP oder lokales kubeconfig
- MacBook: Via SSH MCP oder lokales kubeconfig

### Network Policies

- Namespace-Isolation via Calico
- Nur explizit erlaubte Kommunikation
- Ingress nur Ã¼ber Traefik

### Policy Engine (Kyverno)

- Pod Security Standards (Baseline/Restricted)
- Image Policies (nur erlaubte Registries)
- Resource Quotas
- Label Requirements


---

## 12. SSL-Zertifikate

### Let's Encrypt via DNS-01 Challenge (IONOS)

**Bereits konfiguriert im VorgÃ¤ngerprojekt:**

- Domain: eneg.de (bei IONOS gehostet)
- Cert-Manager Version: v1.16.2
- Webhook: cert-manager-webhook-ionos (fabmade)
- ClusterIssuer: letsencrypt-staging, letsencrypt-prod

### ClusterIssuer Konfiguration

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@eneg.de
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          webhook:
            groupName: acme.fabmade.de
            solverName: ionos
            config:
              apiUrl: https://api.hosting.ionos.com/dns/v1
              publicKeySecretRef:
                key: IONOS_PUBLIC_PREFIX
                name: ionos-secret
              secretKeySecretRef:
                key: IONOS_SECRET
                name: ionos-secret
```

### IONOS Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ionos-secret
  namespace: cert-manager
type: Opaque
stringData:
  IONOS_PUBLIC_PREFIX: "<aus 1Password>"
  IONOS_SECRET: "<aus 1Password>"
```

### DNS-Konfiguration fÃ¼r externe Resolver

```yaml
# cert-manager-values.yaml
extraArgs:
  - --dns01-recursive-nameservers=8.8.8.8:53,1.1.1.1:53
  - --dns01-recursive-nameservers-only
```

---

## 13. Implementierungsplan

### Phasen-Ãœbersicht

| Phase | Beschreibung | Dauer | Status |
|-------|--------------|-------|--------|
| 0 | Vorbereitung & Workstation Setup | 1-2 Tage | ✅ Abgeschlossen |
| 1 | Ubuntu-Template & VM-Automatisierung | 2-3 Tage | ✅ Abgeschlossen |
| 2 | K3s DEV-Cluster | 1 Tag | ✅ Abgeschlossen |
| 3 | GitOps-Fundament (ArgoCD, SOPS, GitHub) | 2-3 Tage | ✅ Abgeschlossen |
| 4 | Kubernetes-Basis (MetalLB, Traefik, Cert-Manager, Longhorn) | 2-3 Tage | Offen |
| 5 | Datenbank-Cluster (CloudNativePG, MariaDB Galera) | 2-3 Tage | Offen |
| 6 | Pilot-Apps (n8n, OpenProject, Odoo) | 3-5 Tage | Offen |
| 7 | Monitoring-Stack | 2-3 Tage | Offen |
| 8 | TEST & PROD Rollout | 2-3 Tage | Offen |
| 9 | Security & HÃ¤rtung | 3-5 Tage | Offen |
| 10 | Backup & Dokumentation | 2-3 Tage | Offen |

**GeschÃ¤tzte Gesamtdauer:** 20-32 Arbeitstage

### Phase 0: Vorbereitung & Workstation Setup âœ…

**Ziel:** Arbeitsstationen und Management-VM bereit fÃ¼r alle Phasen

**Abgeschlossen am:** 04.02.2026

**Windows Laptop:**
- [x] Git installieren
- [x] Node.js installieren (fÃ¼r MCP Server)
- [x] SSH-Key generieren (Ed25519)
- [x] Desktop Commander MCP konfigurieren
- [x] kubectl installieren

**MacBook/MacMini:**
- [x] Desktop Commander MCP konfigurieren
- [x] allowedDirectories konfigurieren (/Users/danielhenke/git)
- [x] Repository geklont

**GitHub:**
- [x] Repository erstellen (privat): eneg-k8s-infrastructure-v2
- [x] Basis-Struktur angelegt
- [x] SSH-Key fÃ¼r Management-VM hinzugefÃ¼gt

**Management-VM (k8s-mgmt-10.eneg.de):**
- [x] VM in vCenter-A erstellt (Host: S2843, Datastore: S2843_SSD_01_VMS)
- [x] Ubuntu 24.04 LTS installiert
- [x] Statische IP konfiguriert (192.168.180.10)
- [x] System aktualisiert (apt update/upgrade)
- [x] SSH-Key generiert und in GitHub hinterlegt
- [x] Git konfiguriert (user.name, user.email)
- [x] Repository geklont nach ~/git/eneg-k8s-infrastructure-v2
- [x] Alle Tools installiert (siehe Tool-Versionen unten)

**Installierte Tool-Versionen auf k8s-mgmt-10:**

| Tool | Version | Installationsmethode |
|------|---------|---------------------|
| OpenTofu | 1.11.4 | install-opentofu.sh (deb) |
| Ansible | 2.20.2 (core) | PPA ansible/ansible |
| Packer | 1.15.0 | HashiCorp APT Repository |
| kubectl | 1.35.0 | Kubernetes APT Repository (v1.35) |
| Helm | 3.20.0 | get-helm-3 Script |
| SOPS | 3.11.0 | GitHub Release Binary |
| Age | 1.1.1 | apt (Ubuntu Repository) |
| Git | 2.43.0 | apt (Ubuntu Repository) |

**Hinweis:** Bei kubectl wurde initial das v1.32 Repository verwendet, was zu einer veralteten Version fÃ¼hrte. Dies wurde korrigiert durch Wechsel auf das v1.35 Repository, da Kubernetes 1.32 am 28.02.2026 End-of-Life erreicht.

### Phase 2: K3s HA-Cluster Installation ✅

**Ziel:** Automatisierte K3s HA-Installation mit Ansible

**Abgeschlossen am:** 09.02.2026

**Erreichte Ziele:**
- [x] Ansible-Struktur aufgebaut (Inventory, Playbooks, Roles)
- [x] SSH-Key-Management implementiert
- [x] K3s v1.35.0+k3s3 auf 3 Nodes installiert
- [x] HA-Cluster mit embedded etcd konfiguriert
- [x] Version-Pinning statt Channels implementiert
- [x] Upgrade-Fähigkeit durch Versions-Check
- [x] Comprehensive Documentation (README, SSH-Keys, Troubleshooting)

**Cluster-Status:**
```
k8s-dev-21   Ready    control-plane,etcd   v1.35.0+k3s3
k8s-dev-22   Ready    control-plane,etcd   v1.35.0+k3s3
k8s-dev-23   Ready    control-plane,etcd   v1.35.0+k3s3
```

**Wichtige Learnings:**
- K3s Token-Format: Simple Password für ersten Server, K10-Format für Additional Servers
- Version Pinning bevorzugt gegenüber Channels für Reproduzierbarkeit
- Token niemals bei laufendem Cluster ändern (etcd-Verschlüsselung!)
- Upgrade-Erkennung durch Version-Vergleich implementiert

**Dokumentation:**
- `docs/phase-02-abschluss.md` - Vollständiger Phasenbericht
- `ansible/README.md` - Ansible-Nutzungsanleitung
- `ansible/SSH-KEYS.md` - SSH-Key Quick Reference
- `docs/SSH-KEY-MANAGEMENT.md` - Umfassende SSH-Dokumentation

**kubeconfig-Speicherort:**
- Management-VM: `~/git/eneg-k8s-infrastructure-v2/kubeconfig-dev.yaml`

**Deaktivierte K3s-Komponenten (für GitOps):**
- Traefik (wird in Phase 4 manuell installiert)
- ServiceLB (wird durch MetalLB ersetzt)
- Local-Storage (wird durch Longhorn ersetzt)

---

## 14. Dokumentation

### Speicherort

- **PrimÃ¤r:** `/docs` im Git Repository
- **Format:** Markdown (.md)
- **ErgÃ¤nzend:** README.md in jedem Unterverzeichnis

### Dokumentationsstruktur

```
docs/
â”œâ”€â”€ architecture/
â”‚   â”œâ”€â”€ overview.md
â”‚   â”œâ”€â”€ network.md
â”‚   â”œâ”€â”€ storage.md
â”‚   â””â”€â”€ security.md
â”œâ”€â”€ runbooks/
â”‚   â”œâ”€â”€ deployment.md
â”‚   â”œâ”€â”€ backup-restore.md
â”‚   â”œâ”€â”€ troubleshooting.md
â”‚   â””â”€â”€ disaster-recovery.md
â”œâ”€â”€ decisions/
â”‚   â”œâ”€â”€ ADR-001-kubernetes-distribution.md
â”‚   â”œâ”€â”€ ADR-002-database-strategy.md
â”‚   â””â”€â”€ ...
â””â”€â”€ guides/
    â”œâ”€â”€ onboarding.md
    â”œâ”€â”€ kubectl-access.md
    â””â”€â”€ adding-new-app.md
```

### Dokumentationsprinzipien

1. **Aktuell halten:** Dokumentation wird direkt nach erfolgreicher Implementierung erstellt
2. **Versioniert:** Alle Ã„nderungen via Git nachvollziehbar
3. **Praktisch:** Fokus auf Runbooks und konkrete Anleitungen
4. **Entscheidungen dokumentieren:** Architecture Decision Records (ADRs) fÃ¼r wichtige Entscheidungen

---

## Anhang A: Tool-Versionen

### Management-VM (k8s-mgmt-10) - Stand 04.02.2026

| Tool | Version | Hinweis |
|------|---------|---------|
| Ubuntu Server | 24.04 LTS | Bis April 2029 unterstÃ¼tzt |
| OpenTofu | 1.11.4 | Aktuell (Released 21.01.2026) |
| Ansible | 2.20.2 (core) | Aktuell (Released 29.01.2026) |
| Packer | 1.15.0 | Aktuell |
| kubectl | 1.35.0 | Aktuell (K8s 1.35 Released 17.12.2025) |
| Helm | 3.20.0 | Aktuell |
| SOPS | 3.11.0 | Aktuell |
| Age | 1.1.1 | Aktuell |
| Git | 2.43.0 | Ubuntu Default |

### Kubernetes Cluster (geplant)

| Tool | Version | Hinweis |
|------|---------|---------|
| K3s | Latest Stable | Wird bei Installation ermittelt |
| ArgoCD | Latest Stable | |
| Cert-Manager | 1.16.x | |
| Longhorn | Latest Stable | |
| CloudNativePG | Latest Stable | |
| Prometheus Stack | Latest Stable | kube-prometheus-stack Helm Chart |

---

## Anhang B: Kontakte & ZugÃ¤nge

| System | Zugangsdaten |
|--------|--------------|
| vCenter-A (vcenter-a.eneg.de) | In 1Password |
| IONOS API | In 1Password |
| GitHub | eneg-k8s-infrastructure-v2 |
| NAS (nas10.eneg.de) | In 1Password |

---

## Ã„nderungshistorie

| Datum | Version | Ã„nderung | Autor |
|-------|---------|----------|-------|
| 04.02.2026 | 1.0 | Initiale Version | Claude AI / D. Henke |
| 09.02.2026 | 1.2 | Phase 2 abgeschlossen: K3s v1.35.0+k3s3 HA-Cluster mit Ansible installiert, Version-Pinning implementiert, Umfassende Dokumentation erstellt | Claude AI / D. Henke |
| 16.02.2026 | 1.3 | Infrastruktur-Migration: Single vCenter (vcenter-a.eneg.de), S2842 neu aufgebaut (ESXi 8.0.3), Clean Slate DEV-Cluster mit K3s v1.35.1+k3s1, Rolling Upgrade implementiert, Phase 1+3 abgeschlossen | Claude AI / D. Henke |

---

*Dieses Dokument wird kontinuierlich aktualisiert, sobald neue Entscheidungen getroffen oder Phasen abgeschlossen werden.*
