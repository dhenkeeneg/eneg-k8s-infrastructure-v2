# Phase 4: Kubernetes-Basis — Abschlussdokument

**Status:** ✅ Abgeschlossen  
**Abgeschlossen am:** 18.02.2026  
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Zusammenfassung

Phase 4 hat die gesamte Kubernetes-Basis-Infrastruktur für den DEV-Cluster aufgebaut:
LoadBalancer, Ingress Controller, SSL-Zertifikatsverwaltung, verteilter Storage und
das Ingress-Pattern für alle zukünftigen Anwendungen. Zusätzlich wurden in dieser
Phase kritische Fehler im Packer-Template behoben und das Ubuntu-Template auf
24.04.4 aktualisiert.

---

## Installierte Komponenten

| Komponente | Version | Namespace | Status |
|---|---|---|---|
| MetalLB | v0.15.3 | metallb-system | ✅ Healthy |
| Traefik | v3.6.7 (Chart v39.0.0) | traefik | ✅ Healthy |
| Cert-Manager | v1.17.2 | cert-manager | ✅ Healthy |
| IONOS Webhook | latest | cert-manager | ✅ Healthy |
| KSOPS | v4.4.0 | argocd (repo-server) | ✅ Healthy |
| Longhorn | v1.9.2 | longhorn-system | ✅ Healthy |

---

## ArgoCD Applications

| Application | Typ | Source |
|---|---|---|
| metallb | Kustomize (remote) | github.com/metallb/metallb v0.15.3 |
| traefik | Helm (multi-source) | traefik/traefik Chart v39.0.0 + Git values |
| cert-manager | Helm (multi-source) | jetstack/cert-manager Chart v1.17.2 + Git values |
| cert-manager-webhook-ionos | Helm | fabmade/cert-manager-webhook-ionos |
| cert-manager-secrets | Kustomize + KSOPS | Git (SOPS-verschlüsseltes IONOS Secret) |
| cert-manager-config | Directory | Git (ClusterIssuers) |
| longhorn | Helm (multi-source) | charts.longhorn.io v1.9.2 + Git values |
| longhorn-ingress | Directory | Git (IngressRoute + Certificate) |

---

## Netzwerk-Konfiguration

### MetalLB IP-Pool (DEV)

| Adresse | Verwendung |
|---|---|
| 192.168.180.100 | Traefik LoadBalancer (dediziert) |
| 192.168.180.151-199 | Allgemeiner Pool für weitere Services |

### DNS-Einträge

| Hostname | Typ | Ziel |
|---|---|---|
| traefik-dev.eneg.de | A | 192.168.180.100 |
| argocd-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de |
| longhorn-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de |

### SSL-Zertifikate (Let's Encrypt Production)

| Zertifikat | Namespace | DNS-Name |
|---|---|---|
| traefik-dashboard-tls | traefik | traefik-dev.eneg.de |
| argocd-server-tls | traefik | argocd-dev-v2.eneg.de |
| longhorn-dashboard-tls | traefik | longhorn-dev-v2.eneg.de |

---

## Longhorn Storage-Konfiguration

### Node-Konfiguration

| Node | Disk | Gesamt | Scheduleable |
|---|---|---|---|
| k8s-dev-21 | /var/lib/longhorn | ~380 GB | ~285 GB |
| k8s-dev-22 | /var/lib/longhorn | ~380 GB | ~285 GB |
| k8s-dev-23 | /var/lib/longhorn | ~380 GB | ~285 GB |

### Longhorn Einstellungen

| Setting | Wert | Begründung |
|---|---|---|
| defaultReplicaCount | 2 | Optimal für 3 Nodes |
| defaultDataLocality | best-effort | Performance + Verfügbarkeit |
| replicaAutoBalance | best-effort | Automatische Verteilung |
| storageReservedPercentage | 25% | Sicherheitspuffer |
| storageOverProvisioning | 200% | Thin Provisioning |
| preUpgradeChecker.jobEnabled | false | Erforderlich für ArgoCD |

### Voraussetzungen (Ansible Playbook)

