
# GitOps Kubernetes-Infrastruktur auf VMware vSphere

## Projektplanung - Version 2.27

**Erstellt:** 04.02.2026  
**Letzte Aktualisierung:** 19.05.2026 (Velero AWS-SDK-go-v2 Checksum-Fix DEV: checksumAlgorithm leer fuer QNAP QuObjects)  
**Phase 9 gestartet:** 14.04.2026  
**Phase 9a vorbereitet:** 20.04.2026  
**Phase 9a Etappe A VOLLSTAENDIG abgeschlossen:** 21.04.2026 (DEV + TEST + PROD)  
**Phase 9a Etappe A Trivy Mirror Fix (DEV):** 22.04.2026  
**Phase 11 abgeschlossen:** 30.04.2026 (Rolling OS-Update DEV)  
**Phase 12 abgeschlossen:** 06.05.2026 (HA-Improvements DEV — Zot + CoreDNS)  
**Phase 12b CoreDNS HA komplett:** 07.05.2026 (TEST 06.05. + PROD 07.05.)  
**Incident DEV 10.-12.05.2026 abgeschlossen:** 12.05.2026 (3 Tage Recovery, alle 3 DB-Cluster + 37/37 Longhorn-Volumes geheilt)  
**Incident DEV 16.05.2026 abgeschlossen:** 16.05.2026 (cnpg-erp Frozen Replica + WAL-Stau, ~90 Min Recovery via PVC-Recreation)  
**Backup-Subsystem-Reparatur DEV 17.05.2026 abgeschlossen:** 17.05.2026 (Cron-Format-Bug behoben + Bucket-Reset, Backups laufen wieder in 51s)  
**i-doit-Backup Tarball-Refactor 17.05.2026 abgeschlossen:** 17.05.2026 (DEV verifiziert: 2h Timeout -> 9s Tarball-Upload; TEST+PROD GitOps-konfiguriert)  
**Velero AWS-SDK Checksum-Fix DEV 19.05.2026 abgeschlossen:** 19.05.2026 (Daily-Backups schlugen seit 14.05. mit InvalidDigest fehl; gefixt via `checksumAlgorithm: ""` in BSL-Config; Test-Backup Completed, Cleanup der 10 Failed-Backups durchgefuehrt; TEST+PROD-Rollout ausstehend)  
**Standort:** Hamburg  
**Projekt:** eNeG K8s Infrastructure v2

---

## Inhaltsverzeichnis

