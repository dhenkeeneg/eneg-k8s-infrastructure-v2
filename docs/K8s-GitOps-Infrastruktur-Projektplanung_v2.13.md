# GitOps Kubernetes-Infrastruktur auf VMware vSphere

## Projektplanung - Version 2.13

**Erstellt:** 04.02.2026  
**Letzte Aktualisierung:** 13.04.2026  
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
| Kyverno | - | Phase 9 |
| Falco | - | Phase 9 |
| Trivy Operator | - | Phase 9 |

### Layer 6: Identity und Backup

| Komponente | Version | Status |
|------------|---------|--------|
| Keycloak | 26.5.4 | ✅ Installiert |
| Velero | - | Phase 10 |
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

| Was | Wohin | Frequenz | Retention | Tool |
|-----|-------|----------|-----------|------|
| PostgreSQL (WAL) | NAS10 S3 (k8s-{env}-postgres-wal) | Kontinuierlich | 7 Tage | CloudNativePG/Barman |
| PostgreSQL (Dump) | NAS10 S3 (k8s-{env}-postgres-backup) | Taeglich 03:00/03:15 | 32 Tage | pg_dumpall CronJob |
| MariaDB (Physical) | NAS10 S3 (k8s-{env}-mariadb-backup) | Taeglich 02:30 | 7 Tage (168h) | MariaDB Operator |
| Garage S3-Inhalte | NAS10 S3 (k8s-{env}-garage-backup) | Taeglich | 30 Tage | rclone CronJob |
| Odoo Filestore | NAS10 S3 (k8s-{env}-odoo-backup) | Taeglich | 30 Tage | rclone CronJob |
| Kubernetes Resources | S3 | Taeglich 04:00 | 14 Tage | Velero (Phase 10) |
| Longhorn Volumes | S3/NFS | Taeglich 05:00 | 14 Tage | Longhorn (Phase 10) |
| OpenTofu State | S3 (k8s-terraform-state, geplant) | Bei jedem Apply | Versioniert | S3 Backend |
| VMs | Veeam | Bestehend | Bestehend | Veeam |

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

- Namespace-Isolation via Calico (Phase 9)
- Nur explizit erlaubte Kommunikation
- Ingress nur ueber Traefik

### Policy Engine (Phase 9)

- Kyverno: Pod Security Standards, Image Policies, Resource Quotas
- Falco: Runtime Security Monitoring
- Trivy Operator: Vulnerability Scanning

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
| 7     | Monitoring-Stack (inkl. Backup-Health, WAL-Volume, S3-Endpoint Alerting)          | 2-3 Tage | 🔲 Offen                     |
| 8     | TEST & PROD Rollout                                                               | 2-3 Tage | ✅ Abgeschlossen (30.03.2026) |
| 9     | Security & Haertung                                                               | 3-5 Tage | 🔲 Offen                     |
| 10    | Backup & Dokumentation                                                            | 2-3 Tage | 🔲 Offen                     |

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