Vor Longhorn-Deployment müssen auf allen Nodes installiert/konfiguriert sein:
- `open-iscsi` + `iscsid` (aktiv + enabled)
- `nfs-common`
- `iscsi_tcp` + `dm_crypt` Kernel-Module
- `multipathd` gestoppt + maskiert (Konflikt mit iSCSI)

Playbook: `ansible/playbooks/04-longhorn-prerequisites.yml`

---

## Template-Bugfix & Aktualisierung

### Gefundener Bug: LVM nicht erweitert nach Clone

**Problem:** Packer erstellte Template mit 50GB Disk. OpenTofu setzte VM-Disk
korrekt auf 384GB, aber LVM/Partition wurden nicht automatisch erweitert.

**Ursache:** `cloud-init` war nicht konfiguriert um die Partition nach dem
ersten Boot zu erweitern.

**Fix:**
1. `cloud-guest-utils` + `cloud-initramfs-growroot` im Template installiert
2. `growpart` + `resize_rootfs: true` in cloud-init konfiguriert
3. Bestehende DEV-Nodes manuell per Ansible erweitert (`05-extend-disk.yml`)

### Template-Aktualisierungen

| Änderung | Details |
|---|---|
| Ubuntu Version | 24.04.3 → 24.04.4 |
| Kernel | Hardcodiert 6.8.0-71 → GA Kernel (linux-image-generic) |
| Build-Host | s2843 → s3168 (ISO liegt auf S3168_HDD_00_BOOT) |
| Timezone | Nicht gesetzt → Europe/Berlin |
| Disk-Erweiterung | Fehlend → cloud-init growpart automatisch |
| Neue Pakete | cloud-guest-utils, cloud-initramfs-growroot |

### Packer Build-Konfiguration (aktuell)

```
Build-Host:  s3168.eneg.de
Datastore:   S3168_HDD_00_BOOT
ISO:         ubuntu-24.04.4-live-server-amd64.iso
Template:    ubuntu-24.04-k8s-template
Ordner:      eNeG-VM-Vorlagen
```

**Wichtig:** Template liegt nach dem Build auf `S3168_HDD_00_BOOT`. OpenTofu
findet es automatisch über den Namen im Datacenter – keine Anpassung nötig.

### Bestehende DEV-Nodes erweitert

```bash
# Durchgeführt am 18.02.2026
ansible-playbook ansible/playbooks/05-extend-disk.yml \
  -i ansible/inventory/dev/hosts.ini
```

Ergebnis: Alle 3 Nodes von 46,9GB auf 380,9GB erweitert (kein Reboot nötig).

---

## Timezone-Korrektur

**Problem:** Alle Nodes liefen auf `Etc/UTC` statt `Europe/Berlin`.

**Fix:**
- Packer `user-data`: `timezone: Europe/Berlin` hinzugefügt
- Ansible `03-system-maintenance.yml`: Timezone-Task ergänzt

**Sofortmaßnahme auf bestehenden Nodes:**
```bash
ansible-playbook ansible/playbooks/03-system-maintenance.yml \
  -i ansible/inventory/dev/hosts.ini \
  --tags timezone
```

---

## Architektur-Entscheidungen & Patterns

### Ingress-Pattern (Standard für alle Apps)

```
Internet/LAN
    │
    ▼
┌─────────────────────────────────┐
│  Traefik (192.168.180.100)      │
│  Namespace: traefik             │
│  - Certificate (cert-manager)   │
│  - IngressRoute                 │
│  - TLS-Terminierung             │
└──────────┬──────────────────────┘
           │ HTTP (port 80) cross-namespace
           ▼
┌─────────────────────────────────┐
│  Backend-App                    │
│  Namespace: <app-namespace>     │
│  - Service (ClusterIP, port 80) │
└─────────────────────────────────┘
```

**Regeln:**
1. Certificate + IngressRoute immer im **traefik** Namespace
2. Backend-Service wird **cross-namespace** referenziert
3. Backend läuft auf **HTTP** (TLS wird von Traefik terminiert)
4. DNS-Einträge werden einzeln angelegt (CNAME auf traefik-dev.eneg.de)

