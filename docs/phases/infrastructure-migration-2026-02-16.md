# Infrastruktur-Migration: Single vCenter (16.02.2026)

## Anlass

Das alte vCenter (vcenter.eneg.de) mit ESXi 6.7 wurde dekommissioniert. Der Host S2842 wurde neu aufgebaut mit ESXi 8.0.3 und in vcenter-a.eneg.de integriert. Dadurch befinden sich jetzt alle drei Hosts in einem einzigen vCenter.

## Ausgangssituation

- vCenter.eneg.de (ESXi 6.7) mit Host S2842 wurde entfernt
- k8s-dev-21 (war auf S2842 im alten vCenter) wurde geloescht
- k8s-dev-22 (S2843) und k8s-dev-23 (S3168) liefen noch
- K3s Cluster hatte kein etcd-Quorum mehr (2 von 3 Nodes)

## Entscheidungen

- **Clean Slate:** Alle 3 VMs neu erstellen statt Recovery (sauberer Zustand)
- **Single Provider:** OpenTofu Dual-Provider-Setup entfernt, nur noch vcenter-a.eneg.de
- **K3s Upgrade:** Gleich auf v1.35.1+k3s1 statt v1.35.0+k3s3

## Durchgefuehrte Aenderungen

### OpenTofu
- Dual-Provider-Setup (vcenter_legacy + vcenter_a) entfernt
- Nur noch ein Provider: vcenter-a.eneg.de
- k8s-dev-21 Datastore: S2842_D08-10_R5_SSD_K8s -> S2842_SSD_01_VMS
- Alle 3 VMs im gleichen Datacenter (eNeG-Datacenter)
- VM-Ordner: eNeG-VM-K8s/DEV (bereits vorhanden)

### Packer
- Legacy-Konfiguration (variables-vcenter-legacy.pkrvars.hcl) geloescht
- VM-Version 14 (ESXi 6.7) nicht mehr benoetigt

### Ansible
- Inventory mit Host-Zuordnungen aktualisiert
- K3s Playbook um Rolling Upgrade erweitert (Install vs Upgrade Logik)
- Rolling Upgrade verifiziert: v1.35.1 -> v1.35.0 -> v1.35.1
- System-Wartungs-Playbook erstellt (03-system-maintenance.yml)

### Cluster
- K3s v1.35.1+k3s1 auf allen 3 Nodes
- ArgoCD installiert und Self-Management aktiviert
- admin-ubuntu Passwort geaendert
- Ubuntu Updates eingespielt (24.04.4 LTS)

## Neue VM-Verteilung

| VM | Host | Datastore | IP |
|----|------|-----------|-----|
| k8s-dev-21 | s2842.eneg.de | S2842_SSD_01_VMS | 192.168.180.21 |
| k8s-dev-22 | s2843.eneg.de | S2843_SSD_01_VMS | 192.168.180.22 |
| k8s-dev-23 | s3168.eneg.de | S3168_SSD_01_VMS | 192.168.180.23 |

## Neue Host-Uebersicht (alle in vcenter-a.eneg.de)

| Host-Nr | Host-Name | ESXi Version | Datastore (K8s VMs) |
|---------|-----------|-------------|---------------------|
| HOST1 | s2842.eneg.de | 8.0.3 | S2842_SSD_01_VMS (3.7 TB) |
| HOST2 | s2843.eneg.de | 8.0.3 | S2843_SSD_01_VMS (3.7 TB) |
| HOST3 | s3168.eneg.de | 8.0.3 | S3168_SSD_01_VMS (7.5 TB) |

## Geaenderte Dateien

| Datei | Aenderung |
|-------|-----------|
| terraform/environments/dev/main.tf | Single Provider |
| terraform/environments/dev/variables.tf | Legacy-Variablen entfernt |
| terraform/environments/dev/vms.tf | Alle VMs gleicher Provider |
| terraform/environments/dev/folders.tf | Legacy-Ordner entfernt |
| terraform/environments/dev/outputs.tf | vCenter-Refs entfernt |
| terraform/environments/dev/credentials.example.tfvars | Vereinfacht |
| ansible/inventory/dev/hosts.ini | Host-Kommentare aktualisiert |
| ansible/inventory/dev/group_vars/all.yml | K3s v1.35.1+k3s1 |
| ansible/playbooks/02-install-k3s.yml | Rolling Upgrade Support |
| ansible/playbooks/03-system-maintenance.yml | Neu erstellt |
| packer/ubuntu-24.04/variables-vcenter-legacy.pkrvars.hcl | Geloescht |
| .gitignore | kubeconfig-*.yaml Pattern |

## Wichtige Learnings

- Rolling Upgrade bei K3s: Nur Binary ersetzen + Service restart, KEIN cluster-init
- Bei Erstinstallation: cluster-init fuer Initial Server, --server fuer Additional
- etcd Quorum: Bei 2 von 3 Nodes ist kein Recovery moeglich, Clean Slate noetig
- vSphere Web Console braucht open-vm-tools (war bereits installiert im Template)
- Bash History Expansion: Ausrufezeichen in Passwoertern mit read -s umgehen

## Aktueller Status nach Migration

- 3 Nodes Ready mit K3s v1.35.1+k3s1
- Ubuntu 24.04.4 LTS (aktuell)
- ArgoCD v3.x Synced + Healthy (Self-Management)
- SOPS + Age Secret Management operativ
- Bereit fuer Phase 4 (MetalLB, Traefik, Cert-Manager, Longhorn)
