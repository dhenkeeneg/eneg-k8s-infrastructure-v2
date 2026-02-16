# DEV Environment - OpenTofu Konfiguration

## Übersicht

Erstellt die 3 K3s DEV-Cluster VMs aus einem Ubuntu 24.04 Template.

**Alle Hosts sind in vcenter-a.eneg.de (ESXi 8.0.3)**

## VM-Verteilung

| VM | Host | Datastore | IP |
|----|------|-----------|-----|
| k8s-dev-21 | s2842.eneg.de | S2842_SSD_01_VMS | 192.168.180.21 |
| k8s-dev-22 | s2843.eneg.de | S2843_SSD_01_VMS | 192.168.180.22 |
| k8s-dev-23 | s3168.eneg.de | S3168_SSD_01_VMS | 192.168.180.23 |

## Voraussetzungen

- VM-Template `ubuntu-24.04-k8s-template` in vCenter-A vorhanden
- VM-Ordner `eNeG-VM-K8s/DEV` in vCenter-A vorhanden
- Portgroup `VT 180 - K8s Dev` auf allen Hosts konfiguriert

## Verwendung

```bash
# 1. In DEV-Umgebung wechseln
cd ~/git/eneg-k8s-infrastructure-v2/terraform/environments/dev

# 2. Credentials-Datei erstellen (einmalig)
cp credentials.example.tfvars credentials.auto.tfvars
nano credentials.auto.tfvars

# 3. Initialisieren
tofu init

# 4. Plan prüfen
tofu plan

# 5. VMs erstellen
tofu apply
```

## Nach der Erstellung

VMs werden automatisch mit statischer IP konfiguriert (Guest Customization).
Nach dem Erstellen:

1. SSH-Keys verteilen (Ansible Phase 2, Playbook 01)
2. K3s installieren (Ansible Phase 2, Playbook 02)

## Änderungshistorie

| Datum | Änderung |
|-------|----------|
| 06.02.2026 | Initiale Erstellung mit Dual-vCenter-Support |
| 16.02.2026 | Migration auf Single vCenter (vcenter-a.eneg.de), S2842 neu aufgebaut mit ESXi 8.0.3 |