### Helm Chart Multi-Source Pattern (ArgoCD)

```yaml
sources:
  - repoURL: https://charts.example.io
    chart: app-name
    targetRevision: v1.0.0
    helm:
      releaseName: app-name
      valueFiles:
        - $values/kubernetes/base/app-name/values.yaml
  - repoURL: git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git
    targetRevision: main
    ref: values
```

---

## Key Learnings

### 1. LVM wird nach VM-Clone nicht automatisch erweitert

vSphere setzt die Disk-Größe beim Clonen korrekt, aber LVM/Filesystem
bleiben bei der Template-Größe. **cloud-init growpart** muss explizit
konfiguriert werden.

```yaml
# In user-data.pkrtpl.hcl
user-data:
  growpart:
    mode: auto
    devices: ['/']
  resize_rootfs: true
```

### 2. Packer Build-Host muss Zugriff auf ISO haben

vSphere kann keine ISO von einem anderen Datastore/Host mounten.
Build-Host und ISO müssen auf demselben Host/Datastore liegen.

### 3. Traefik Helm Chart v39.0.0 Breaking Change

`redirections` und `tls` Felder benötigen zusätzliche `http:`-Verschachtelung.

### 4. Longhorn: open-iscsi inactive ist normal

`open-iscsi` ist ein oneshot-Service. Nur `iscsid` muss aktiv sein.
Longhorn kommuniziert direkt mit iscsid.

### 5. Longhorn + ArgoCD: preUpgradeChecker deaktivieren

```yaml
preUpgradeChecker:
  jobEnabled: false  # ERFORDERLICH für ArgoCD-Kompatibilität
```

### 6. Cert-Manager DNS-01 Split-DNS

Interne DNS-Server kennen Let's Encrypt Challenges nicht.
Externe Nameserver müssen explizit konfiguriert werden:

```yaml
extraArgs:
  - --dns01-recursive-nameservers=8.8.8.8:53,1.1.1.1:53
  - --dns01-recursive-nameservers-only
```

---

## Dateistruktur

```
kubernetes/
├── base/
│   ├── metallb/
│   │   ├── kustomization.yaml
│   │   ├── ipaddresspool.yaml
│   │   └── l2advertisement.yaml
│   ├── traefik/
│   │   ├── values.yaml
│   │   └── certificate.yaml
│   ├── cert-manager/
│   │   ├── values.yaml
│   │   ├── clusterissuer-staging.yaml
│   │   ├── clusterissuer-prod.yaml
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml
│   │       └── ionos-secret.enc.yaml
│   └── longhorn/
│       ├── values.yaml
│       └── ingress.yaml
└── environments/
    └── dev/
        └── infrastructure/
            ├── metallb-app.yaml
            ├── traefik-app.yaml
            ├── cert-manager-app.yaml
            ├── cert-manager-webhook-ionos-app.yaml
            ├── cert-manager-secrets-app.yaml
            ├── cert-manager-config-app.yaml
            ├── longhorn-app.yaml
            └── longhorn-ingress-app.yaml

ansible/playbooks/
├── 04-longhorn-prerequisites.yml   # iSCSI, NFS, Kernel-Module
└── 05-extend-disk.yml              # Partition + LVM + Filesystem erweitern

packer/ubuntu-24.04/
├── ubuntu-24.04.pkr.hcl            # Build-Definition
├── variables-vcenter-a.pkrvars.hcl # Build auf s3168, ISO auf S3168_HDD_00_BOOT
└── http/
    └── user-data.pkrtpl.hcl        # cloud-init mit growpart + timezone
```

---

## Nächste Schritte → Phase 5

- CloudNativePG Operator installieren
- PostgreSQL HA-Cluster (3 Instanzen) deployen
- MariaDB Galera Cluster deployen
- Datenbank-Namespaces + Netzwerk-Policies

---

**Ende Phase 4 - Kubernetes-Basis vollständig! Bereit für Phase 5 (Datenbanken)!** 🚀