1. [Executive Summary](#1-executive-summary)
2. [Infrastruktur-Uebersicht](#2-infrastruktur-uebersicht)
3. [Architektur-Entscheidungen](#3-architektur-entscheidungen)
4. [Netzwerk-Konfiguration](#4-netzwerk-konfiguration)
5. [Naming Conventions](#5-naming-conventions)
6. [Software-Stack](#6-software-stack)
7. [GitOps Workflow](#7-gitops-workflow)
8. [Datenbank-Strategie](#8-datenbank-strategie)
9. [Monitoring und Alerting](#9-monitoring-und-alerting)
10. [Backup-Strategie](#10-backup-strategie)
11. [Security](#11-security)
12. [SSL-Zertifikate](#12-ssl-zertifikate)
13. [Implementierungsplan](#13-implementierungsplan)
14. [Dokumentation](#14-dokumentation)

---

## 1. Executive Summary

### Projektziel

Aufbau einer vollstaendig automatisierten, GitOps-basierten Kubernetes-Infrastruktur
mit drei Umgebungen (DEV, TEST, PROD) auf VMware vSphere.

### Kernprinzipien

- **Infrastructure as Code:** Alle Ressourcen werden durch Code definiert (OpenTofu, Ansible, Kubernetes Manifests)
- **GitOps:** Git als Single Source of Truth, ArgoCD fuer automatische Synchronisation
- **Promotion Pipeline:** Aenderungen durchlaufen immer DEV -> TEST -> PROD
- **Stabilitaet vor Geschwindigkeit:** Erprobte, stabile Loesungen haben Vorrang

### Technologie-Stack (Kurzuebersicht)

| Bereich | Technologie | Version |
|---------|-------------|---------|
| Kubernetes | K3s HA-Cluster (3 Nodes) | v1.35.1+k3s1 |
| OS | Ubuntu Server | 24.04.4 LTS |
| IaC | OpenTofu / Ansible / Packer | 1.11.4 / 2.20.2 / 1.15.0 |
| GitOps | ArgoCD + Kustomize + SOPS + Age | v3.3.0 |
| LoadBalancer | MetalLB (L2) | v0.15.3 |
| Ingress | Traefik | v3.6.7 |
| SSL | Cert-Manager + IONOS Webhook | v1.17.2 |
| Storage (Block) | Longhorn (Distributed Block Storage) | v1.9.2 |
| Storage (Object) | Garage (In-Cluster S3) | v2.2.0 |
| Datenbanken | CloudNativePG (PostgreSQL) + MariaDB Galera | - |
| Monitoring | Prometheus + Grafana + Loki + AlertManager | - |
| Dashboard | Headlamp (Kubernetes Web UI) | Helm v0.41.0 |
| Secrets | SOPS + Age (verschluesselt in Git) | 3.11.0 / 1.1.1 |

---

## 2. Infrastruktur-Uebersicht

### VMware vSphere Umgebung

| vCenter | ESXi Version | Hardware | Datastore |
|---------|--------------|----------|-----------|
| vCenter-A | ESXi 8.03 | 3x Dell (48 Cores, 512GB RAM) | S2842_SSD_01_VMS, S2843_SSD_01_VMS, S3168_SSD_01_VMS |

**Alle K8s-VMs laufen auf ESXi 8.03 in vCenter-A.**

### VMware Hosts

| vCenter | Host-Nr | Host-Name | ESX-Version | Datastore |
|---------|---------|-----------|-------------|-----------|
| vCenter-A | HOST1 | s2842.eneg.de | ESXi 8.03 | S2842_SSD_01_VMS |
| vCenter-A | HOST2 | s2843.eneg.de | ESXi 8.03 | S2843_SSD_01_VMS |
| vCenter-A | HOST3 | s3168.eneg.de | ESXi 8.03 | S3168_SSD_01_VMS |

### VM-Uebersicht

```
+-----------------------------------------------------------------------------+
|                              MANAGEMENT                                      |
|  k8s-mgmt-10.eneg.de (192.168.180.10) - Ubuntu 24.04, 4 vCPU, 8GB RAM      |
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

### VM-Verteilung auf Hosts

Jeder Host bekommt aus jedem Environment genau eine VM:

| Host | DEV | TEST | PROD |
|------|-----|------|------|
| s2842 (ESXi 8.03) | k8s-dev-21 | k8s-test-21 | k8s-prod-21 |
| s2843 (ESXi 8.03) | k8s-dev-22 | k8s-test-22 | k8s-prod-22 |
| s3168 (ESXi 8.03) | k8s-dev-23 | k8s-test-23 | k8s-prod-23 |

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
| Kontrolle | Volle Kontrolle ueber alle Komponenten | Snap-basiert, eingeschraenkt |
| Groesse | ~40MB Binary | Groesser durch Snap |
| OS-Unabhaengigkeit | Funktioniert identisch auf allen Linux | Snap-Abhaengigkeit |
| GitOps-Integration | Alle Komponenten selbst verwaltet | Einige Addons "black box" |
| Debugging | Separate Prozesse, einfacher | Komplexer |

**Deaktivierte K3s-Komponenten (ersetzt durch GitOps-verwaltete Versionen):**
- Traefik (ersetzt durch Helm Chart v3.6.7)
- ServiceLB (ersetzt durch MetalLB)
- Local-Storage (ersetzt durch Longhorn)

### Betriebssystem: Ubuntu 24.04 LTS

**Entscheidung:** Ubuntu 24.04.4 (aktuell)

- Bessere Kubernetes-Dokumentation und Community-Support
- Neuere Kernel fuer VMware Tools Kompatibilitaet
- 5 Jahre Support (10 mit Ubuntu Pro)
- cloud-init growpart fuer automatische Disk-Erweiterung nach Clone

### Datenbanken: Kubernetes-native

**Entscheidung:** CloudNativePG + MariaDB Galera innerhalb Kubernetes

- CNCF Sandbox Projekt (CloudNativePG)
- Vollstaendige GitOps-Integration
- Automatisches HA/Failover
- Native Backup-Integration

### Ingress: Traefik (nicht nginx-ingress)

**Entscheidung:** Traefik v3 als Ingress Controller

- Bessere CRD-Integration (IngressRoute)
- Native Let's Encrypt Unterstuetzung (aber wir nutzen cert-manager)
- Besseres Middleware-System
- Aktive Weiterentwicklung

---

## 4. Netzwerk-Konfiguration

### VLANs und IP-Bereiche

| Umgebung | VLAN | Netzwerk | Gateway | DNS Server |
|----------|------|----------|---------|------------|
| DEV  | 180 | 192.168.180.0/24 | .247 | 192.168.161.104-106 |
| TEST | 179 | 192.168.179.0/24 | .247 | 192.168.161.104-106 |
| PROD | 178 | 192.168.178.0/24 | .247 | 192.168.161.104-106 |

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

### DNS-Eintraege

```
# Management
k8s-mgmt-10.eneg.de       -> 192.168.180.10

# DEV Cluster Nodes
k8s-dev-21.eneg.de        -> 192.168.180.21
k8s-dev-22.eneg.de        -> 192.168.180.22
k8s-dev-23.eneg.de        -> 192.168.180.23

# DEV Apps (einzelne Eintraege, CNAME auf Traefik)
traefik-dev.eneg.de       -> 192.168.180.100  (A-Record)
argocd-dev-v2.eneg.de     -> traefik-dev.eneg.de  (CNAME)
longhorn-dev-v2.eneg.de   -> traefik-dev.eneg.de  (CNAME)
s3-dev-v2.eneg.de         -> traefik-dev.eneg.de  (CNAME, Garage S3 API)
s3-gui-dev-v2.eneg.de     -> traefik-dev.eneg.de  (CNAME, Garage WebUI)
<app>-dev.eneg.de         -> traefik-dev.eneg.de  (CNAME, pro App)

# TEST Apps (einzelne Eintraege, CNAME auf Traefik)
traefik-test.eneg.de      -> 192.168.179.100  (A-Record)
argocd-test.eneg.de       -> traefik-test.eneg.de  (CNAME)
longhorn-test.eneg.de     -> traefik-test.eneg.de  (CNAME)
<app>-test.eneg.de        -> traefik-test.eneg.de  (CNAME, pro App)

# PROD Apps (einzelne Eintraege, CNAME auf Traefik)
traefik-prod.eneg.de      -> 192.168.178.100  (A-Record)
argocd-prod.eneg.de       -> traefik-prod.eneg.de  (CNAME)
longhorn-prod.eneg.de     -> traefik-prod.eneg.de  (CNAME)
k8s-dashboard-prod.eneg.de -> traefik-prod.eneg.de  (CNAME)
s3-prod.eneg.de           -> traefik-prod.eneg.de  (CNAME, Garage S3 API)
s3-gui-prod.eneg.de       -> traefik-prod.eneg.de  (CNAME, Garage WebUI)
n8n.eneg.de               -> traefik-prod.eneg.de  (CNAME)
keycloak.eneg.de          -> traefik-prod.eneg.de  (CNAME)
openproject.eneg.de       -> traefik-prod.eneg.de  (CNAME)
odoo.eneg.de              -> traefik-prod.eneg.de  (CNAME)
idoit.eneg.de             -> traefik-prod.eneg.de  (CNAME)
it-info-versand.eneg.de   -> traefik-prod.eneg.de  (CNAME)
```

**Hinweis:** Fuer alle Umgebungen (DEV, TEST, PROD) werden DNS-Eintraege einzeln pro App angelegt (kein Wildcard).
PROD user-facing Apps nutzen `appname.eneg.de`, interne PROD-Tools nutzen `appname-prod.eneg.de`.

---

## 5. Naming Conventions

### Allgemeine Regeln

- Lowercase mit Bindestrichen
- Keine Umgebungs-Suffixe in Kubernetes-Ressourcen (separate Cluster)
- Konsistent ueber alle Ebenen

### Schema

| Bereich | Schema | Beispiel |
|---------|--------|----------|
| VMs | `k8s-{env}-{nr}` | k8s-dev-21, k8s-prod-23 |
| Kubernetes Namespaces | `{app}` | n8n, odoo, monitoring |
| Helm Releases | `{app}` | n8n, traefik |
| Secrets (DB, databases NS) | `{app}-db-credentials` | n8n-db-credentials |
| Secrets (App, app NS) | `{app}-secrets` | n8n-secrets |
| ConfigMaps | `{app}-config` | n8n-config |
| PVCs | `{app}-data` | odoo-data |
| Services | `{app}` | n8n, traefik |
| DNS (DEV) | `{app}-dev-v2.eneg.de` | argocd-dev-v2.eneg.de |
| DNS (TEST) | `{app}-test.eneg.de` | grafana-test.eneg.de |
| DNS (PROD, User-facing) | `{app}.eneg.de` | odoo.eneg.de |
| DNS (PROD, Interne Tools) | `{app}-prod.eneg.de` | argocd-prod.eneg.de |

### Namespace-Struktur

```
namespaces:
├── argocd              # GitOps Controller
├── cert-manager        # SSL-Zertifikate
├── cnpg-system         # CloudNativePG Operator
├── traefik             # Ingress Controller
├── metallb-system      # LoadBalancer
├── longhorn-system     # Storage (Block)
├── garage              # Storage (Object/S3)
├── mariadb-operator    # MariaDB Operator
├── databases           # CloudNativePG Cluster + MariaDB Galera Cluster
├── headlamp            # Kubernetes Web Dashboard
├── monitoring          # Prometheus, Grafana, Loki, AlertManager (Phase 7)
├── velero              # Kubernetes Backup & Disaster Recovery (Phase 10)
├── kyverno             # Policy Engine (Phase 9)
├── trivy-system        # Vulnerability Scanner (Phase 9)
├── crowdsec            # WAF + Brute-Force-Schutz (Phase 9)
├── falco               # Runtime Security Monitoring (Phase 9)
├── n8n                 # Workflow Automation
├── keycloak            # Identity Management (SSO, OIDC)
├── idoit               # IT-Dokumentation
├── it-info-versand     # IT-Informationsverteilung
├── odoo                # ERP System
├── openproject         # Projektmanagement
├── nextcloud           # File Sharing (geplant)
├── gitea               # Git Repository (geplant)
└── ...                 # Weitere Apps
```

---

## 6. Software-Stack

### Layer 0: Virtualisierung und OS

| Komponente | Version | Status |
|------------|---------|--------|
| VMware vSphere | 8.03 (3 Hosts in vCenter-A) | Produktiv |
| Ubuntu Server | 24.04.4 LTS | Produktiv |
| Packer Template | 24.04.4 (s3168) | Aktuell |

### Layer 1: Kubernetes Core

| Komponente | Version | Status |
|------------|---------|--------|
| K3s | v1.35.1+k3s1 | Produktiv |
| MetalLB | v0.15.3 | Produktiv |
| Traefik | v3.6.7 (Chart v39.0.0) | Produktiv |
| Cert-Manager | v1.17.2 | Produktiv |
| IONOS Webhook | latest | Produktiv |
| Longhorn | v1.9.2 | Produktiv |
| Garage (S3 Object Storage) | v2.2.0 | Produktiv |

### Layer 2: GitOps und Secrets

| Komponente | Version | Status |
|------------|---------|--------|
| ArgoCD | v3.3.0 | Produktiv |
| KSOPS | v4.4.0 | Produktiv |
| SOPS | 3.11.0 | Produktiv |
| Age | 1.1.1 | Produktiv |
| GitHub | - | Privates Monorepo |

### Layer 3: Datenbanken

| Komponente | Version | Status |
|------------|---------|--------|
| CloudNativePG Operator | 1.28.1 (Chart 0.27.1) | ✅ Installiert |
| MariaDB Galera | 11.8.6 LTS (Operator 25.10.4) | ✅ Installiert |

### Layer 4: Monitoring und Observability

| Komponente | Version | Status |
|------------|---------|--------|
| kube-prometheus-stack (Prometheus + Grafana + AlertManager) | Helm 83.0.0 | ✅ DEV/TEST/PROD |
| Thanos (bitnami) | Helm 17.3.1 | ✅ DEV/TEST/PROD |
| Loki (grafana) | Helm 6.55.0 | ✅ DEV/TEST/PROD |
| Grafana Alloy (ersetzt Promtail) | Helm 1.7.0 | ✅ DEV/TEST/PROD |
| Blackbox Exporter | Helm 11.9.1 | ✅ DEV/TEST/PROD |
| prometheus-msteams (Teams Adapter) | v1.5.4 | ✅ DEV/TEST/PROD |

### Layer 5: Security

| Komponente | Version | Status |
|------------|---------|--------|
| Kyverno | v1.17.1 (Helm 3.7.1) | ✅ DEV |
| Kyverno Policies (PSS) | Helm 3.7.1 | ✅ DEV |
| Trivy Operator | v0.30.1 (Helm 0.32.1) | ✅ DEV |
| CrowdSec Security Engine | Helm (latest stable) | 🔧 Phase 9 (Ausstehend) |
| CrowdSec Traefik Bouncer | Plugin v1.3.3 | 🔧 Phase 9 (Ausstehend) |
| Falco | v0.42.x (Helm 8.0.1) | 🔧 Phase 9 (Ausstehend) |

### Layer 6: Identity und Backup

| Komponente | Version | Status |
|------------|---------|--------|
| Keycloak | 26.5.4 | ✅ Installiert |
| Velero | v1.17.1 (Helm 11.3.2) | ✅ Installiert |
| Vaultwarden | - | Offen |

### Layer 7: Business Applications

**Pilot-Anwendungen (Prioritaet 1):**

| App | Datenbank | User | Beschreibung |
|-----|-----------|------|--------------|
| n8n | PostgreSQL | 10 | Workflow Automation |
| Keycloak | PostgreSQL | - | Identity Management (SSO, OIDC, AD/LDAP) |
| i-doit | MariaDB | 30 | IT-Dokumentation (Custom Docker Image) |
| it-info-versand | PostgreSQL | - | IT-Informationsverteilung (Custom Docker Image) |
| OpenProject | PostgreSQL | 25 | Projektmanagement |
| Odoo | PostgreSQL | 50 | ERP System |

**Weitere Anwendungen (Prioritaet 2):**

| App | Datenbank | User | Beschreibung |
|-----|-----------|------|--------------|
| Nextcloud | MariaDB | 100 | File Sharing |
| KixDesk | MariaDB | 10 | Ticketing |
| Papermerge | PostgreSQL | 20 | Document Management |
| Gitea | PostgreSQL | 20 | Git Repository |

---

## 7. GitOps Workflow

### Repository-Struktur (Monorepo)

```
eneg-k8s-infrastructure-v2/
├── .sops.yaml                    # SOPS Verschluesselungsregeln
├── .gitignore
├── docs/                         # Dokumentation
│   ├── phases/                   # Phasen-Abschlussdokumente
│   ├── architecture/
│   ├── guides/                   # Anleitungen und Chat-Anweisungen
│   ├── runbooks/
│   └── decisions/                # Architektur-Entscheidungen (ADRs)
├── docker/                       # Custom Docker Images
│   └── idoit/                    # i-doit Open Dockerfile
├── scripts/                      # Hilfs-Skripte
│   ├── generate-prod-secrets.sh
│   ├── fix-prod-secrets.sh
│   └── update-kubeconfig.sh
├── packer/
│   └── ubuntu-24.04/             # VM-Template Konfiguration
├── terraform/                    # OpenTofu VM-Provisioning
│   ├── modules/vm/
│   └── environments/
│       ├── dev/
│       ├── test/
│       └── prod/
├── ansible/                      # Konfigurationsmanagement
│   ├── inventory/
│   │   ├── dev/
│   │   ├── test/
│   │   └── prod/
│   ├── playbooks/
│   │   ├── 01-setup-ssh-keys.yml
│   │   ├── 02-install-k3s.yml
│   │   ├── 03-system-maintenance.yml
│   │   ├── 04-longhorn-prerequisites.yml
│   │   └── 05-extend-disk.yml
│   ├── roles/
│   └── templates/
└── kubernetes/
    ├── bootstrap/                # Einmalige Bootstrap-Manifeste
    │   ├── namespace.yaml        # ArgoCD Namespace
    │   ├── argocd-app.yaml       # ArgoCD Self-Management (DEV)
    │   ├── dev-infrastructure-app.yaml
    │   ├── test-argocd-app.yaml
    │   ├── test-infrastructure-app.yaml
    │   ├── prod-argocd-app.yaml
    │   └── prod-infrastructure-app.yaml
    ├── base/                     # Gemeinsame Basis-Konfiguration (generisch)
    │   ├── argocd/               # KSOPS-Config, Cmd-Params, Helm-Repos
    │   ├── metallb/              # MetalLB Installation (ohne IP-Pools)
    │   ├── traefik/              # Helm Values generisch (ohne IPs/Hostnames)
    │   ├── cert-manager/         # ClusterIssuer, IONOS Webhook, Secrets
    │   ├── longhorn/             # Helm Values, StorageClass
    │   ├── cloudnative-pg/       # Operator, Cluster, Backup, Databases, Secrets
    │   ├── mariadb-galera/       # Operator, Cluster, Databases, Secrets
    │   ├── garage/               # S3 Object Storage (StatefulSet, WebUI, ConfigMap)
    │   ├── headlamp/             # Kubernetes Dashboard Helm Values
    │   ├── monitoring/           # Prometheus, Grafana, Loki, AlertManager (Platzhalter)
    │   └── apps/                 # Pilot-Apps (Basis-Manifeste + DEV-Secrets)
    │       ├── n8n/
    │       ├── keycloak/
    │       ├── idoit/
    │       ├── it-info-versand/
    │       ├── openproject/
    │       └── odoo/
    └── environments/             # Umgebungsspezifische Overlays
        ├── dev/
        │   ├── argocd/           # DEV: URL-Patch + Ingress
        │   ├── metallb/          # DEV: IP-Pool 192.168.180.x
        │   ├── traefik/          # DEV: LB-IP, Dashboard, Certificate
        │   ├── longhorn/         # DEV: Dashboard-Ingress
        │   ├── headlamp/         # DEV: Dashboard-Ingress
        │   ├── cnpg-cluster/     # DEV: CNPG Cluster-Spec
        │   ├── cnpg-backup/      # DEV: Backup CronJobs
        │   ├── mariadb-cluster/  # DEV: MariaDB Galera Cluster
        │   ├── garage/           # DEV: StatefulSet, Ingress
        │   ├── garage-backup/    # DEV: Backup CronJob
        │   ├── garage-secrets/   # DEV: Garage Secrets (SOPS)
        │   ├── garage-backup-secrets/
        │   ├── secrets/          # DEV: Umgebungs-Secrets
        │   ├── patches/          # DEV: Kustomize Patches
        │   ├── apps/             # DEV: App-Overlays (6 Pilot-Apps)
        │   └── infrastructure/   # DEV: ArgoCD App-Definitionen (39 Apps)
        ├── test/                 # TEST: Gleiche Struktur wie DEV
        │   ├── argocd/           # TEST: URL-Patch + Ingress
        │   ├── ...               # (analog zu DEV, VLAN 179)
        │   └── infrastructure/   # TEST: ArgoCD App-Definitionen (39 Apps)
        └── prod/                 # PROD: Gleiche Struktur wie DEV/TEST
            ├── argocd/           # PROD: URL-Patch + Ingress
            ├── ...               # (analog zu DEV, VLAN 178)
            └── infrastructure/   # PROD: ArgoCD App-Definitionen (39 Apps)
```

### Git Workflow: Branch-per-Environment + Pull Requests

**Branch-Strategie:** Drei Branches (`main`, `test`, `prod`), Promotion per PR.

**Promotion-Pfad:** DEV (main) → PR → TEST (test) → PR → PROD (prod)

### Deployment-Workflow

1. **Aenderung entwickeln:** In `kubernetes/base/` oder `environments/dev/` anpassen
2. **Nach DEV deployen:** `git push` auf `main` -> ArgoCD DEV synct automatisch
3. **Testen in DEV:** Funktionalitaet und Zertifikate pruefen
4. **Nach TEST promoten:** PR `main → test` auf GitHub erstellen, Diff pruefen, Merge
5. **Testen in TEST:** Funktionalitaet pruefen
6. **Nach PROD promoten:** PR `test → prod` auf GitHub erstellen, Diff pruefen, Merge

### App-of-Apps Pattern

ArgoCD verwaltet sich selbst und alle anderen Applications aus Git.
Aenderungen an ArgoCD-Konfiguration (ConfigMaps, Secrets, Helm Repos)
werden automatisch nach einem `git push` synchronisiert.

### Kustomize-Overlay Pattern (Multi-Environment)

Seit Version 2.5 nutzt das Projekt Kustomize-Overlays fuer Multi-Environment-Support.
Das Prinzip: `kubernetes/base/` enthaelt generische Konfiguration, die Umgebungs-Overlays
in `kubernetes/environments/{env}/` ergaenzen umgebungsspezifische Werte (IPs, Hostnames, Pools).

**Refactored auf Overlay-Basis (Phase 2-4 Infrastruktur):**

| Komponente | Base (generisch) | Environment-Overlay (spezifisch) |
|------------|------------------|----------------------------------|
| MetalLB | Installation (v0.15.3) | IP-Pool, L2Advertisement |
| Traefik | Helm Values (Deployment, Ports, Providers) | LoadBalancer-IP, MetalLB-Pool, Dashboard-Host, Certificate |
| Longhorn | Helm Values, StorageClass | Dashboard-Ingress (Certificate + IngressRoute) |
| ArgoCD | KSOPS-Config, Cmd-Params | Server-URL (per JSON-Patch), Ingress |
| Cert-Manager | ClusterIssuer, Values, IONOS Secret | _(generisch, kein Overlay noetig)_ |

**Refactored auf Overlay-Basis (Phase 5 Datenbanken):**

| Komponente | Base (generisch) | Environment-Overlay (spezifisch) |
|------------|------------------|----------------------------------|
| CNPG Operator | Helm Chart (v0.27.1) | _(generisch, kein Overlay noetig)_ |
| CNPG Cluster | Cluster-Spec (cnpg-shared, cnpg-erp) | S3-Backup-Buckets, Endpoint-URL |
| CNPG Backups | CronJob-Templates | Bucket-Prefix pro Umgebung |
| CNPG Secrets | _(in base fuer DEV)_ | DB-Credentials pro Umgebung (SOPS) |
| MariaDB Operator | Helm Chart (25.10.4) + CRDs | _(generisch, kein Overlay noetig)_ |
| MariaDB Cluster | Galera Cluster-Spec | S3-Backup-Ziel pro Umgebung |
| MariaDB Secrets | _(in base fuer DEV)_ | DB-Credentials pro Umgebung (SOPS) |

**Refactored auf Overlay-Basis (Phase 6 Apps + Phase 8):**

| Komponente | Base (generisch) | Environment-Overlay (spezifisch) |
|------------|------------------|----------------------------------|
| Garage S3 | ConfigMap, Services, StatefulSet, WebUI | Node-IDs, Ingress, Backup-Buckets |
| Headlamp | Helm Values | Dashboard-Ingress pro Umgebung |
| n8n | Deployment, Service, Namespace | Ingress (Hostname), Secrets (SOPS) |
| Keycloak | Deployment, Service, Namespace | Ingress (Hostname), KC_HOSTNAME, Secrets (SOPS) |
| i-doit | Deployment, Service, Namespace, PVC | Ingress (Hostname), Secrets + GHCR-Pull-Secret |
| it-info-versand | Deployment, Service, Namespace | Ingress (Hostname), OIDC-Config, Secrets (SOPS) |
| OpenProject | Deployment (Web, Worker, Seeder, Memcached, Hocuspocus), Service, Namespace | Ingress, S3-Config, SMTP, Secrets (SOPS) |
| Odoo | Deployment, Service, Namespace, ConfigMap | Ingress, Backup-CronJob + Secrets (SOPS) |

**ArgoCD App-Definitionen zeigen auf Overlay-Pfade:**
- Kustomize-basierte Apps: `path: kubernetes/environments/{env}/{component}`
- Helm-basierte Apps (Traefik, Longhorn): Multi-Source mit base + override valueFiles

**Entscheidungsdokument:** `docs/decisions/ADR-001-kustomize-overlay-pattern.md`

### Branch-Strategie: Branch-per-Environment (ADR-002)

**Entscheidung:** Migration von Single-Branch auf Branch-per-Environment.

| Branch | ArgoCD-Cluster | Zweck |
|--------|----------------|-------|
| `main` | DEV | Entwicklung, erste Tests |
| `test` | TEST | Integrationstests, Abnahme |
| `prod` | PROD | Produktivbetrieb |

**Promotion:** Per Pull Request auf GitHub (main → test → prod).
Jede Aenderung durchlaeuft DEV → TEST → PROD. Kein direkter Push auf test/prod.
Image-Tags sind fest getaggt und pro Umgebung individuell steuerbar.
Ressourcen (CPU/RAM) sind pro Umgebung unterschiedlich dimensioniert.

**Entscheidungsdokument:** `docs/decisions/ADR-002-branch-per-environment.md`
**Migrationsplan:** `docs/phases/phase-08e-branch-migration-handoff.md`

### Ingress-Pattern (Standard fuer alle Apps)

```
LAN-Anfrage auf <app>-dev.eneg.de
    |
    v
Traefik (192.168.180.100) - Namespace: traefik
  - IngressRoute (im traefik Namespace)
  - Certificate (im traefik Namespace, via cert-manager)
  - TLS-Terminierung
    |
    | HTTP cross-namespace
    v
Backend-App - Namespace: <app>
  - Service (ClusterIP, port 80/8080)
  - Kein TLS noetig (intern)
```

**Regeln:**
- Certificate und IngressRoute immer im **traefik** Namespace erstellen
- Backend-Service wird cross-namespace referenziert
- Backend laeuft auf HTTP (TLS wird von Traefik terminiert)

---

## 8. Datenbank-Strategie

### Architektur: Zwei PostgreSQL-Cluster + MariaDB Galera pro Umgebung

**Entscheidung:** Getrennte CNPG-Cluster nach Workload-Profil

```
DEV/TEST/PROD Environment (jeweils)

  cnpg-shared (CloudNativePG)         cnpg-erp (CloudNativePG)
  3 Instanzen, PostgreSQL 17.8        3 Instanzen, PostgreSQL 17.8
  Leichtgewichtige Apps               Schwergewichtige ERP-Apps
  shared_buffers: 256MB               shared_buffers: 512MB
  max_connections: 200                 max_connections: 100
                                      
  Databases:                           Databases:
  - n8n                                - odoo
  - keycloak                           - openproject
  - it_info_versand
  - (gitea, papermerge geplant)

  MariaDB Galera (Operator 25.10.4)
  3 Nodes, Multi-Master, MariaDB 11.8.6 LTS
  
  Databases:
  - idoit
  - (nextcloud, kixdesk geplant)
```

### CloudNativePG Cluster-Konfiguration (Basis)

```yaml
# cnpg-shared: Leichtgewichtige Apps
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-shared
  namespace: databases
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:17.8-system-bookworm
  instances: 3
  storage:
    size: 20Gi
    storageClass: longhorn-db
  walStorage:
    size: 5Gi
    storageClass: longhorn-db
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-{env}-postgres-wal/cnpg-shared/
      endpointURL: http://nas10.eneg.de:8010
      s3Credentials:
        accessKeyId: { name: cnpg-s3-credentials, key: ACCESS_KEY_ID }
        secretAccessKey: { name: cnpg-s3-credentials, key: SECRET_ACCESS_KEY }
    retentionPolicy: "7d"
  managed:
    roles:
      - name: n8n           # passwordSecret: n8n-db-credentials
      - name: keycloak       # passwordSecret: keycloak-db-credentials
      - name: it_info_versand # passwordSecret: it-info-versand-db-credentials
```

```yaml
# cnpg-erp: Schwergewichtige ERP-Apps (hoeher dimensioniert)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-erp
  namespace: databases
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:17.8-system-bookworm
  instances: 3
  storage:
    size: 20Gi
    storageClass: longhorn-db
  walStorage:
    size: 5Gi
    storageClass: longhorn-db
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-{env}-postgres-wal/cnpg-erp/
      endpointURL: http://nas10.eneg.de:8010
      s3Credentials:
        accessKeyId: { name: cnpg-s3-credentials, key: ACCESS_KEY_ID }
        secretAccessKey: { name: cnpg-s3-credentials, key: SECRET_ACCESS_KEY }
    retentionPolicy: "7d"
  managed:
    roles:
      - name: openproject   # passwordSecret: openproject-db-credentials
      - name: odoo          # passwordSecret: odoo-db-credentials
```

**Hinweis:** Die Basis-Specs in `kubernetes/base/cloudnative-pg/cluster/` enthalten DEV-Werte.
Umgebungsspezifische Anpassungen (S3-Buckets, Ressourcen) erfolgen per Overlay in
`kubernetes/environments/{env}/cnpg-cluster/`.

### Backup-Arten

| Backup-Typ | Methode | Frequenz | Retention |
|------------|---------|----------|-----------|
| WAL-Archivierung | Kontinuierlich auf S3 | Echtzeit | 7 Tage |
| Physical Backup | Barman (Full Cluster) | Taeglich 02:00 | 30 Tage |
| Logical Backup | pg_dump (ScheduledBackup) | Taeglich 03:00 | 30 Tage |

---

## 9. Monitoring und Alerting

### Architektur

```
Prometheus -> AlertManager -> E-Mail / Teams
     |
     v
Grafana (Dashboards) + Loki (Logs)
```

### Alert-Schwellwerte

| Metrik | Warning | Critical |
|--------|---------|----------|
| RAM-Auslastung | 80% | 90% |
| Disk-Space | 80% | 90% |
| CPU-Auslastung | 85% (sustained >5min) | 95% (sustained) |
| Backup-Space (NAS) | 85% | 95% |
| CNPG WAL-Volume Fuellstand | 70% | 85% |
| CNPG WAL-Archivierung fehlgeschlagen | >5 min ohne Archivierung | >15 min ohne Archivierung |
| CNPG Cluster Ready-Status | - | Cluster Not Ready >5 min |
| CronJob Backup fehlgeschlagen | 1x fehlgeschlagen | 2x hintereinander fehlgeschlagen |
| S3 Endpoint (NAS10) nicht erreichbar | - | Nicht erreichbar >5 min |

### Alert-Routing

- `#k8s-alerts-dev` - Entwicklungs-Alerts (alle Schweregrade)
- `#k8s-alerts-test` - Test-Alerts (alle Schweregrade)
- `#k8s-alerts-prod` - Produktions-Alerts (nur critical)
- E-Mail an d.henke@eneg.de fuer alle Environments

---

## 10. Backup-Strategie

### Uebersicht

Backup-Zeitplaene gestaffelt: PROD → TEST → DEV (keine NAS10-Ueberlappung).

| Was | Wohin | PROD | TEST | DEV | Retention | Tool |
|-----|-------|------|------|-----|-----------|------|
| PostgreSQL (WAL) | NAS10 S3 (k8s-{env}-postgres-wal) | laufend | laufend | laufend | 7 Tage | CloudNativePG/Barman |
| MariaDB (Physical) | NAS10 S3 (k8s-{env}-mariadb-backup) | 00:01 | 02:15 | 04:30 | 7 Tage (168h) | MariaDB Operator |
| PostgreSQL (Barman) | NAS10 S3 (k8s-{env}-postgres-wal) | 00:15/00:20 | 02:30/02:35 | 04:45/04:50 | 30 Tage | CNPG ScheduledBackup |
| PostgreSQL (Dump) | NAS10 S3 (k8s-{env}-postgres-backup) | 00:30/00:45 | 02:45/03:00 | 05:00/05:15 | 32 Tage | pg_dumpall CronJob |
| Garage S3-Inhalte | NAS10 S3 (k8s-{env}-garage-backup) | 01:00 | 03:15 | 05:30 | 32 Tage | rclone CronJob |
| Kubernetes + PVs | NAS10 S3 (k8s-{env}-velero) | 01:15 | 03:30 | 05:45 | 14 Tage | Velero v1.17.1 (kopia) |
| Odoo Filestore | NAS10 S3 (k8s-{env}-odoo-backup) | 01:45 | 04:00 | 06:15 | 32 Tage | rclone CronJob |
| i-doit Upload + src | NAS10 S3 (k8s-{env}-idoit) | 02:00 | 04:15 | 06:30 | 7 Tage | rclone Tarball CronJob |
| OpenTofu State | S3 (k8s-terraform-state, geplant) | Bei jedem Apply | - | - | Versioniert | S3 Backend |
| VMs | Veeam | Bestehend | Bestehend | Bestehend | Bestehend | Veeam |

**Zeitfenster:** PROD 00:01–02:00, TEST 02:15–04:15, DEV 04:30–06:30 (alle vor 07:00 fertig).

### Backup-Ziele

- **Primaer:** nas10.eneg.de (S3-kompatibler Object Storage, Port 8010, HTTP)
- **In-Cluster S3:** Garage — fuer App-Daten, Uploads, Attachments (pro Umgebung)
- **Sekundaer:** Weitere Sicherung auf andere Medien (nicht Teil dieses Projekts)

### S3 Buckets auf NAS10 (Backup-Ziel)

Bucket-Namenskonvention: `k8s-{env}-{service}` mit `{env}` = dev, test, prod

| Bucket-Schema | Inhalt | Sub-Prefix |
|---------------|--------|------------|
| `k8s-{env}-postgres-wal` | CNPG WAL-Archivierung (Barman) | `cnpg-shared/`, `cnpg-erp/` |
| `k8s-{env}-postgres-backup` | CNPG Logical Backups (pg_dumpall) | `cnpg-shared/`, `cnpg-erp/` |
| `k8s-{env}-mariadb-backup` | MariaDB Galera Physical Backup | `mariadb-galera/` |
| `k8s-{env}-garage-backup` | Garage S3-Inhalte (rclone sync) | pro Bucket |
| `k8s-{env}-odoo-backup` | Odoo Filestore + DB-Dumps | `filestore/`, `_backups/` |
| `k8s-{env}-idoit` | i-doit Upload + src (rclone Tarball) | `upload/upload-YYYY-MM-DD.tar.gz`, `src/src-YYYY-MM-DD.tar.gz` |
| `k8s-{env}-velero` | Velero Backups (K8s-Objekte + PV-Daten) | `backups/`, `kopia/` |
| `k8s-terraform-state` | OpenTofu State (geplant, noch nicht aktiv) | `{env}/terraform.tfstate` |

### In-Cluster S3 Buckets (Garage)

Garage stellt pro Umgebung S3-kompatiblen Storage bereit. Buckets werden nach Bedarf
ueber die Garage WebUI oder API angelegt.

| Umgebung | Garage S3 API | Garage WebUI | Beispiel-Buckets |
|----------|---------------|--------------|------------------|
| DEV | s3-dev-v2.eneg.de | s3-gui-dev-v2.eneg.de | openproject-attachments |
| TEST | s3-test.eneg.de | s3-gui-test.eneg.de | openproject-attachments |
| PROD | s3-prod.eneg.de | s3-gui-prod.eneg.de | openproject-attachments |

### Restore-Verfahren

| Szenario | Verfahren |
|----------|-----------|
| App-Deployment fehlerhaft | ArgoCD: Git Revert -> Auto-Sync |
| Kubernetes Namespace geloescht | Velero Restore |
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
| vCenter API | Service Account | Dedizierter User fuer OpenTofu |
| GitHub | Deploy Key (read-only) | Fuer ArgoCD |
| kubectl | kubeconfig | Management-VM + Windows Laptop + MacBook |
| App-Login | Lokale Admins + Keycloak SSO | 1-3 lokale Admins pro App |

### Network Policies

- Namespace-Isolation via Calico (spaetere Phase)
- Nur explizit erlaubte Kommunikation
- Ingress nur ueber Traefik

### Security Stack (Phase 9)

Mehrschichtiges Sicherheitsmodell ("Aussen-nach-Innen"):

| Schicht | Komponente | Funktion | Modus (Start) |
|---------|------------|----------|----------------|
| Perimeter | CrowdSec + Traefik Bouncer | WAF (OWASP Top 10), IP-Reputation, Brute-Force-Schutz | Detection/Log |
| Policy | Kyverno | Pod Security Standards, Image-Policies, Resource-Quotas | Audit |
| Scan | Trivy Operator | CVE-Scanning aller Container-Images, Config-Audit | Passiv (Reports) |
| Runtime | Falco | Syscall-Monitoring, Anomalie-Erkennung (Shell, Datei, Netzwerk) | Alerting |

**Implementierungsreihenfolge:** Kyverno → Trivy Operator → CrowdSec → Falco
**Phasendokumentation:** `docs/phases/phase-09-security-dev.md`

---

## 12. SSL-Zertifikate

### Let's Encrypt via DNS-01 Challenge (IONOS)

- **Domain:** eneg.de (bei IONOS gehostet)
- **Cert-Manager:** v1.17.2
- **Webhook:** cert-manager-webhook-ionos (fabmade)
- **ClusterIssuer:** letsencrypt-staging, letsencrypt-prod (beide Ready)

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

### IONOS Secret (SOPS-verschluesselt in Git)

Das IONOS API Secret wird via KSOPS durch ArgoCD entschluesselt und
automatisch als Kubernetes Secret deployed. Die verschluesselte Datei
liegt in `kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml`.

### DNS-01 fuer Split-DNS

```yaml
# cert-manager values.yaml
extraArgs:
  - --dns01-recursive-nameservers=8.8.8.8:53,1.1.1.1:53
  - --dns01-recursive-nameservers-only
```

---

## 13. Implementierungsplan

### Phasen-Uebersicht

| Phase | Beschreibung                                                                      | Dauer    | Status                       |
| ----- | --------------------------------------------------------------------------------- | -------- | ---------------------------- |
| 0     | Vorbereitung & Workstation Setup                                                  | 1-2 Tage | ✅ Abgeschlossen (04.02.2026) |
| 1     | Ubuntu-Template & VM-Automatisierung                                              | 2-3 Tage | ✅ Abgeschlossen (06.02.2026) |
| 2     | K3s DEV-Cluster                                                                   | 1-2 Tage | ✅ Abgeschlossen (09.02.2026) |
| 3     | GitOps-Fundament (ArgoCD, SOPS, GitHub)                                           | 2-3 Tage | ✅ Abgeschlossen (10.02.2026) |
| 4     | Kubernetes-Basis (MetalLB, Traefik, Cert-Manager, Longhorn)                       | 2-3 Tage | ✅ Abgeschlossen (18.02.2026) |
| 5     | Datenbank-Cluster (CloudNativePG, MariaDB Galera)                                 | 2-3 Tage | ✅ Abgeschlossen (25.02.2026) |
| 6     | Pilot-Apps (Garage S3, n8n, Keycloak, i-doit, it-info-versand, OpenProject, Odoo) | 3-5 Tage | ✅ Abgeschlossen (26.03.2026) |
| 7     | Monitoring-Stack (inkl. Backup-Health, WAL-Volume, S3-Endpoint Alerting)          | 2-3 Tage | ✅ Abgeschlossen (13.04.2026) |
| 8     | TEST & PROD Rollout                                                               | 2-3 Tage | ✅ Abgeschlossen (30.03.2026) |
| 9     | Security & Haertung (Kyverno, Trivy Operator, CrowdSec, Falco)                   | 3-5 Tage | 🔧 In Arbeit                  |
| 10    | Velero Backup + i-doit rclone Backup                                              | 2-3 Tage | ✅ Abgeschlossen (14.04.2026) |
| 11    | Rolling OS-Update DEV (Ubuntu 24.04 Patches + Reboots)                            | 1-2 Tage | ✅ Abgeschlossen (DEV)        |
| 12    | HA-Improvements (Zot + CoreDNS) — SPOF-Eliminierung aus Phase 11 Vorfall          | 1-2 Tage | ✅ Abgeschlossen (DEV 06.05.2026) — TEST/PROD ausstehend |

---

### Phase 0: Vorbereitung & Workstation Setup ✅

**Abgeschlossen am:** 04.02.2026

**Ergebnisse:**
- Windows Laptop, MacBook/MacMini mit Desktop Commander MCP eingerichtet
- Management-VM (k8s-mgmt-10, 192.168.180.10) erstellt und konfiguriert
- GitHub Repository erstellt (privat, SSH Deploy Key)
- Alle Tools installiert

**Tool-Versionen auf k8s-mgmt-10:**

| Tool | Version |
|------|---------|
| OpenTofu | 1.11.4 |
| Ansible | 2.20.2 (core) |
| Packer | 1.15.0 |
| kubectl | 1.35.0 |
| Helm | 3.20.0 |
| SOPS | 3.11.0 |
| Age | 1.1.1 |
| Git | 2.43.0 |

---

### Phase 1: Ubuntu-Template & VM-Automatisierung ✅

**Abgeschlossen am:** 06.02.2026  
**Aktualisiert am:** 18.02.2026 (Template auf 24.04.4 + Bugfix)

**Ergebnisse:**
- Packer-Template fuer Ubuntu 24.04 LTS (vCenter-A, ESXi 8.x)
- OpenTofu-Modul fuer VM-Deployment (Clone + Guest Customization)
- DEV-Cluster VMs deployed (k8s-dev-21/22/23)

**Kritische Learnings:**
- `util-linux-extra` (nicht `util-linux`) fuer VMware Guest Customization
- SSH Host Keys muessen nach Clone neu generiert werden (Systemd-Service)
- Netplan-Konflikte: Alle Configs im Cleanup loeschen
- VM Hardware Version: ESXi 8.03 = v21 (alle Hosts nun auf ESXi 8.03)

**Template-Update (18.02.2026):**
- Ubuntu 24.04.3 -> 24.04.4
- Build-Host: s2843 -> s3168 (ISO liegt auf S3168_HDD_00_BOOT)
- cloud-init growpart: Automatische Disk-Erweiterung nach Clone
- Timezone: Europe/Berlin gesetzt
- Kernel: Version-Pinning aufgehoben, GA Kernel (linux-image-generic)

**Packer Build (aktuell):**
```bash
cd ~/git/eneg-k8s-infrastructure-v2/packer/ubuntu-24.04
packer build -force \
  -var-file="credentials.auto.pkrvars.hcl" \
  -var-file="variables-vcenter-a.pkrvars.hcl" \
  ubuntu-24.04.pkr.hcl
```

---

### Phase 2: K3s DEV-Cluster ✅

**Abgeschlossen am:** 09.02.2026

**Ergebnisse:**
- Ansible-Struktur (Inventory, Playbooks, Roles)
- K3s v1.35.1+k3s1 HA-Cluster auf 3 Nodes (embedded etcd)
- Version-Pinning statt Channels
- Upgrade-Faehigkeit durch Versions-Check implementiert

**Cluster-Status:**
```
k8s-dev-21   Ready   control-plane,etcd   v1.35.1+k3s1
k8s-dev-22   Ready   control-plane,etcd   v1.35.1+k3s1
k8s-dev-23   Ready   control-plane,etcd   v1.35.1+k3s1
```

**kubeconfig:** `~/git/eneg-k8s-infrastructure-v2/kubeconfig-dev.yaml`

---

### Phase 3: GitOps-Fundament ✅

**Abgeschlossen am:** 10.02.2026

**Ergebnisse:**
- ArgoCD v3.3.0 (Manifest-basiert, server-side apply)
- GitHub SSH Deploy Key (read-only)
- App-of-Apps Pattern (ArgoCD verwaltet sich selbst)
- SOPS + Age fuer Secret-Management (Phase 3b)
- KSOPS v4.4.0 in ArgoCD repo-server integriert
- kubeconfig auf Windows Laptop und MacBook gemergt

**ArgoCD:** https://argocd-dev-v2.eneg.de

---

### Phase 4: Kubernetes-Basis ✅

**Abgeschlossen am:** 18.02.2026

**Ergebnisse:**

| Komponente | Version | URL |
|---|---|---|
| MetalLB | v0.15.3 | - |
| Traefik | v3.6.7 | https://traefik-dev.eneg.de |
| Cert-Manager | v1.17.2 | - |
| IONOS Webhook | latest | - |
| Longhorn | v1.9.2 | https://longhorn-dev-v2.eneg.de |

**Alle ArgoCD Applications:** Synced + Healthy

**Longhorn Storage:**
- 3x ~380 GB pro Node (nach LVM-Erweiterung)
- 2 Replicas, best-effort locality
- Scheduleable: ~855 GB total (mit 2-Replica: ~427 GB nutzbar)

**Kritische Learnings Phase 4:**
- LVM nach vSphere-Clone nicht automatisch erweitert -> cloud-init growpart noetig
- Traefik Chart v39.0.0: Breaking Change bei `redirections` (http:-Verschachtelung)
- Longhorn: preUpgradeChecker.jobEnabled=false fuer ArgoCD-Kompatibilitaet
- Cert-Manager: externe Nameserver fuer DNS-01 in Split-DNS Umgebung

---

### Phase 7: Monitoring-Stack ✅

**Status:** Abgeschlossen (DEV 08.04.2026, TEST + PROD 13.04.2026)

**Vorbereitende Aufgabe: CNPG Barman Cloud Plugin Migration**

Die native (in-tree) Unterstuetzung fuer Barman Cloud Backups ist seit CNPG 1.26.0 deprecated
und wird in CNPG 1.30.0 entfernt. Vor dem naechsten CNPG Operator-Upgrade muss auf das
externe Barman Cloud Plugin (`barman-cloud.cloudnative-pg.io`) migriert werden.

- Anleitung: `docs/guides/cnpg-barman-cloud-plugin-migration.md`
- Betroffene Cluster: cnpg-shared, cnpg-erp
- Migration ist ohne Datenverlust moeglich (bestehende Backups bleiben kompatibel)
- Gleichzeitig Image-Wechsel von `system` auf `standard` (leichteres Image ohne Barman)

**Pflicht-Anforderungen (Lessons Learned aus Vorfall 10.03.2026):**

Am 10.03.2026 fuehrte ein temporaerer NAS10-Ausfall dazu, dass:
1. Alle Backup-CronJobs (CNPG, Garage, Odoo, MariaDB) ueber 3 Tage fehlschlugen
2. CNPG WAL-Archivierung (Barman) stoppte → WAL-Segmente stauten sich auf den 5Gi WAL-Volumes
3. CNPG-ERP Replicas (cnpg-erp-1, cnpg-erp-2) WAL-Volumes zu 100% voll → CrashLoopBackOff
4. Designierter Primary (cnpg-erp-2) konnte nicht starten → Cluster ohne aktiven Primary
5. Manuelles Failover auf cnpg-erp-3 und PVC-Rebuild der Replicas noetig

**Daraus abgeleitete Monitoring-Anforderungen fuer Phase 7:**

| Alert | Metrik/Quelle | Schwellwert Warning | Schwellwert Critical |
|-------|---------------|---------------------|----------------------|
| CNPG WAL-Volume voll | PVC disk usage (kubelet_volume_stats) | >=70% | >=85% |
| CNPG WAL-Archivierung gestoppt | cnpg_pg_stat_archiver / ContinuousArchiving Condition | >5 min ohne Archivierung | >15 min ohne Archivierung |
| CNPG Cluster Not Ready | Cluster Ready Condition = False | - | >5 min |
| CNPG Replica CrashLoop | Pod RestartCount steigend | >3 Restarts in 10 min | >10 Restarts in 10 min |
| CronJob Backup fehlgeschlagen | kube_job_status_failed | 1x fehlgeschlagen | 2x hintereinander fehlgeschlagen |
| S3 Endpoint (NAS10) nicht erreichbar | Blackbox Exporter / Probe | - | Nicht erreichbar >5 min |
| ArgoCD App Degraded | argocd_app_info health_status | - | Degraded >15 min |

**Zusaetzliche Empfehlungen:**
- CNPG enablePodMonitor auf true setzen (bereits in Cluster-Spec vorbereitet)
- Prometheus ServiceMonitor fuer CronJob-Exporter
- Grafana Dashboard fuer Backup-Uebersicht (letzte Laufzeit, Erfolg/Fehler, naechster Lauf)
- Blackbox Exporter Probe fuer nas10.eneg.de:8010 (S3 Endpoint Health)

**Kritische Learnings (Stromabschaltung 15.03.2026):**

- Garage S3 `bootstrap_peers` muessen im Format `node_id@ip:port` konfiguriert sein,
  nicht nur `ip:port`. Ohne Node-ID kann Garage nach einem Neustart mit neuen Pod-IPs
  die Peers nicht wiederfinden. Fix: Node-IDs aus `/var/lib/garage/meta/node_key.pub`
  hardcoded in die ConfigMap eingetragen.
- Cluster-Shutdown-Reihenfolge: Backups triggern → ArgoCD Auto-Sync deaktivieren →
  Apps stoppen → CNPG Hibernation → MariaDB Operator stoppen → MariaDB Galera stoppen →
  Worker-Nodes → Server-Node → Management-Server
- Cluster-Startup-Reihenfolge: Management → Server-Node → Worker-Nodes → CNPG Hibernation
  aufheben → ArgoCD Sync
- ArgoCD CLI auf k8s-mgmt-10 installiert (Login ueber Port-Forward)
- CNPG Hibernation per Annotation: `kubectl annotate cluster <name> -n databases cnpg.io/hibernation=on`

---

### Phase 8: TEST & PROD Rollout ✅

**Status:** Abgeschlossen (30.03.2026)

**Phase 8a: Kustomize-Overlay Refactoring ✅ (16.03.2026)**

Vorbereitung fuer Multi-Environment: Infrastruktur-Manifeste (Phase 2-4 Komponenten)
von DEV-spezifischen base-Manifesten auf generische base + Environment-Overlays umgestellt.

**Refactored auf Overlay-Basis:**

| Komponente | Vorher | Nachher |
|------------|--------|---------|
| MetalLB | IP-Pool direkt in base | base: nur Installation; Overlay: IP-Pool + L2Advertisement |
| Traefik | values.yaml mit DEV-IPs | base: generische values; Overlay: values-override + Certificate |
| Longhorn | Ingress direkt in base | base: values + StorageClass; Overlay: Ingress |
| ArgoCD | CM + Ingress in base | base: generische CM; Overlay: URL-Patch + Ingress |
| Cert-Manager | _(bereits generisch)_ | _(keine Aenderung noetig)_ |

**Erstellte Dateien:**
- `kubernetes/environments/dev/{metallb,traefik,longhorn,argocd}/` — DEV Overlays
- `kubernetes/environments/test/{metallb,traefik,longhorn,argocd}/` — TEST Overlays (VLAN 179)
- `kubernetes/bootstrap/test-argocd-app.yaml` — ArgoCD Bootstrap fuer TEST
- `kubernetes/bootstrap/test-infrastructure-app.yaml` — App-of-Apps fuer TEST

**Verifiziert:** Alle DEV ArgoCD Apps nach Refactoring Synced + Healthy, keine Pod-Restarts,
alle Dashboards (ArgoCD, Traefik, Longhorn) weiterhin erreichbar.

**Entscheidungsdokument:** `docs/decisions/ADR-001-kustomize-overlay-pattern.md`

**Phase 8b: TEST-Cluster VMs und K3s ✅ (16.03.2026)**

TEST-Cluster (VLAN 179) vollstaendig aufgebaut mit allen Infrastruktur-Komponenten.

**Erstellte Konfigurationen:**
- `terraform/environments/test/` — OpenTofu (6 vCPU, 16GB RAM, 512GB Disk)
- `ansible/inventory/test/` — K3s Inventory + group_vars
- `kubernetes/environments/test/infrastructure/` — 9 ArgoCD App-Definitionen

**Infrastruktur-Status (11 ArgoCD Apps Synced + Healthy):**

| Komponente | Version | URL |
|---|---|---|
| K3s | v1.35.1+k3s1 | 3 Nodes (192.168.179.21-23) |
| ArgoCD | v3.3.0 | https://argocd-test.eneg.de |
| MetalLB | v0.15.3 | Pool: 192.168.179.151-199 |
| Traefik | v3.6.7 | https://traefik-test.eneg.de (LB: .100) |
| Cert-Manager | v1.17.2 | ClusterIssuers Ready |
| Longhorn | v1.9.2 | https://longhorn-test.eneg.de |

**Kritische Learnings:**
- SSH-Keys muessen vor Ansible via `ssh-copy-id` verteilt werden (Template hat keinen Key)
- Ansible `group_vars/all.yml` pro Environment noetig (K3s-Config, SSH-Keys)
- SOPS Secret-Name: `sops-age` (nicht `age-key`)
- ArgoCD v3.3.0: ApplicationSet CRD Annotation-Limit, Manifest ggf. zweimal anwenden
- ArgoCD hinter Traefik: `server.insecure: "true"` in argocd-cmd-params-cm noetig
- ArgoCD App-of-Apps: Permanentes OutOfSync durch `directory: recurse: false` Default
  (Kubernetes API fuegt dieses Feld automatisch hinzu, ArgoCD erkennt den Diff).
  Fix: `resource.customizations.ignoreDifferences` in argocd-cm ConfigMap fuer
  `argoproj.io/Application` mit jqPathExpression `.spec.source.directory`
  (Ref: https://github.com/argoproj/argo-cd/issues/4501)

**Abschlussdokument:** `docs/phases/phase-08b-test-cluster-handoff.md`

**Phase 8b-continued: TEST-Umgebung Apps ✅ ABGESCHLOSSEN (26.03.2026)**

Alle 6 Pilot-Apps + Datenbank-Operatoren/Cluster von DEV-spezifisch auf Environment-Overlays
umgestellt und erfolgreich nach TEST deployed.

**Refactored auf Overlay-Basis (Schritt 1-6, vorherige Session):**
- CNPG Operator, MariaDB Operator + CRDs (generische ArgoCD Apps fuer TEST)
- CNPG/MariaDB Secrets (SOPS-verschluesselt fuer TEST)
- CNPG Cluster + Backup CronJobs (environment-spezifische S3-Buckets)
- MariaDB Galera Cluster + Physical Backup
- Garage S3 (environment-spezifische Node-IDs, Ingress, Backup-Buckets)

**Refactored auf Overlay-Basis (Schritt 7, diese Session):**
- n8n: DEV + TEST Manifeste, TEST Secrets
- Keycloak: DEV + TEST Manifeste, TEST Secrets
- i-doit: DEV + TEST Manifeste, TEST Secrets (inkl. ghcr-pull-secret)
- it-info-versand: DEV + TEST Manifeste, TEST Secrets (inkl. ghcr-pull-secret)
- OpenProject: DEV + TEST Manifeste, TEST Secrets (Web, Worker, Seeder, Memcached, Hocuspocus)
- Odoo: DEV + TEST Manifeste, TEST Secrets (inkl. Backup CronJob + Backup Secrets)

**ArgoCD App-Definitionen:**
- 7 DEV App-Pfade aktualisiert: `base/apps/*` → `environments/dev/apps/*`
- DEV Secret-Apps bleiben auf `base/apps/*/secrets/` (keine Re-Encryption noetig)
- 14 TEST ArgoCD App-Definitionen neu erstellt
- `.sops.yaml` Regel 1c fuer `environments/*/apps/*/secrets/`

**TEST-Cluster Gesamtstatus:** Alle Apps Synced + Healthy auf ArgoCD TEST
- https://argocd-test.eneg.de — Alle Apps gruen
- https://openproject-test.eneg.de — Erreichbar, LDAP-Auth (AD), SMTP konfiguriert, S3-Attachments (Garage)
- https://odoo-test.eneg.de — Erreichbar
- https://idoit-test.eneg.de — Erreichbar
- https://it-info-versand-test.eneg.de — Erreichbar, Keycloak OIDC Login
- https://n8n-test.eneg.de — Erreichbar
- https://keycloak-test.eneg.de — Erreichbar, Realm `eNeG`, AD/LDAP Federation
- https://s3-gui-test.eneg.de — Erreichbar, Garage WebUI

**Post-Deployment Konfiguration (26.03.2026):**
- Garage TEST: WebUI-Passwort neu gesetzt, API Key + Bucket fuer OpenProject erstellt
- Keycloak TEST: Realm `eNeG`, AD/LDAP Federation, Group Mapper, OIDC-Clients
- OpenProject TEST: S3-Credentials, SMTP (smtpout1.eneg.customers.hosting.zone:587), LDAP-Auth
- it-info-versand TEST: OIDC-Client-Secret, Keycloak Group Membership Mapper
- Bugfix: Keycloak Realm-Name `eneg` -> `eNeG` in allen OpenProject-Deployments (case-sensitive)

**Fixes waehrend Deployment:**
- ghcr-pull-secret: `auth`-Feld darf nur reinen Base64-String enthalten (kein Prefix)
- OpenProject DB-Passwort: Sonderzeichen (`/`, `%`) in DATABASE_URL vermeiden → Hex-only Passwoerter
- OpenProject: DB-Migrationen muessen beim ersten Start manuell angestossen werden (`rails db:migrate`)
- Odoo: DB-Initialisierung beim ersten Start manuell anstossen (`odoo -i base --stop-after-init --no-http`)
- Keycloak OIDC: Group Membership Protocol Mapper noetig fuer gruppenbasierte App-Autorisierung

**Phase 8c: PROD Rollout ✅ ABGESCHLOSSEN (30.03.2026)**

Rollout des PROD-Clusters analog zu TEST, inklusive Post-Deployment-Konfiguration.

**PROD-Cluster:**
- 3 Nodes (k8s-prod-21/22/23), VLAN 178, K3s v1.35.1+k3s1
- 8 vCPU, 24 GB RAM, 768 GB Disk pro Node
- 39 ArgoCD Apps Synced + Healthy

**Post-Deployment-Konfiguration (30.03.2026):**
- Garage: API Keys + Buckets erstellt, Backup-Credentials (Secret #19) verschluesselt
- Keycloak: Realm `eNeG`, AD/LDAP Federation, OIDC-Client `it-info-versand`
- OpenProject: LDAP-Auth, S3-Attachments, SMTP, Hocuspocus Echtzeit-Kollaboration
- Odoo: Admin-Passwort konfiguriert
- SSL/DNS: Alle 10 PROD-URLs erreichbar
- Backups: Alle 5 Backup-Jobs (CNPG Physical+Logical, MariaDB, Garage, Odoo) verifiziert

**Kritische Learnings:**
- LVM nach vSphere-Clone manuell erweitern (growpart + pvresize + lvextend + resize2fs)
- GHCR Pull-Secrets nie per heredoc/Script, immer per Template mit `|` Block-Scalar
- Garage Node-IDs aus Rohbytes auslesen (`xxd -p | tr -d '\n'`)
- Hocuspocus muss in OpenProject Administration → Documents manuell konfiguriert werden
- OpenProject-Pods brauchen Restart nach Secret-Updates

**Abschlussdokument:** `docs/phases/phase-08c-prod-deployment-handoff.md`

**Headlamp Kubernetes Dashboard (30.03.2026):**

Headlamp als Web-basiertes Kubernetes Dashboard auf allen 3 Clustern deployed.

| Umgebung | URL | Helm Chart |
|----------|-----|------------|
| DEV | https://k8s-dashboard-dev-v2.eneg.de | v0.41.0 |
| TEST | https://k8s-dashboard-test.eneg.de | v0.41.0 |
| PROD | https://k8s-dashboard-prod.eneg.de | v0.41.0 |

- Deployment: Helm via ArgoCD (Multi-Source: Helm Chart + Git Values)
- Auth: ServiceAccount Token (OIDC/Keycloak optional spaeter)
- Ingress: Traefik IngressRoute mit Let's Encrypt TLS
- DNS: Split-DNS (nur lokal konfiguriert)

---

### Phase 9: Security & Haertung 🔧

**Status:** In Arbeit — Kyverno + Trivy Operator DEV abgeschlossen (Stand 20.04.2026); CrowdSec + Falco ausstehend

**Beginn:** 14.04.2026

**Ziel:** Mehrschichtiger Security-Stack fuer alle drei Umgebungen.
Vorbereitung fuer geplante Internet-Freischaltung einzelner Apps.

**Komponenten und Versionen:**

| Komponente | Version | Funktion | DEV-Status |
|------------|---------|----------|------------|
| Kyverno | v1.17.1 (Helm 3.7.1) | Policy Engine (Pod Security Standards, Image Policies) | ✅ Deployed |
| Kyverno Policies | Helm 3.7.1 | Kubernetes Pod Security Standards (Baseline, Audit-Modus) | ✅ Deployed |
| Trivy Operator | v0.30.1 (Helm 0.32.1) | Vulnerability Scanner (CVEs, Fehlkonfigurationen) | ✅ Deployed, ClientServer-Mode (20.04.2026) |
| Trivy Server (intern) | v0.69.3 (trivy-server-0 StatefulSet, PVC 5Gi) | Zentraler DB-Cache fuer alle Scan-Pods | ✅ Aktiv seit 20.04.2026 |
| CrowdSec Engine | Helm (latest stable) | WAF + Brute-Force-Schutz + IP-Reputation | ⏳ Ausstehend |
| CrowdSec Bouncer | Plugin v1.3.3 | Traefik-Middleware (Ban/Captcha) | ⏳ Ausstehend |
| Falco | v0.42.x (Helm 8.0.1) | Runtime Security (eBPF Syscall-Monitoring) | ⏳ Ausstehend |

**Implementierungsreihenfolge:** Kyverno → Trivy Operator → **Phase 9a (Container Registries Zot)** → CrowdSec → Falco

**Neue Namespaces:** `kyverno`, `trivy-system`, `registry`, `crowdsec`, `falco`
**Neue ArgoCD Apps:** 8 pro Environment (2 bereits in DEV aktiv; Registry kommt DEV+PROD, nicht TEST)
**Geschaetzter Aufwand:** DEV ~10-15h (+ Phase 9a: ~1-2 Tage), TEST/PROD je ~2-3h

**Wichtige Chart-Learnings (Trivy Operator, 20.04.2026):**
- `operator.builtInTrivyServer: true` (nicht `trivy.builtInTrivyServer`) aktiviert
  ClientServer-Mode + trivy-server-0 StatefulSet
- `resources:` liegt im Aqua-Chart auf Root-Ebene (nicht unter `operator.*`)
- Uebergeordnetes Prinzip: Helm-Value-Overrides IMMER gegen Chart-Struktur pruefen,
  nicht aus Intuition benachbarte Keys benutzen
- DockerHub Rate-Limit bei Scans von `docker.io/*`-Images → wird in **Phase 9a** vollstaendig geloest durch eigene Zot-Registry mit Proxy-Cache

**Phasendokumentation:**
- `docs/phases/phase-09-security-dev.md` (Kyverno, Trivy, CrowdSec, Falco)
- `docs/phases/phase-09a-security-registries.md` (Zot Registries DEV + PROD)

---

### Phase 9a: Container Registry Infrastruktur (Zot) 🔧

**Status:** **Etappe A VOLLSTAENDIG ABGESCHLOSSEN (DEV + TEST + PROD)** am 21.04.2026 — Etappe B (PROD-Zot + Cutover) offen

**Ziel:** Eigene OCI-Container-Registry mit Proxy-Cache fuer Upstream-Registries
und eigenem Image-Hosting. Einschub in Phase 9 zwischen Trivy Operator und CrowdSec,
weil CrowdSec-/Falco-Rollout und generelle Image-Pulls sonst durch DockerHub
Rate-Limit gebremst wuerden.

**Topologie (Variante 2):**

| Instanz | Cluster | DNS | S3 Bucket | Rolle |
|---------|---------|-----|-----------|-------|
| DEV-Zot | k8s-dev | registry-dev.eneg.de | nas10/k8s-dev-registry | Proxy-Cache + eigene Images; TEST pullt hier mit |
| PROD-Zot | k8s-prod | registry-prod.eneg.de | nas10/k8s-prod-registry | Empfaengt Sync von DEV; PROD-Cluster pullt ausschliesslich hier, ohne Internet-Fallback |

**Software:** Zot v2.1.15 (Helm Chart 0.1.104, project-zot/zot, CNCF Sandbox)

**Mirror-Scope containerd:** `docker.io`, `quay.io`, `ghcr.io`, `registry.k8s.io` —
in DEV + TEST + PROD aktuell mit Internet-Fallback (built-in default endpoint fallback seit K3s v1.26.13+k3s1); PROD ohne Fallback kommt mit Etappe B.

**Etappe A Abschluss (21.04.2026):**
- DEV-Zot deployed, HTTPS erreichbar, NAS10 S3 befuellt, `eneg/*`-Images gesynct
- containerd registries.yaml auf allen 9 Nodes (DEV + TEST + PROD) via Ansible Playbook `07-k3s-registries-mirror.yml`
- Playbook 07 env-agnostisch (Variable `kubectl_context` aus Inventory-Dir)
- End-to-End-Pulls verifiziert: hello-world/nginx (DEV), alpine (TEST), busybox (PROD)
- Multi-Arch-Loesung: `preserveDigest: true` + `http.compat: ["docker2s2"]`
- DockerHub-Auth via PAT (authenticated Rate-Limit 200/6h fuer Sync)
- sysctl inotify-Limits ausgerollt + Packer-Template gepatcht

**Offene Punkte (nach Etappe A):**
- Trivy Operator Rate-Limit-Fix: Trivy umgeht containerd-Mirror (Remote-API direkt an `index.docker.io`). Fix via `TRIVY_REGISTRY_MIRROR=docker.io=registry-dev.eneg.de`. DEV-lokal, nicht blockierend.
- OnDemand-First-Pull-Latency bei grossen Multi-Arch-Images (z.B. alpine ~6m34s): relevant fuer Etappe B Warm-up, damit PROD-Cutover ohne Fallback reibungslos laeuft.

**Etappe B (offen):**
- Eigene PROD-Zot-Instanz in PROD-Cluster
- Sync DEV→PROD mit Denylist-Filter fuer mutable Tags (latest, main, dev, rc*, alpha*, beta*)
- containerd-Cutover auf `registry-prod.eneg.de` OHNE Fallback
- Voraussetzungen: Bucket + DNS bereits vorhanden (Stand 21.04.2026)

**Neuer Namespace:** `registry` (DEV aktiv, PROD mit Etappe B)
**Neue ArgoCD Apps:** `registry`, `registry-secrets` in DEV aktiv; gleiches in PROD nach Etappe B
**Geschaetzter Aufwand Rest:** ~0,5-1 Tag fuer Etappe B

**Phasendokumentation:** `docs/phases/phase-09a-security-registries.md` (Sections 12.13–12.15 enthalten TEST+PROD-Abschluss-Learnings)
**Folge-Anweisung Etappe B:** `docs/guides/phase-09a-test-prod-handoff.md`

---

### Phase 10: Velero Backup + i-doit rclone Backup ✅

**Status:** Abgeschlossen (14.04.2026, DEV + TEST + PROD)

**Velero v1.17.1 (Helm Chart 11.3.2):**
- Taegliches Backup aller Kubernetes-Ressourcen + PV-Daten (kopia fs-backup)
- Schedule: 04:30 Europe/Berlin, TTL 14 Tage
- Backup-Ziel: NAS10 S3 (`k8s-{env}-velero`)
- AWS Plugin v1.13.0 (S3-kompatibel)
- node-agent DaemonSet (1 Pod pro Node)
- 2 ArgoCD Apps: `velero`, `velero-secrets`

**i-doit rclone Backup:**
- Taegliches Backup von Upload-Verzeichnis + src (config.inc.php)
- Schedule: 05:30 Europe/Berlin, 32 Tage Retention
- Backup-Ziel: NAS10 S3 (`k8s-{env}-idoit`)
- rclone 1.73.1 (gleiche Version wie Odoo/Garage Backup)
- 2 ArgoCD Apps: `idoit-backup`, `idoit-backup-secrets`

**Verifizierung DEV:**
- Velero Full Backup (alle Namespaces + PVs): Completed
- i-doit rclone Backup (Upload + src): Completed, 23.7 MiB

**Phasendokumentation:** `docs/phases/phase-10-backup-dev.md`

---

## 14. Dokumentation

### Speicherort

- **Primaer:** `/docs` im Git Repository
- **Format:** Markdown (.md)
- **Ergaenzend:** README.md in jedem Unterverzeichnis

### Dokumentationsstruktur

```
docs/
├── phases/                        # Phasen-Abschlussdokumente
│   ├── README.md                  # Phasenuebersicht (aktueller Stand)
│   ├── phase-0-vorbereitung.md
│   ├── phase-1-vm-automatisierung.md
│   ├── phase-02-abschluss.md
│   ├── phase-03-abschluss.md
│   ├── phase-03b-abschluss.md    # SOPS + KSOPS
│   ├── phase-04-abschluss.md
│   ├── phase-05-abschluss.md
│   ├── phase-05-datenbanken.md
│   ├── phase-06-pilot-apps.md
│   ├── phase-08b-test-cluster-handoff.md
│   ├── phase-08b-continued-handoff.md
│   ├── phase-08c-zwischenstand-handoff.md
│   ├── phase-08c-prod-handoff.md
│   ├── phase-08c-prod-deployment-handoff.md
│   ├── phase-08e-branch-migration-handoff.md
│   ├── phase-09-security-dev.md
│   ├── phase-10-backup-dev.md
│   └── infrastructure-migration-2026-02-16.md
├── architecture/
├── guides/
│   ├── argocd-cli-setup-mgmt10.md
│   ├── cnpg-barman-cloud-plugin-migration.md
│   ├── idoit-post-deployment-test-prod.md
│   ├── timezone-configuration.md
│   └── phase-6.*-chat-anweisung-*.md  # Chat-Anweisungen pro App
├── runbooks/
├── decisions/
│   ├── ADR-001-kustomize-overlay-pattern.md
│   └── ADR-002-branch-per-environment.md
├── SOPS-SECRET-MANAGEMENT.md
└── SSH-KEY-MANAGEMENT.md
```

### Dokumentationsprinzipien

1. **Aktuell halten:** Dokumentation direkt nach erfolgreicher Implementierung
2. **Versioniert:** Alle Aenderungen via Git nachvollziehbar
3. **Praktisch:** Fokus auf Runbooks und konkrete Anleitungen
4. **Entscheidungen dokumentieren:** Key Learnings in Phasen-Abschluessen

---

## Anhang A: Zugaenge und Credentials

| System | Zugangsdaten |
|--------|--------------|
| vCenter-A | In 1Password |
| IONOS API | In 1Password (via SOPS im Cluster) |
| GitHub | eneg-k8s-infrastructure-v2 |
| NAS (nas10.eneg.de) | In 1Password |
| ArgoCD | In 1Password |

---

## Aenderungshistorie

| Datum      | Version | Aenderung                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 04.02.2026 | 1.0     | Initiale Version                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 04.02.2026 | 1.1     | Phase 0 abgeschlossen                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| 09.02.2026 | 1.2     | Phase 2 abgeschlossen (K3s)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| 10.02.2026 | 1.3     | Phase 3 abgeschlossen (ArgoCD + SOPS)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| 18.02.2026 | 2.0     | Phase 4 abgeschlossen (MetalLB, Traefik, Cert-Manager, Longhorn), Template-Bugfix, komplette Neuformatierung (Encoding-Bereinigung)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| 25.02.2026 | 2.1     | Phase 5 abgeschlossen, Phase 6 gestartet, Naming Convention um Zwei-Secret-Pattern erweitert                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| 25.02.2026 | 2.2     | n8n deployed (Phase 6.1), Garage S3 in Tech-Stack und Backup-Strategie ergaenzt                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 26.02.2026 | 2.3     | Garage S3 v2.2.0 deployed (Phase 6.1b), Phase 5+6 Fortschritte im Implementierungsplan ergaenzt                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 04.03.2026 | 2.4     | Keycloak 26.5.4 deployed (Phase 6.4), AD-Anbindung, OpenProject LDAP, SSO-Erkenntnisse dokumentiert                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| 10.03.2026 | 2.5     | i-doit Open 37 deployed (Phase 6.5), eigenes Docker Image, MariaDB Operator CRDs, ghcr.io Registry                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 15.03.2026 | 2.6     | Garage bootstrap_peers Fix (Node-IDs hinzugefuegt), Barman Cloud Plugin Migrations-Anleitung erstellt, ArgoCD CLI auf k8s-mgmt-10 installiert, Cluster Shutdown/Startup Prozedur durchgefuehrt und dokumentiert                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 16.03.2026 | 2.7     | Phase 8a: Kustomize-Overlay Refactoring fuer Multi-Environment (MetalLB, Traefik, Longhorn, ArgoCD), TEST-Overlays vorbereitet, Repository-Struktur und GitOps-Workflow aktualisiert, ADR-001 erstellt                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| 16.03.2026 | 2.8     | Phase 8b: TEST-Cluster aufgebaut (OpenTofu, Ansible, K3s, ArgoCD Bootstrap), 11 Infrastruktur-Apps Synced+Healthy, Dashboards erreichbar, Learnings dokumentiert                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 26.03.2026 | 2.9     | Phase 8b-continued: Alle 6 Pilot-Apps nach TEST deployed (Environment-Overlay Refactoring), DB-Operatoren/Cluster/Garage refactored, 14 TEST ArgoCD Apps, Fixes (ghcr auth, DB-Passwort Sonderzeichen, manuelle DB-Migration/Init)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 26.03.2026 | 2.10    | Post-Deployment TEST: Garage S3 Key+Bucket fuer OpenProject, Keycloak AD/LDAP+OIDC (Realm eNeG), OpenProject SMTP+LDAP, it-info-versand OIDC+Group Mapper, Fix Realm-Name eneg->eNeG                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 30.03.2026 | 2.11    | Phase 8c ABGESCHLOSSEN: PROD-Cluster komplett deployed + Post-Deployment-Konfiguration (Garage Keys, Keycloak OIDC, OpenProject LDAP/S3/SMTP/Hocuspocus, Odoo, SSL/DNS, Backups verifiziert)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| 30.03.2026 | 2.12    | Headlamp Kubernetes Dashboard (Helm v0.41.0) auf DEV, TEST, PROD deployed, ServiceAccount Token Auth, Split-DNS                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 31.03.2026 | 2.13    | Dokumentation gegen Repository abgeglichen: Phase 6+8 Status auf Abgeschlossen, DNS PROD Wildcard durch Einzel-Eintraege ersetzt, Pilot-Apps-Tabelle auf 6 Apps erweitert (Keycloak, i-doit, it-info-versand ergaenzt), Repository-Struktur aktualisiert (docker/, scripts/, prod-Overlays, Ansible Playbooks), Namespace-Struktur vervollstaendigt, Dokumentationsstruktur aktualisiert, cnpg-barman-cloud-plugin-migration.md Guide erstellt, CNPG-Spec auf cnpg-shared + cnpg-erp angepasst, Kustomize-Overlay-Tabellen um DB- und App-Layer erweitert, S3-Bucket-Tabelle mit tatsaechlichen Namenskonventionen aktualisiert, Backup-Uebersicht korrigiert, DEV App-Secrets und Infra-Secrets von base/ nach environments/dev/ migriert (11 ArgoCD Apps angepasst), ArgoCD App-of-Apps OutOfSync Fix via resource.customizations.ignoreDifferences in argocd-cm (directory.recurse Default, Ref: #4501), ADR-002 Branch-per-Environment Promotion-Strategie, Phase 8e Migrationsplan erstellt |
| 13.04.2026 | 2.14    | Phase 7 Monitoring-Stack ABGESCHLOSSEN (DEV+TEST+PROD): kube-prometheus-stack 83.0.0, Thanos 17.3.1, Loki 6.55.0, Alloy 1.7.0, Blackbox Exporter 11.9.1, prometheus-msteams v1.5.4. 9 ArgoCD Apps + 23 Pods pro Env, Grafana Dashboards (7x), Custom PrometheusRules (4x), AlertManager E-Mail+Teams, Watchdog 07:00 MESZ. Layer 4 Monitoring-Tabelle aktualisiert. Learning #20: CNPG enablePodMonitor SSA-Workaround (eigenstaendige PodMonitor-CRDs statt Operator-Funktion fuer TEST/PROD)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| 14.04.2026 | 2.15    | Phase 10 Velero Backup + i-doit rclone Backup ABGESCHLOSSEN (DEV+TEST+PROD): Velero v1.17.1 (Helm 11.3.2) mit AWS Plugin v1.13.0, node-agent DaemonSet (kopia fs-backup) auf NAS10 S3 (k8s-{env}-velero). i-doit Upload+src rclone Backup auf NAS10 S3 (k8s-{env}-idoit). 4 neue ArgoCD Apps pro Env. Backup-Zeitplaene gestaffelt: PROD 00:01-02:00, TEST 02:15-04:15, DEV 04:30-06:30 (keine NAS10-Ueberlappung). MariaDB PhysicalBackup schedule.cron ist immutable (Learning #6). Layer 6 Velero auf Installiert, Namespace velero hinzugefuegt |
| 14.04.2026 | 2.16    | Phase 9 Security & Haertung GESTARTET: Toolauswahl und Reihenfolge festgelegt (Kyverno v1.17.1 → Trivy Operator v0.30.1 → CrowdSec + Traefik Bouncer v1.3.3 → Falco v0.42.x). Layer 5 Security-Tabelle mit konkreten Versionen befuellt. 4 neue Namespaces (kyverno, trivy-system, crowdsec, falco), 6 neue ArgoCD Apps pro Env geplant. Phasendokumentation phase-09-security-dev.md erstellt. CrowdSec als WAF/Fail2Ban-Ersatz fuer geplante Internet-Freischaltung |
| 20.04.2026 | 2.16    | Nachbesserungen (Stand v2.16 bleibt): **Trivy Operator Chart-Pfad-Fixes** — `builtInTrivyServer: true` nach `operator.*` verschoben (war unter `trivy.*`, wurde ignoriert); `resources:` auf Root-Ebene verschoben (war unter `operator.resources`). Folge: trivy-server-0 StatefulSet (PVC 5Gi) aktiv, Cache-Lock-Fehler bei parallelen Scans behoben, Memory-Limits 512Mi/1Gi wirken jetzt. Phase 9 Status: Kyverno + Trivy Operator DEV abgeschlossen. Learnings #6/#7/#8 in phase-09-security-dev.md ergaenzt (DockerHub Rate-Limit als Follow-up). **DEV-Monitoring-Tuning:** Prometheus retention 7d/12GB in DEV values-override, CronJobOverdue DEV-SMP-Patch mit 36h Threshold + idoit im Selector (`kube_cronjob_status_last_successful_time` statt next_schedule_time). Phase 7 Learning #21 ergaenzt |
| 20.04.2026 | 2.16    | **Phase 9a Container Registry Infrastruktur (Zot) vorbereitet:** Zwischenschritt in Phase 9 zwischen Trivy Operator und CrowdSec. Loest DockerHub Rate-Limit (Phase 9 Learning #8) und konsolidiert eigene Images. Topologie Variante 2: DEV-Zot (`registry-dev.eneg.de`, Proxy-Cache + Hosting, NAS10 `k8s-dev-registry`) + PROD-Zot (`registry-prod.eneg.de`, empfaengt Sync von DEV, NAS10 `k8s-prod-registry`, ohne Internet-Fallback). TEST pullt von DEV. Mirror-Scope containerd: docker.io, quay.io, ghcr.io, registry.k8s.io. Auth: anonymous pull, htpasswd push (User `eneg`). Eigene Images `dhenkeeneg/*` via Zot sync-Extension gespiegelt (CI bleibt auf ghcr.io). Sync DEV→PROD mit Denylist-Filter fuer mutable Tags (latest, main, dev, rc*, alpha*, beta*). Abstimmung komplett. Phasendokumentation `docs/phases/phase-09a-security-registries.md` erstellt. Umsetzung in separatem Chat |
| 21.04.2026 | 2.17    | **Phase 9a Etappe A (DEV) ABGESCHLOSSEN:** Zot v2.1.15 (Helm Chart 0.1.104) deployed auf DEV-Cluster. NAS10 S3-Backend `k8s-dev-registry`, PVC 10Gi Longhorn, cert-manager ClusterIssuer `letsencrypt-prod`, IngressRoute in `traefik` Namespace mit Cross-Namespace-Service-Ref. Repository-Struktur: `kubernetes/base/registry/`, `environments/dev/registry/` + separater `registry-secrets/` Layer (sync-wave 3→4). containerd registries.yaml via Ansible-Playbook `07-k3s-registries-mirror.yml` rolling auf allen 3 DEV-Nodes ausgerollt (default endpoint fallback). End-to-End verifiziert: `crictl pull docker.io/library/hello-world:latest` und `nginx:stable-alpine` erfolgreich via Zot Multi-Arch Proxy-Cache. **Kritisches Learning (in `docs/phases/phase-09a-security-registries.md` Section 12 dokumentiert):** Multi-Arch + S3 + OnDemand-Sync erfordert zwingend die Kombination `preserveDigest: true` (Byte-exakte Manifest-Erhaltung) + `http.compat: ["docker2s2"]` im Zot-Config — ohne docker2s2 crasht der Pod mit `can not use PreserveDigest option without enabling http.Compat`; ohne preserveDigest wird Multi-Arch-Index nicht im Catalog registriert (`invalid manifest content` beim 2. Pull). DockerHub PAT integriert in `ghcr-sync-credentials.enc.yaml` (JSON mit mehreren Upstream-Registries: ghcr.io + registry-1.docker.io) — Rate-Limit von 60/6h anon auf 200/6h authenticated angehoben. sysctl-Tuning (`fs.inotify.max_user_watches=524288`) via Ansible-Playbook `06-sysctl-inotify-limits.yml` auf allen Nodes + Packer-Template `user-data.pkrtpl.hcl` gepatcht. **Ausstehend:** containerd-Mirror-Rollout auf TEST + PROD (Ansible 07 erneut mit jeweiligem Inventory), Eigene-Images-Sync `dhenkeeneg/*` → `eneg/*` verifizieren, Trivy `TOOMANYREQUESTS`-Aufloesung verifizieren, danach Etappe B (PROD-Zot mit Sync DEV→PROD, PROD ohne Internet-Fallback). Folge-Anweisung: `docs/guides/phase-09a-test-prod-handoff.md` |
| 21.04.2026 | 2.18    | **Phase 9a Etappe A VOLLSTAENDIG ABGESCHLOSSEN (DEV + TEST + PROD):** Containerd-Mirror auf allen 9 Nodes via Ansible-Playbook `07-k3s-registries-mirror.yml` rolling ausgerollt. **TEST-Rollout** (k8s-test-21/22/23): PLAY RECAP `ok=15-16, changed=2, failed=0` pro Node, hosts.toml in `certs.d/docker.io/` mit Mirror `https://registry-dev.eneg.de/v2` bestaetigt, `library/alpine` via Test-Pull in Catalog aufgenommen. **PROD-Rollout** (k8s-prod-21/22/23): analog, `library/busybox` Test-Pull in 15,5 s direkt durch (Multi-Arch mit nur 4-5 Varianten → OnDemand-Sync innerhalb containerd-Timeout), alle 40+ ArgoCD-Apps durchgaengig Synced+Healthy. **Playbook 07 env-agnostisch gemacht:** Variable `kubectl_context: "k8s-{{ inventory_dir | basename }}"` aus vars-Section leitet aus Inventory-Pfad den richtigen kubectl-Context fuer den Approval-Prompt ab. **Learning OnDemand-First-Pull-Latency (Section 12.13.1 der Phase-Doku):** Beim initialen Test-Pull `docker.io/library/alpine:3` (~15-20 Multi-Arch-Varianten) via Mirror kam `context canceled` zurueck, weil Zot's synchroner OnDemand-Sync 6m34s brauchte (regclient kopiert alle Platform-Layer + Configs nach NAS10-S3) und containerd's HTTP-Timeout (~30-60 s) frueher zuschlug. Zweiter Pull: 6 s (Cache-Hit). In Etappe A unkritisch wegen Fallback; fuer Etappe B PROD ohne Fallback: Warm-up aller produktiven Images ins PROD-Zot vor Cutover erforderlich. **Trivy Rate-Limit als offener Punkt identifiziert:** Trivy Operator umgeht containerd-Mirror (Remote-API-Pull direkt an `index.docker.io`), `TOOMANYREQUESTS` fuer `docker.io`-Images bleibt in DEV bestehen (162 VulnerabilityReports existieren, nicht-docker.io Images werden weiterhin gescannt). DEV-lokal, nicht blockierend fuer Etappe B. Fix-Strategie: `TRIVY_REGISTRY_MIRROR=docker.io=registry-dev.eneg.de` als additionalEnvVar. Section 12.13–12.15 in `docs/phases/phase-09a-security-registries.md` ergaenzt; Handoff `docs/guides/phase-09a-test-prod-handoff.md` aktualisiert (Schritte 1+2 als erledigt markiert, Fokus auf Etappe B). NAS10-Bucket `k8s-prod-registry` + DNS `registry-prod.eneg.de` bereits vorhanden als Etappe-B-Vorbereitung. |
| 22.04.2026 | 2.19    | **Phase 9a Etappe A Nachbesserung: Trivy Operator Mirror Fix (DEV) ABGESCHLOSSEN.** Der offene Trivy-Rate-Limit-Punkt aus v2.18 ist aufgeloest. Trivy-Scan-Pods nutzen jetzt den DEV-Zot als Upstream-Mirror fuer `index.docker.io` via `trivy.configFile` in den Helm-Values. **Learnings (vollstaendig in `docs/phases/phase-09a-security-registries.md` Section 12.16):** (1) Erster Versuch mit `trivy.registry.mirror.docker.io` in Helm-Values **wirkungslos** — Chart schreibt in ConfigMap, aber Trivy CLI liest Mirror-Settings nicht aus env vars (woertlich in Chart-Kommentar: "options available only in the config file"). (2) Zweiter Versuch mit `trivy.configFile: \|` als Multi-Line-String scheiterte an Double-Wrap-Bug: Chart-Template wendet `toYaml` auf String an, der wiederum mit `\|` gewrappt wird → ConfigMap-Wert beginnt mit `\|` als erster Zeile, kein valides YAML. (3) Erfolgreicher Fix: `trivy.configFile:` als **YAML-Object** (nicht String) wie im upstream Chart-values.yaml Kommentar-Beispiel. **Wichtiges Begleit-Learning:** Jede Aenderung an `trivy-operator-trivy-config` ConfigMap triggert automatisch Vollrescan aller VulnerabilityReports (Config-Hash-Vergleich). Vor Aenderungen daher `scanJobsConcurrentLimit` temporaer auf 1 reduzieren, um Rescan-Flut unter DockerHub-Rate-Limit zu halten. **Verifizierung:** Zot-Logs bestaetigen Incoming `User-Agent: trivy/0.69.3` mit `Host: registry-dev.eneg.de` (nicht mehr docker.io), OnDemand-Sync gegen `registry-1.docker.io` via regclient; alle bisher scheiternden docker.io-Workloads (velero, openproject, argocd-redis) nach Fix erfolgreich gescannt. `scanJobsConcurrentLimit` nach abgeschlossenem Rescan-Durchlauf zurueck auf 2 (Standard-Wert). Scope: nur DEV — TEST/PROD haben aktuell keinen Trivy-Operator. Bei spaeterer Trivy-Ausrollung in TEST/PROD dieselbe configFile-Struktur mit env-spezifischen Zot-Endpunkten (`registry-test.eneg.de`, `registry-prod.eneg.de`) uebernehmen. **Status:** Phase 9a Etappe A Checkliste nun vollstaendig gruen (inkl. Trivy). Naechster Schritt: Phase 9a Etappe B (PROD-Zot, Sync DEV→PROD, Cutover mit Warm-up). |
| 06.05.2026 | 2.20    | **Phase 11 + Phase 12 in Implementierungsplan-Tabelle ergaenzt.** Phase 11 (Rolling OS-Update DEV) abgeschlossen — Vorfall mit kaskadierendem Cluster-Ausfall durch zwei verkettete SPOFs identifiziert (Zot Single-Replica, CoreDNS Single-Replica). **Phase 12 HA-Improvements DEV ABGESCHLOSSEN:** **Plan A — Zot HA:** StatefulSet `registry-zot` von 1 auf 3 Replicas skaliert mit podAntiAffinity (preferred) und topologySpreadConstraints (maxSkew=1, ScheduleAnyway). Pod-Verteilung 1+1+1 ueber alle DEV-Nodes, +20 GB Longhorn (3x 10Gi PVC). Backend bleibt S3 auf NAS10. **Plan B — CoreDNS HA:** K3s-Default-Single-Replica abgeloest durch ArgoCD-managed Helm-Chart `coredns/coredns` v1.45.2 mit 3 Replicas (je 1 pro Node), dedizierter ServiceAccount `coredns`, PDB `minAvailable=2`, Service `kube-dns` @ 10.43.0.10 uebernommen, Service `coredns-metrics` @ 9153/TCP, ServiceMonitor `coredns` mit `release: kube-prometheus-stack` Label. Image `rancher/mirrored-coredns-coredns:1.14.1` (= K3s-Default, bereits in containerd-Cache). NodeHosts-Plugin inline im DEV-Override (replaces K3s-managed `/etc/coredns/NodeHosts` ConfigMap-Eintrag). `k3s_disable: + coredns` in `ansible/inventory/dev/group_vars/all.yml`, neues Ansible-Playbook `09-k3s-coredns-disable.yml` (sequenziell `serial: 1`, mit `k3s kubectl get --raw=/healthz` als Health-Check). `coreDns.enabled: false` im DEV-Monitoring-Override (raeumt obsoleten `kube-prometheus-stack-coredns` Service+ServiceMonitor weg, der unsere Pod-Labels nicht matcht). **Lessons Learned (vollstaendig in `docs/phases/phase-12-ha-improvements-completed.md`):** (1) HelmChart-CR-Cleanup beim K3s-Restart entfernt aktiv Service+Deployment+ConfigMap+Pods — nicht erwartet, fuehrte zu ungeplanter DNS-Outage; Recovery via direktem `helm template \| kubectl apply --server-side --force-conflicts` auf k8s-mgmt-10 (umgeht ArgoCD-DNS-Henne-Ei). (2) `ansible.builtin.uri https://localhost:6443/healthz` wirft 401 in modernen K3s/K8s — Auth-Required; ersetzt durch `ansible.builtin.command: k3s kubectl get --raw=/healthz`. (3) Falscher Helm-Chart-Key `serviceMonitor.enabled` wurde still ignoriert — korrekt ist `prometheus.monitor.enabled`. Detected via `helm template \| grep kind:` — ServiceMonitor + ServiceAccount fehlten. (4) RollingUpdate produzierte 1+2+0-Verteilung wegen `whenUnsatisfiable: ScheduleAnyway` (soft); manuell einen Pod auf der ueberbesetzten Node geloescht, Anti-Affinity hat den neuen Pod auf die freie Node geschedult. **ArgoCD App `coredns` mit `selfHeal: false`** — manuelle Kontrolle bei Cluster-DNS bevorzugt. **TEST/PROD-Rollout:** separater Handoff `docs/phases/phase-12b-coredns-test-prod-handoff.md` mit eingearbeiteten DEV-Lessons. |
| 07.05.2026 | 2.20    | **Phase 12b CoreDNS HA komplett ABGESCHLOSSEN (TEST 06.05. + PROD 07.05.).** **TEST-Rollout (06.05.2026):** Cutover war technisch erfolgreich, hatte aber **5min DNS-Outage** durch eine Race-Condition mit ArgoCD Auto-Sync, die in DEV nicht aufgetreten war: `test-infrastructure` App-of-Apps discovered den Push <60s und triggerte Auto-Sync der neuen `coredns`-App, bevor der Cutover-Bypass auf k8s-mgmt-10 ausgefuehrt werden konnte. ServerSideApply uebernahm Service `kube-dns` mit neuem Helm-Selector (`app.kubernetes.io/name: coredns`), aber der laufende K3s-Default-CoreDNS-Pod hatte nur Label `k8s-app: kube-dns` → keine Endpoints → DNS tot. Recovery vorwaerts ohne Cluster-Wiederherstellung via Pod-Label-Ergaenzung (`kubectl label pod coredns-XXX app.kubernetes.io/name=coredns ... --overwrite`) — Pod-Labels sind editierbar (anders als Deployment-Selectors). DNS in <5s zurueck. Anschliessend regulaerer Cutover: Wrangler-Annotations `objectset.rio.cattle.io/*` strippen + Addon-CR direkt deleten + Apply VOR Playbook (nicht parallel). 6 Lessons Learned (LL-T1 bis LL-T6) in `docs/phases/phase-12b-test-completed.md` dokumentiert. **PROD-Rollout (07.05.2026):** Sauber beim **1. Versuch, 0s DNS-Outage**. Alle TEST-Lessons bewaehrt: `coredns-app.yaml` ohne `automated:` Block deployed → kein Race; Wrangler-Annotations gestrippt vor Playbook; `monitoring`-Sync ohne Hook-Hang sofort `Succeeded`. End-to-End-Verify: 4 DNS-Lookups gruen (cluster, cross-NS, extern, NodeHost), alle 53 ArgoCD-Apps Synced/Healthy, Addon-CR `coredns` persistent geloescht, K3s `--disable=coredns` in `/etc/rancher/k3s/config.yaml` auf allen 3 Nodes. Doku `docs/phases/phase-12b-prod-completed.md` (NEU). **Handoff** `docs/phases/phase-12b-coredns-test-prod-handoff.md` mit eingearbeiteten TEST-Lessons als verlaesslicher Referenzplan etabliert (auch fuer zukuenftige Wrangler-Addon-Migrationen wie `metrics-server`/`traefik`). **Naechster Block laut `roadmap-handoff-2026-05-06.md`:** Phase 11 Rolling OS-Update TEST (frueh. 08.05. nachmittags nach 24h PROD Burn-in). |
| 12.05.2026 | 2.21    | **Incident DEV 2026-05-10 bis 2026-05-12 vollstaendig recovered.** Ausloeser: EXT4-Medium-Errors auf einer Longhorn-Daten-Disk des ESXi-Hosts von k8s-dev-21 (Unrecoverable read error `sd 12:0:0:1: [sdk]`) am 10.05. ca. 14:59 CEST → I/O-Storm → SCSI-Reset-Kaskaden → etcd-Slow → systemd-Watchdog killt K3s zyklisch. **Tag 1 (10.05.):** Initiale Mitigation (Longhorn-Settings, k8s-dev-21 cordon, 49 retry=5 Replicas Cleanup-Round-1, CNPG-Pod-Restarts angestossen). **Tag 2 (11.05.):** MariaDB Galera Recovery aus PhysicalBackup `physicalbackup-20260509043000.xb.gz` (S3 NAS10 `k8s-dev-mariadb-backup`); StatefulSet+PVCs zerstoert, MariaDB-CR mit `spec.bootstrapFrom` Restore → Galera 3/3 Ready ~30 Min nach ArgoCD-Sync. i-doit Reconnect erfolgreich (Datenverlust ~35h CMDB-Eintraege, Upload-Dir aus rclone-Backup unbeschaedigt). 6 weitere orphan Longhorn-Volumes aus Phase-1-Cleanup geloescht. Rancher/Cattle-Komponenten entfernt (nicht mehr genutzt nach Headlamp-Umstellung). **Tag 3 (12.05.):** Cluster-Komplett-Heilung. **Phase A — Zombie-Cleanup:** 23 weitere Longhorn-Zombie-Replicas (state=stopped, desire=running) auf Node 21 identifiziert (7 Loki, 16 weitere). Cleanup in 2 Batches → Storage Node 21 von 401.9 GB auf 193.6 GB (−52%). dmesg-Verifikation: letzter SCSI-Reset 15:15:38 MESZ, danach 31+ Min Ruhe. Node 21 `allowScheduling=true` zurueck. **Phase B — CNPG-Cluster-Recovery:** Schwerer Befund — cnpg-shared **komplett DOWN ueber 22h** (alle 3 Pods nicht ready), cnpg-erp **degraded** (cnpg-erp-4 in Unknown-State, cnpg-erp-5 mit 10 Restarts im 30-Min-Crash-Loop). Wurzelursache via SSH-Diagnose: **kubelet-State-Haenger** (EXT4-Volume war clean, aber `crictl ps` zeigte keine postgres-Container, `journalctl -u k3s` leer fuer betroffene Pods). cnpg-shared recovered via sequenzielles Pod-Delete (Primary 50s, Standbys 6-7m mit Barman-Archive-WAL-Restore). cnpg-erp-4 recovered via Pod-Delete (3m12s). cnpg-erp-5 hatte zusaetzlich `dataLocality: strict-local` + `numberOfReplicas: 1` → Pod-Migration nicht trivial; **saubere Migration via PVC-Recreation** (Pod+PVCs geloescht, Operator macht **instance-serial-bump 5→6** und schedult `cnpg-erp-6` auf Node 21, `WaitForFirstConsumer` provisioniert Volumes lokal, `pg_basebackup` vom Primary ~5-10 Min). **Phase C — Volume-Cleanup:** 2 orphan cnpg-erp-5 Volumes auf Node 23 geloescht (26.9 GB freigegeben). 3 degraded Volumes (registry-zot-2, thanos-compactor 30 GiB, thanos-storegateway-0 10 GiB) gehealt via **Replica-Delete-Trick:** Auto-Replenishment greift nicht bei "Zombie"-Replicas (`state: running` + `healthyAt: <leer>`); manuelles `kubectl delete replica.longhorn.io <name>` triggert sofortigen Rebuild auf freiem Node. **Endzustand:** 37/37 Longhorn-Volumes healthy, alle 3 DB-Cluster 3/3 ready mit Optimal-Verteilung 1-pro-Node, Storage ausgewogen (60-65% pro Node), alle Apps validiert (Keycloak, n8n, OpenProject, Odoo, i-doit, Headlamp). **16 Final Lessons Learned** in `docs/incidents/2026-05-11-mariadb-galera-recovery.md` (Inkrement um Tag-2/Tag-3-Sektionen + Lessons): u.a. dmesg-vs-kubectl als Diagnose-Quelle bei Hardware-Issues, kubelet-State-Haenger Pattern + Recovery, CNPG-Streaming-vs-Archive-Replication, `dataLocality strict-local` + `WaitForFirstConsumer` als saubere Migrations-Kombination, Zombie-Replica-Pattern. **Empfehlung Phase 11 TEST:** vor Rolling-OS-Update Pod-Recovery-Test nach jedem Node-Reboot einbauen. |
| 17.05.2026 | 2.23    | **Backup-Subsystem-Reparatur DEV abgeschlossen.** Kontext: Im Anschluss an die Frozen-Replica-Reparatur vom 16.05.2026 stand "Problem B" — alle Backup-CRs beider DB-Cluster (cnpg-erp, cnpg-shared) in Phase `failed` mit `exit status 4` — als offener Folgepunkt im Raum. Erste Hypothese war temporaere NAS-Last; tatsaechliche Wurzelursache war jedoch ein **Konfigurations-Bug, der den Bucket strukturell ueberfuellt hatte**. **Root Cause Cron-Format-Bug:** CNPG `ScheduledBackup.spec.schedule` verwendet 6-Feld-Cron (`Sekunde Minute Stunde Tag Monat Wochentag`), nicht das uebliche 5-Feld-Kubernetes-CronJob-Format. Die bisherigen 5-Feld-Schedules (`50 4 * * *` etc.) wurden als 6-Feld interpretiert: erste Spalte als Sekunde, gewuenschter Stunden-Wert fiel auf 'jede Stunde'-Wildcard zurueck. Folge: **24 Backup-Runs pro Tag statt 1**, akkumuliert seit Mitte April. Statt erwartet max. 14 Backup-CRs (bei 7d Retention) hatte DEV 278+ Backup-CRs und einen entsprechend ueberfuellten Bucket. **Root Cause QuObjects-LIST-Performance:** NAS10 QNAP QuObjects skaliert LIST-API-Performance ungefaehr linear mit der Gesamt-Objektanzahl im Bucket (nicht mit Anzahl direkter Children unter dem angefragten Pfad). Bei ~10000+ Objekten dauerte `LIST cnpg-erp/cnpg-erp/base/` >5 Min und lief in 503-Rate-Limits, was `barman-cloud-backup-show` und `barman-cloud-backup-delete` (Retention) timeouten liess — `barman-cloud-backup` selbst lief weiterhin erfolgreich durch, weshalb Daten im S3 lagen, aber Backup-CRs als `failed` gekennzeichnet wurden. WAL-Archiving (PUT-Operationen) war von der Latenz nicht betroffen. **Reparatur in 5 Schritten:** (1) **Cron-Schedule-Fix in allen 4 YAML-Dateien:** `kubernetes/base/cloudnative-pg/cluster/scheduled-backup.yaml` und je `kubernetes/environments/{dev,test,prod}/cnpg-cluster/scheduled-backup.yaml` — Sekunde `0` vorangestellt: `"45 4 * * *"` → `"0 45 4 * * *"` (cnpg-shared DEV), analog erp/test/prod. ArgoCD-Hard-Refresh in DEV → ScheduledBackups zeigen korrekten 6-Feld-Schedule. TEST+PROD-Cluster waren zu diesem Zeitpunkt ausgeschaltet — Schedules werden bei naechstem Cluster-Start aus Git gezogen. (2) **K8s-Cleanup zeitbasiert:** 208 Backup-CRs geloescht (alle `failed` + 1 `completed` aelter als 7d). Verbleibend 99 CRs alle `completed` und <7d alt. (3) **Diagnose S3-LIST-Performance:** s3cmd Tests von k8s-mgmt-10. Pre-Cleanup Top-Level-LIST 67s, base/-LIST timeout >5min mit 503-Rate-Limits selbst nach QuObjects-Restart. Erkenntnis: strukturelles Skalierungsproblem, nicht nur transiente NAS-Last. Cleanup ueber S3-API selbst nicht praktikabel (rekursives DELETE haengt analog im LIST-Pfad). (4) **Voll-Cleanup im QNAP-Filesystem direkt:** Daniel hat ueber QNAP-UI File-Browser die Verzeichnisse `cnpg-erp/` und `cnpg-shared/` unter `k8s-dev-postgres-wal/` rekursiv geloescht, sowie 3 Test-Dateien aus der 10.-12.05.-Recovery (`test-recovery-0836.txt`, `test-wal-16mb-0839.bin`, `test-wal-postreboot-0907.bin`); QuObjects danach neu gestartet (Index-Resync). Verify: Top-Level-LIST 1.4s (vorher 67s, Faktor ~48). WAL-Archiving lief sofort wieder erfolgreich auf neu angelegtem `wals/`-Pfad. (5) **ScheduledBackups un-suspended + Test-Backup-Trigger:** Manuelle Backup-CRs `cnpg-erp-cleanup-test-001` und `cnpg-shared-cleanup-test-001` angelegt. Beide gingen in `started` → 30-60s spaeter `completed`. `barman-cloud-backup` Dauer 2s, gesamter CR-Lifecycle (inkl. Plugin-Validation + Status-Update) 51s. **Endzustand DEV:** Alle 4 Cluster-Conditions True (`ConsistentSystemID`, `Ready`, `ContinuousArchiving`, `LastBackupSucceeded`). Bucket-Inhalt 2 base/ + ~200 WAL-Files. Top-Level-LIST 21s (akzeptabel — `barman-cloud-backup-show` macht delimiter-LIST auf `base/` mit 1 Eintrag, das ist blitzschnell). Backup-Show/Retention werden in 7d zum ersten Mal real getestet wenn Retention greift. **Begleit-Befund (auf Cluster-Seite, dokumentiert nicht reagiert):** Waehrend der heutigen Bestandsaufnahme hatte cnpg-erp einen weiteren Auto-Failback durchlaufen — Primary war nach 16.05.-Recovery `cnpg-erp-4` auf TL17, ist heute (17.05. nachmittags) wieder `cnpg-erp-3` auf TL18. Replicas `cnpg-erp-4` und `cnpg-erp-7` beide caught up. Eine zusaetzliche `00000012.history` entstand dadurch im Object Storage — analog zum verwaisten `00000011.history`-Pattern vom 16.05.-Incident, diesmal aber valide (neue Timeline existiert wirklich) und durch den Bucket-Reset ohnehin neu geschrieben. **Dokumentation:** Neue Datei `docs/incidents/2026-05-17-cnpg-backup-subsystem-repair.md` (vollstaendiger Bericht, 388 Zeilen, 5 Lessons Learned, 5 offene Folgepunkte). Update `docs/incidents/2026-05-16-cnpg-erp-frozen-replica.md`: Folgepunkte A) Backup-Subsystem-Reparatur und B) TL17-History-Cleanup beide als ✅ behoben markiert (TL17-History wurde durch den Bucket-Reset mitentfernt). **Offene Punkte:** (a) Retention-Wirkung am ~24.05. ueberwachen (`barman-cloud-backup-delete` ist der bisher ungetestete API-Pfad, nun mit kleinem Bucket bestmoegliche Bedingungen). (b) TEST + PROD Bucket-Status pruefen sobald Cluster wieder up — vermutlich aehnlich ueberfuellt aufgrund desselben Cron-Bugs, aber dort nie eskaliert weil 503-Schwelle noch nicht erreicht; Schedule-Korrektur ist via GitOps-Commit bereits ausgerollt, bei Cluster-Start wird sie automatisch wirksam. (c) PrometheusRule fuer Slot-Inactivity (Frueherkennung Frozen-Replica analog zum 16.05.-Pattern, weiterhin offen). (d) **Schedule-Linter im PR-Workflow erwaegen** — neuer Vorschlag aus diesem Incident: einfacher Pre-Commit-/CI-Check, dass jeder `ScheduledBackup.spec.schedule` 6 Felder hat (Cron-Field-Count-Validation per `yq` + regex). (e) Strategische Option NAS10 → Garage S3 fuer CNPG-Backups bleibt im Hinterkopf, ist nach Bucket-Reset aber nicht mehr dringlich. **Lessons Learned (5 in Detail im Incident-Doc):** (1) CNPG verwendet 6-Feld-Cron — bei Migration aus Standard-K8s-Welt leichte Stolperfalle, im CNPG-Doku-Header ueberlesbar; (2) QuObjects-LIST-Performance skaliert mit Total-Object-Count (Top-Level-LIST listet zwar nur direkte Children, intern enumeriert die Engine aber den ganzen Bucket); (3) Bucket-Reset ueber Filesystem statt S3-API ist bei QuObjects der robusteste Weg, wenn LIST-Operations rate-limited sind — anschliessend QuObjects-Restart fuer Index-Resync; (4) Backup-CR `failed` sagt nichts ueber Datenexistenz aus — Plugin-Logs zeigen ob `barman-cloud-backup` selbst erfolgreich war oder erst die Validierung scheiterte; (5) Defense-in-Depth Idee: Schedule-Linter im PR-Workflow als Praeventionsmassnahme. |


| 17.05.2026 | 2.24    | **PrometheusRule `CnpgReplicationSlotInactive` ergaenzt** — Folgepunkt C aus 16.05.-Incident-Doc und Punkt (c) im 17.05.-Backup-Subsystem-Doc abgeschlossen. **Hintergrund:** Beim 16.05.-Incident (cnpg-erp-6 Frozen Replica) meldete CNPG die Cluster trotz inaktivem Replication-Slot weiterhin als `healthy 3/3`. Symptomatisch wurde das Problem erst durch `CnpgWalVolumeWarning` bei 70% WAL-Volume-Belegung erkannt — also Stunden nach Beginn des WAL-Staus. **Neuer Alert:** Loest aus, sobald `cnpg_pg_replication_slots_active{slot_type="physical"} == 0` UND der Pod ist Primary (Filter via `cnpg_pg_replication_in_recovery == 0`, blendet die lokalen Slot-Spiegelungen auf Standby-Pods aus, die strukturell immer `active=0` sind), `for: 10m` (filtert kurze Pod-Restarts und regulaere Failover-Phasen heraus), `severity: warning`. Annotation verlinkt direkt auf `docs/runbooks/cnpg-frozen-replica-stale-slot.md`. **Resultat:** Frozen-Replica-Pattern wird ~10 Min nach Eintreten erkannt, lange bevor `CnpgWalVolumeWarning` bei 70% greift — Reaktionszeit dadurch deutlich verkuerzt (vorher: stundenlanger WAL-Stau bis zur ersten Warnung). **Datei:** Erweiterung der bestehenden `kubernetes/base/monitoring/alert-rules/cnpg-alerts.yaml` (nun 7 Rules statt 6). Live-Query gegen DEV-Prometheus verifiziert (0 aktive Treffer, alle 3 Cluster-Replicas streamen sauber). Test mit echtem Slot-Inaktiv-Szenario erfolgt im naechsten realen Failover-Event (Zwangstest beim naechsten Cluster-Update geplant). **Doku-Updates:** Folgepunkte als ✅ erledigt markiert in `docs/incidents/2026-05-16-cnpg-erp-frozen-replica.md` (Punkt C) und `docs/incidents/2026-05-17-cnpg-backup-subsystem-repair.md` (Punkt c). |

| 17.05.2026 | 2.25    | **i-doit-Backup Tarball-Refactor + Velero-Alert-Tuning.** Zwei zusammenhaengende Optimierungen am Backup- und Monitoring-Subsystem nach Auswertung der Sonntags-Alert-Welle vom 17.05. morgens (1x `ArgoCdAppDegraded` idoit-backup, 9x `KubeJobFailed` Velero-Kopia-Maintain). **(A) i-doit-Backup DEV — Phase 1 (Quick-Fix) + Phase 2 (Tarball-Refactor):** Root Cause des `ArgoCdAppDegraded`: Der Sonntags-Backup-Run um 04:30 UTC haengt 2h im rclone-Compare-Step (3012 Files im src-Verzeichnis, `--checksum` triggert tausende HEAD-Requests gegen NAS10 QuObjects) und faellt in `activeDeadlineSeconds: 7200`. **Phase 1 (Commit 1):** rclone-Parameter `--checksum` durch `--fast-list` ersetzt, Retention `32 -> 7 Tage`, Bucket `k8s-dev-idoit` per QuObjects-GUI komplett geleert (sauberer Neustart). Verifiziert mit zwei manuellen Test-Jobs: Initial-Upload 91s (23 MiB, 3012 Files), Compare-Run gegen vollen Bucket 6 min. Verbesserung ggu. Vorher: 2h Timeout -> 6 min, aber fuer Nightly-Backup mit 3012 Files weiterhin viel. **Phase 2 (Commit 2):** Wechsel von `rclone sync` auf Tarball-Upload via `tar -czf` + `rclone copyto`. Ein PUT pro Verzeichnis statt 3012, ListObjects-Last auf NAS10 eliminiert. Skip-bei-leer fuer `/data/upload`, `tar -tzf`-Integrity-Check vor Upload, Cleanup via `rclone delete --min-age 7d` (trivial, keine Mass-DELETE-Operationen). `emptyDir 500Mi` als Scratch-Space, `activeDeadlineSeconds 7200 -> 1800` (Tarball laeuft in <2 min). Verifizierter Test-Run **9 Sekunden** (Phase 0 vs 1 vs 2: 2h Timeout -> 91s -> 9s), Bucket-Inhalt nur noch 1 Tarball (`src/src-2026-05-17.tar.gz`, 4.55 MB, 75% gzip-Ratio). Neues Restore-Runbook `docs/runbooks/idoit-backup-restore.md` (178 Zeilen) mit Pod-basiertem Restore-Verfahren. **TEST+PROD (Commit 3):** Identische Konfiguration via sed-Substitution aus DEV-Stand erzeugt (`k8s-dev-idoit` -> `k8s-test-idoit` / `k8s-prod-idoit`, `(DEV)` -> `(TEST)` / `(PROD)`). Beide Cluster aktuell deaktiviert, GitOps-konfiguriert. Vorgemerkt fuer nach Cluster-Reaktivierung: Buckets `k8s-test-idoit` und `k8s-prod-idoit` via QuObjects-GUI leeren, manueller Test-Job-Trigger zur Verifikation. **(B) Velero-KubeJobFailed-Alert-Tuning (DEV+TEST+PROD):** Root Cause der 9 KubeJobFailed-Alerts: NAS10 hatte am 17.05. zwischen 09:42-09:43 UTC einen kurzen TCP-Connection-Aussetzer (`dial tcp 192.168.161.61:8010: connect: ...` in den Pod-Logs). 9 parallel laufende Kopia-Maintain-Jobs fielen alle gleichzeitig in dieses Connect-Loch. Velero auto-healing greift beim naechsten Maintain-Cycle (~1h spaeter, alle Folge-Jobs erfolgreich), aber der Default-Alert `KubeJobFailed` (`for: 15m`) feuert in der Zwischenzeit fuer jeden failed Job einzeln. **Loesung:** Pro Environment `defaultRules.disabled.KubeJobFailed: true` im `kube-prometheus-stack` values-override; Custom-Rule `kube-job-failed-{env}` mit zwei Alerts: (1) `KubeJobFailed` mit `job_name!~".*-kopia-maintain-job-.*"` (regulaere Jobs alarmieren weiterhin nach 15 min, Velero-Maintain ist exkludiert); (2) `VeleroKopiaMaintainPersistentFailures` mit `count(...) >= 3` und `for: 2h` — Maintain-Job-TTL=1h, also filtert die `for`-Klausel transiente NAS10-Spikes; bei persistenten Repository-Problemen feuert der Alert nach 2h. **DEV verifiziert:** Default-Rule `kube_job_failed > 0` aus `kube-prometheus-stack-kubernetes-apps` PrometheusRule entfernt nach ArgoCD-Sync, Custom-Group `kube-job-failed-dev.rules` in Prometheus aktiv (beide Rules `health: ok, state: inactive`), letzter "Nachzuegler"-Alert im Alertmanager nach 1 min resolved. **TEST+PROD GitOps-konfiguriert,** Aktivierung mit naechstem ArgoCD-Sync nach Cluster-Reaktivierung. **Lessons Learned aus dieser Session (3):** (1) **NAS10/QNAP QuObjects ist die gemeinsame Wurzel mehrerer Backup-Probleme** — sowohl die idoit-Performance-Issues (Rate-Limits bei LIST/HEAD, 503-Errors) als auch die Velero-Connect-Failures (TCP-Aussetzer ~1-2 min) gehen auf dasselbe System zurueck. Strategischer Folgepunkt (D aus dem Velero-Plan) bleibt: NAS10-seitige Ursache untersuchen (Geraet-Stabilitaet, Last, ggf. Firmware), oder mittelfristig Garage als Alternative pruefen (analog zu CNPG-Backup-Subsystem-Doc Punkt e). (2) **Tarball-Pattern fuer kleine Dateien auf S3** ist deutlich robuster als sync-basiert: 1 PUT >>> N tausend PUTs, atomare Restore-Punkte (ein .tar.gz pro Datum), Integrity-Check vor Upload. Anwendbar auf weitere kleine Backup-Quellen (z.B. ggf. Garage-rclone-Backups bei vielen kleinen Objekten — Pruefung offen). (3) **Velero setzt absichtlich kein TTL auf failed Maintain-Jobs** (Investigation-Zweck). Mit dem neuen Alert-Tuning ist die manuelle Aufbewahrung Laerm; vorgemerkt fuer spaeter: Velero-Helm-Values `repositoryMaintenance.keepLatestMaintenanceJobs` und failed-job-TTL durchsehen. **Geaenderte Files (9):** `kubernetes/environments/{dev,test,prod}/apps/idoit/backup/cronjob.yaml` (komplett refactored, Tarball-Logik); `kubernetes/environments/{dev,test,prod}/monitoring/values-override.yaml` (`defaultRules.disabled.KubeJobFailed: true`); `kubernetes/environments/{dev,test,prod}/monitoring-alerts/kustomization.yaml` (Resource ergaenzt); `kubernetes/environments/{dev,test,prod}/monitoring-alerts/kube-job-failed-{env}.yaml` (NEU, 41 Zeilen). Neues Runbook `docs/runbooks/idoit-backup-restore.md`. **Offene Folgepunkte fuer TEST+PROD nach Cluster-Reaktivierung:** Buckets `k8s-test-idoit` und `k8s-prod-idoit` via QuObjects-GUI leeren, manueller idoit-Backup-Testlauf, Velero-Alert-Tuning wirkt automatisch beim ersten Sync. |
| 18.05.2026 | 2.26    | **Phase 13: Kyverno Webhook Hardening + Longhorn Auto-Balance (DEV).** Drei verkettete Symptome auf DEV diagnostiziert: (1) Permanente Longhorn-UI-Meldungen `Snapshot becomes not ready to use` (34 Snapshots in 7 Tagen, 32x `readyToUse=false`, ~80 GB belegt durch alte `markRemoved=true` Snapshots), (2) Kyverno ClusterPolicy-Violations fuer `disallow-host-path` (Velero-Backup-Pods + longhorn-manager) und `disallow-privileged-containers` (longhorn-manager), (3) longhorn-manager Crash-Loop mit 75 Restarts in 88 Tagen (~1x/Tag) durch Exit Code 1. **Root Cause:** Der `kyverno-resource-validating-webhook-cfg` aus dem `kyverno-policies` Helm-Chart hat per Default `failurePolicy: Fail` (separater Webhook zum bereits auf `Ignore` gesetzten Admission-Webhook aus dem Kyverno-Chart). Bei Kyverno-Pod-Restarts ist der Service-Endpoint kurz nicht verfuegbar -> longhorn-manager API-Calls schlagen fehl -> Crash + Replica-Reconnect -> Auto-Balance `best-effort` triggert Rebuilds -> System-Snapshots als Nebenwirkung. **Loesung (GitOps via DEV-Override):** (a) `kubernetes/environments/dev/kyverno-policies/values-override.yaml` NEU: `failurePolicy: Ignore` (semantisch korrekt da alle Policies im Audit-Mode) + `policyExclude` fuer `disallow-host-path` und `disallow-privileged-containers` mit Namespace-Excludes fuer `longhorn-system`, `velero`, `monitoring` (alle drei mit `kinds: [Pod]` schema-konform). (b) `kubernetes/environments/dev/longhorn/values-override.yaml` NEU: `replicaAutoBalance: least-effort` (Conservative Auto-Balance, balanciert nur bei echten degraded Volumes). (c) `kyverno-policies-app.yaml` + `longhorn-app.yaml` erweitert um zweite valueFile in DEV-Override-Pfad. **Doku:** `ADR-003-kyverno-webhook-hardening.md` (Entscheidung + Alternativen + Konsequenzen), `phase-13-kyverno-longhorn-stabilization-dev.md` (Implementation + Verifikations-Checkliste + Rollback-Strategie + Learnings). **Naechste Schritte:** 48h-Observation auf DEV (longhorn-manager Restart-Count stabil), Snapshot-Purge fuer alte `markRemoved=true` Snapshots, dann TEST/PROD-Rollout (Phase 13b/13c) sobald TEST-Cluster wieder eingeschaltet ist. **DO-NOT-PORT pauschal zu TEST/PROD** ohne getrennte Review-Session (deshalb bewusst DEV-spezifische Overrides statt Base-Aenderung). Begleitend: Kyverno HA (3 Replicas) ist vertagt als separate Phase fuer alle Controller in Base. |
| 19.05.2026 | 2.27    | **Velero AWS-SDK-go-v2 Checksum-Inkompatibilitaet mit NAS10 QuObjects gefixt (DEV).** Symptom: Seit 14.05.2026 schlugen alle Daily-Backups (`velero-daily-backup-*`) systematisch mit `phase: Failed` und `failureReason: ... InvalidDigest: The Content-MD5 or checksum value that you specified is not valid` beim finalen PutObject der `velero-backup.json` fehl — Items wurden vollstaendig erfasst (z.B. 4752/4752), erst der Metadata-Upload nach NAS10 crashte. 5 Tage ohne erfolgreichen Cluster-Backup. **Root Cause:** `aws-sdk-go-v2` v1.30+ (verwendet von `velero-plugin-for-aws:v1.13.0`) hat den Default fuer Request-Checksums auf `WHEN_SUPPORTED` umgestellt und sendet seitdem standardmaessig `x-amz-sdk-checksum-algorithm` Header sowie Trailing-Checksums (CRC32/CRC32C); QNAP QuObjects (aelteres S3-Protokoll) interpretiert diese Header nicht korrekt und antwortet mit HTTP 400 InvalidDigest. **Symptom-Profil identisch zu Velero Issue [#8742](https://github.com/vmware-tanzu/velero/issues/8742) + Sammel-Issue [#8265](https://github.com/vmware-tanzu/velero/issues/8265):** Scality, IBM COS, Oracle, Linode, Dell EMC OneFS — alle mit gleichem Fix gefixt. **Recherche-Befund (vor Implementation):** Aktuellster Helm-Chart `velero-12.0.1` (27.04.2026) und Plugin `v1.13.0` (Sep 2025) enthalten in den Release Notes **keinen** Checksum-Fix; Chart-/Plugin-Upgrade wuerde 6 Monate Drift mitnehmen ohne Problem zu loesen — daher gezielter Workaround statt Upgrade gewaehlt. **Loesung (offizieller Velero-Workaround):** Setzen von `checksumAlgorithm: ""` (Leer-String) in `configuration.backupStorageLocation[0].config` der Velero-Helm-Values. Plugin laesst dann den `x-amz-sdk-checksum-algorithm` Header weg, keine Trailing-Checksums mehr, QuObjects akzeptiert Upload. **Aenderungen:** (a) `kubernetes/base/velero/values.yaml` — `checksumAlgorithm: ""` als Default-Eintrag mit Kommentar (Doku-Charakter, weil Helm-Listen-Merge die Base-Liste durch Environment-Overrides ersetzt — der Eintrag wirkt nur wenn das Overlay keine `backupStorageLocation` definiert; Code-Referenz zu velero-io/velero#8265 und #8742). (b) `kubernetes/environments/dev/velero/values-override.yaml` — `checksumAlgorithm: ""` zusaetzlich zu bestehenden NAS10-Config-Werten (das ist der **wirksame** Fix fuer DEV; Kommentar verlinkt auf Phase-Doku). **Wichtiges Helm-Verhalten dokumentiert:** YAML-Listen werden in Helm-Values *nicht element-weise gemergt* — der Override ersetzt die ganze Liste. Daher muss `checksumAlgorithm: ""` in **jedem** Environment-Override gesetzt werden, nicht nur in Base. Base-Eintrag ist Doku/Default fuer kuenftige neue Umgebungen. **Verifikation (DEV):** ArgoCD `Synced + Healthy` nach Push, BackupStorageLocation `default` im Cluster zeigt `spec.config.checksumAlgorithm: ""` (initialer Auto-Sync hatte den Eintrag nicht gerendert; ein `argocd.argoproj.io/refresh=hard`-Annotation-Patch hat dann den BSL-Manifest-Diff materialisiert — Hinweis: bei Helm-Values-Aenderungen, die nur in `.config`-Map fliessen, kann ArgoCD den Diff initial uebersehen, Hard-Refresh erzwingt Re-Render). Anschliessend Pod-Restart per `kubectl rollout restart deployment/velero` (zur Sicherheit gegen Plugin-internes Caching). **Zwei Test-Backups beide erfolgreich:** `test-checksum-fix-001` (nur Namespace `velero`, 1350 Items, `defaultVolumesToFsBackup: false`) → Completed in 7 Sekunden, keine InvalidDigest-Errors mehr beim finalen `velero-backup.json`-Upload. `test-checksum-fix-002-full` (alle Namespaces inkl. PV-fs-backup) → ~50 Min, ~5-6 GB Daten erfolgreich nach NAS10 hochgeladen, 0 Failed-PVBs (gegenueber 100 erwarteten Warnings vor dem Fix). Damit ist der Fix sowohl fuer den reinen Resource-Pfad als auch fuer Kopia-fs-backup-Daten verifiziert. **Cleanup:** 10 problematische Backup-CRs (Failed/PartiallyFailed/FailedValidation aus 14.-19.05. + Folgetage des Bugs ab 07.05.) per `DeleteBackupRequest` ueber kubectl_apply angelegt — Velero loescht sequenziell Backup-CR + zugehoerige S3-Objekte. Daily-Backup-Schedule `velero-daily-backup` (05:45 Europe/Berlin) bleibt aktiv; naechster Lauf morgen frueh zeigt Live-Wirkung. **Status TEST+PROD:** Aktuell deaktiviert; Rollout in separater Session sobald aktiv. Dieselben zwei Aenderungen in `kubernetes/environments/{test,prod}/velero/values-override.yaml` reichen — Base-Doku-Eintrag wirkt sich dort nicht aus, da die Overrides die Base-Liste ueberschreiben. **Wichtig fuer kuenftige Helm-Values-Aenderungen:** ArgoCD-Diff kann subtile Config-Map-Aenderungen uebersehen, wenn diese in `.config`-Subfelder fliessen (Helm-Template-Iteration `range $key, $value`); Hard-Refresh via Annotation ist der zuverlaessige Weg zum manifesten Re-Render. **Geaenderte Files (3):** `kubernetes/base/velero/values.yaml`, `kubernetes/environments/dev/velero/values-override.yaml`, `docs/phases/velero-aws-sdk-checksum-fix-dev.md` (NEU, 190 Zeilen — Befund, Loesung, Verifikation, Helm-Listen-Merge-Erklaerung, Cleanup-Plan, TEST/PROD-Rollout-Plan). **Lessons Learned (4):** (1) `aws-sdk-go-v2` v1.30+ Default-Checksum-Verhalten ist die haeufigste Quelle von S3-Compat-Inkompatibilitaeten bei Velero in 2025/2026 — Issue #8265 ist die zentrale Velero-Anlaufstelle fuer S3-kompatible Provider; (2) Chart-/Plugin-Upgrade ist nicht immer die Loesung — vor jedem Upgrade pruefen, ob die geplante Aenderung das aktuelle Problem ueberhaupt adressiert; (3) Helm-Values: List-Merge ersetzt, Map-Merge merged — bei Aenderungen an List-Items in Base immer pruefen, ob ein Override die Aenderung schluckt; Konsequenz hier: env-spezifischer Eintrag noetig; (4) ArgoCD-Diff kann initial unzureichend sein bei Helm-Values-Aenderungen, die auf Sub-Map-Ebene durchschlagen — `argocd.argoproj.io/refresh=hard` Annotation als Standard-Mittel im Werkzeugkasten. **Offene Folgepunkte:** (a) TEST+PROD-Rollout sobald Cluster reaktiviert (Aufwand: ~15 Min pro Env: Override-Patch + Commit + Hard-Refresh + Pod-Restart + Verifikation); (b) NAS10-seitige Stabilitaetsanalyse weiterhin offen (strategischer Punkt D aus dem 17.05.-Velero-Alert-Tuning-Eintrag: TCP-Aussetzer + LIST-Rate-Limits + jetzt Checksum-Inkompatibilitaet — alles dasselbe Geraet; Garage S3 als interne Alternative bleibt mittelfristige Option); (c) Velero-Chart-Upgrade auf 12.x als separate Aufgabe nach Phase 9, im Rahmen des ohnehin geplanten "Systematic Helm chart update review" (post-Phase-9). |

---

*Dieses Dokument wird kontinuierlich aktualisiert, sobald neue Entscheidungen getroffen oder Phasen abgeschlossen werden.*
