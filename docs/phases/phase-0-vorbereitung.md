# Phase 0: Vorbereitung & Workstation Setup

**Status:** ✅ Abgeschlossen  
**Zeitraum:** 04.02.2026  
**Bearbeiter:** D. Henke / Claude AI

---

## Ziel

Einrichtung aller Entwicklungsumgebungen und der Management-VM als zentrale Steuerungsinstanz für die Kubernetes-Infrastruktur.

---

## Erreichte Ergebnisse

### Management-VM (k8s-mgmt-10.eneg.de)

| Eigenschaft | Wert |
|-------------|------|
| IP-Adresse | 192.168.180.10 |
| OS | Ubuntu 24.04 LTS |
| vCPU | 4 |
| RAM | 8 GB |
| Disk | 100 GB |
| vCenter | vcenter-a.eneg.de |
| Host | s2843.eneg.de |
| Datastore | S2843_SSD_01_VMS |

### Installierte Tools auf Management-VM

| Tool | Version | Zweck |
|------|---------|-------|
| OpenTofu | 1.11.4 | Infrastructure as Code |
| Ansible | 2.20.2 (core) | Konfigurationsmanagement |
| Packer | 1.15.0 | VM-Template-Erstellung |
| kubectl | 1.35.0 | Kubernetes CLI |
| Helm | 3.20.0 | Kubernetes Package Manager |
| SOPS | 3.11.0 | Secret-Verschlüsselung |
| Age | 1.1.1 | Verschlüsselung für SOPS |
| Git | 2.43.0 | Versionskontrolle |
| govc | (aktuell) | VMware CLI |

### Workstations

| System | Konfiguration |
|--------|---------------|
| Windows Laptop | Git, Node.js, SSH-Key (Ed25519), Desktop Commander MCP, kubectl |
| MacBook | Desktop Commander MCP, Git, allowedDirectories konfiguriert |
| MacMini | Desktop Commander MCP, Git, allowedDirectories konfiguriert |

### GitHub Repository

- **Name:** eneg-k8s-infrastructure-v2
- **Typ:** Privat (Monorepo)
- **URL:** https://github.com/dhenkeeneg/eneg-k8s-infrastructure-v2
- **SSH-Key:** Von Management-VM hinterlegt

---

## Repository-Struktur (initial)

```
eneg-k8s-infrastructure-v2/
├── README.md
├── .gitignore
├── .sops.yaml
├── docs/
│   ├── K8s-GitOps-Infrastruktur-Projektplanung.md
│   ├── phases/
│   ├── architecture/
│   ├── decisions/
│   ├── guides/
│   └── runbooks/
├── packer/
├── terraform/
│   ├── modules/
│   └── environments/
├── ansible/
│   ├── inventory/
│   ├── playbooks/
│   └── roles/
└── kubernetes/
    ├── base/
    └── environments/
```

---

## Netzwerk-Übersicht

| Umgebung | VLAN | Netzwerk | Gateway | Verwendung |
|----------|------|----------|---------|------------|
| DEV | 180 | 192.168.180.0/24 | .247 | Entwicklung |
| TEST | 179 | 192.168.179.0/24 | .247 | Test |
| PROD | 178 | 192.168.178.0/24 | .247 | Produktion |

**DNS-Server:** 192.168.161.101, .102, .103

---

## Learnings

### kubectl Version
Initial wurde das v1.32 Repository verwendet, was zu einer veralteten Version führte. Korrektur: v1.35 Repository verwenden, da Kubernetes 1.32 am 28.02.2026 End-of-Life erreicht.

### Desktop Commander MCP
Ermöglicht direkten Datei- und Terminal-Zugriff auf alle Entwicklungsumgebungen, was die Zusammenarbeit mit Claude AI erheblich vereinfacht.

---

## Änderungshistorie

| Datum | Änderung |
|-------|----------|
| 04.02.2026 | Phase 0 abgeschlossen, Management-VM eingerichtet |