| Datum | Version | Aenderung |
|-------|---------|-----------|
| 04.02.2026 | 1.0 | Initiale Version |
| 04.02.2026 | 1.1 | Phase 0 abgeschlossen |
| 09.02.2026 | 1.2 | Phase 2 abgeschlossen (K3s) |
| 10.02.2026 | 1.3 | Phase 3 abgeschlossen (ArgoCD + SOPS) |
| 18.02.2026 | 2.0 | Phase 4 abgeschlossen (MetalLB, Traefik, Cert-Manager, Longhorn), Template-Bugfix, komplette Neuformatierung (Encoding-Bereinigung) |
| 25.02.2026 | 2.1 | Phase 5 abgeschlossen, Phase 6 gestartet, Naming Convention um Zwei-Secret-Pattern erweitert |
| 25.02.2026 | 2.2 | n8n deployed (Phase 6.1), Garage S3 in Tech-Stack und Backup-Strategie ergaenzt |
| 26.02.2026 | 2.3 | Garage S3 v2.2.0 deployed (Phase 6.1b), Phase 5+6 Fortschritte im Implementierungsplan ergaenzt |
| 04.03.2026 | 2.4 | Keycloak 26.5.4 deployed (Phase 6.4), AD-Anbindung, OpenProject LDAP, SSO-Erkenntnisse dokumentiert |
| 10.03.2026 | 2.5 | i-doit Open 37 deployed (Phase 6.5), eigenes Docker Image, MariaDB Operator CRDs, ghcr.io Registry |
| 15.03.2026 | 2.6 | Garage bootstrap_peers Fix (Node-IDs hinzugefuegt), Barman Cloud Plugin Migrations-Anleitung erstellt, ArgoCD CLI auf k8s-mgmt-10 installiert, Cluster Shutdown/Startup Prozedur durchgefuehrt und dokumentiert |
| 16.03.2026 | 2.7 | Phase 8a: Kustomize-Overlay Refactoring fuer Multi-Environment (MetalLB, Traefik, Longhorn, ArgoCD), TEST-Overlays vorbereitet, Repository-Struktur und GitOps-Workflow aktualisiert, ADR-001 erstellt |
| 16.03.2026 | 2.8 | Phase 8b: TEST-Cluster aufgebaut (OpenTofu, Ansible, K3s, ArgoCD Bootstrap), 11 Infrastruktur-Apps Synced+Healthy, Dashboards erreichbar, Learnings dokumentiert |
| 26.03.2026 | 2.9 | Phase 8b-continued: Alle 6 Pilot-Apps nach TEST deployed (Environment-Overlay Refactoring), DB-Operatoren/Cluster/Garage refactored, 14 TEST ArgoCD Apps, Fixes (ghcr auth, DB-Passwort Sonderzeichen, manuelle DB-Migration/Init) |
| 26.03.2026 | 2.10 | Post-Deployment TEST: Garage S3 Key+Bucket fuer OpenProject, Keycloak AD/LDAP+OIDC (Realm eNeG), OpenProject SMTP+LDAP, it-info-versand OIDC+Group Mapper, Fix Realm-Name eneg->eNeG |
| 30.03.2026 | 2.11 | Phase 8c ABGESCHLOSSEN: PROD-Cluster komplett deployed + Post-Deployment-Konfiguration (Garage Keys, Keycloak OIDC, OpenProject LDAP/S3/SMTP/Hocuspocus, Odoo, SSL/DNS, Backups verifiziert) |
| 30.03.2026 | 2.12 | Headlamp Kubernetes Dashboard (Helm v0.41.0) auf DEV, TEST, PROD deployed, ServiceAccount Token Auth, Split-DNS |
| 31.03.2026 | 2.13 | Dokumentation gegen Repository abgeglichen: Phase 6+8 Status auf Abgeschlossen, DNS PROD Wildcard durch Einzel-Eintraege ersetzt, Pilot-Apps-Tabelle auf 6 Apps erweitert (Keycloak, i-doit, it-info-versand ergaenzt), Repository-Struktur aktualisiert (docker/, scripts/, prod-Overlays, Ansible Playbooks), Namespace-Struktur vervollstaendigt, Dokumentationsstruktur aktualisiert, cnpg-barman-cloud-plugin-migration.md Guide erstellt, CNPG-Spec auf cnpg-shared + cnpg-erp angepasst, Kustomize-Overlay-Tabellen um DB- und App-Layer erweitert, S3-Bucket-Tabelle mit tatsaechlichen Namenskonventionen aktualisiert, Backup-Uebersicht korrigiert, DEV App-Secrets und Infra-Secrets von base/ nach environments/dev/ migriert (11 ArgoCD Apps angepasst), ArgoCD App-of-Apps OutOfSync Fix via resource.customizations.ignoreDifferences in argocd-cm (directory.recurse Default, Ref: #4501), ADR-002 Branch-per-Environment Promotion-Strategie, Phase 8e Migrationsplan erstellt |
| 13.04.2026 | 2.13 | Phase 7 Monitoring-Stack ABGESCHLOSSEN (DEV+TEST+PROD): kube-prometheus-stack 83.0.0, Thanos 17.3.1, Loki 6.55.0, Alloy 1.7.0, Blackbox Exporter 11.9.1, prometheus-msteams v1.5.4. 9 ArgoCD Apps + 23 Pods pro Env, Grafana Dashboards (7x), Custom PrometheusRules (4x), AlertManager E-Mail+Teams, Watchdog 07:00 MESZ. Layer 4 Monitoring-Tabelle aktualisiert. Learning #20: CNPG enablePodMonitor SSA-Workaround (eigenstaendige PodMonitor-CRDs statt Operator-Funktion fuer TEST/PROD) |

---

*Dieses Dokument wird kontinuierlich aktualisiert, sobald neue Entscheidungen getroffen oder Phasen abgeschlossen werden.*
