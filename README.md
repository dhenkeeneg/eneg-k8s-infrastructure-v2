# eNeG K8s Infrastructure v2

GitOps-basierte Kubernetes-Infrastruktur auf VMware vSphere mit K3s.

## 🎯 Projektziel

Aufbau einer vollständig automatisierten, GitOps-basierten Kubernetes-Infrastruktur mit drei Umgebungen (DEV, TEST, PROD) auf VMware vSphere.

## 🏗️ Architektur

```
┌─────────────────────────────────────────────────────────────────┐
│                      Management-VM                               │
│  Ubuntu 24.04 │ OpenTofu │ Ansible │ kubectl │ SOPS/Age        │
└─────────────────────────────────────────────────────────────────┘
                                │
          ┌─────────────────────┼─────────────────────┐
          ▼                     ▼                     ▼
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│   DEV Cluster   │   │  TEST Cluster   │   │  PROD Cluster   │
│   K3s HA (3)    │   │   K3s HA (3)    │   │   K3s HA (3)    │
│   VLAN 180      │   │   VLAN 179      │   │   VLAN 178      │
└─────────────────┘   └─────────────────┘   └─────────────────┘
```

## 📋 Technologie-Stack

| Bereich | Technologie |
|---------|-------------|
| Kubernetes | K3s HA-Cluster (3 Nodes) |
| OS | Ubuntu 24.04 LTS |
| IaC | OpenTofu 1.11, Ansible 2.20, Packer |
| GitOps | ArgoCD, Kustomize, SOPS + Age |
| Ingress | Traefik + MetalLB |
| Storage | Longhorn |
| Datenbanken | CloudNativePG (PostgreSQL), MariaDB Galera |
| Monitoring | Prometheus, Grafana, Loki, AlertManager |

## 📁 Verzeichnisstruktur

```
eneg-k8s-infrastructure-v2/
├── docs/                    # Dokumentation
├── terraform/               # OpenTofu für VM-Provisioning
├── ansible/                 # Ansible für Konfiguration
├── packer/                  # VM-Templates
└── kubernetes/              # Kubernetes Manifests
    ├── base/                # Gemeinsame Basis
    └── environments/        # DEV/TEST/PROD Overlays
```

## 🚀 Implementierungsphasen

| Phase | Beschreibung | Status |
|-------|--------------|--------|
| 0 | Vorbereitung & Workstation Setup | 🔄 In Arbeit |
| 1 | Ubuntu-Template & VM-Automatisierung | ⏸️ Geplant |
| 2 | K3s DEV-Cluster | ⏸️ Geplant |
| 3 | GitOps-Fundament | ⏸️ Geplant |
| 4 | Kubernetes-Basis | ⏸️ Geplant |
| 5 | Datenbank-Cluster | ⏸️ Geplant |
| 6 | Pilot-Apps | ⏸️ Geplant |
| 7 | Monitoring-Stack | ⏸️ Geplant |
| 8 | TEST & PROD Rollout | ⏸️ Geplant |
| 9 | Security & Härtung | ⏸️ Geplant |
| 10 | Backup & Dokumentation | ⏸️ Geplant |

## 📚 Dokumentation

- [Projektplanung](docs/K8s-GitOps-Infrastruktur-Projektplanung.md)
- [Architektur](docs/architecture/)
- [Runbooks](docs/runbooks/)
- [Entscheidungen (ADRs)](docs/decisions/)

## 👤 Maintainer

- Daniel Henke

---

**Erstellt:** Februar 2026
