# Phasen-Übersicht

**Projekt:** eNeG K8s Infrastructure v2  
**Stand:** 06.02.2026

---

## Status-Übersicht

| Phase | Beschreibung | Status | Dokumentation |
|-------|--------------|--------|---------------|
| 0 | Vorbereitung & Workstation Setup | ✅ Abgeschlossen | [phase-0-vorbereitung.md](phase-0-vorbereitung.md) |
| 1 | Ubuntu-Template & VM-Automatisierung | ✅ Abgeschlossen | [phase-1-vm-automatisierung.md](phase-1-vm-automatisierung.md) |
| 2 | K3s DEV-Cluster | ⏳ Nächste | - |
| 3 | GitOps-Fundament (ArgoCD, SOPS, GitHub) | 🔲 Offen | - |
| 4 | Kubernetes-Basis (MetalLB, Traefik, Cert-Manager, Longhorn) | 🔲 Offen | - |
| 5 | Datenbank-Cluster (CloudNativePG, MariaDB Galera) | 🔲 Offen | - |
| 6 | Pilot-Apps (n8n, OpenProject, Odoo) | 🔲 Offen | - |
| 7 | Monitoring-Stack | 🔲 Offen | - |
| 8 | TEST & PROD Rollout | 🔲 Offen | - |
| 9 | Security & Härtung | 🔲 Offen | - |
| 10 | Backup & Dokumentation | 🔲 Offen | - |

---

## Aktueller Stand

**Letzte abgeschlossene Phase:** Phase 1  
**Aktuelle Infrastruktur:**

| Komponente | Status |
|------------|--------|
| Management-VM (k8s-mgmt-10) | ✅ Läuft |
| DEV-VM k8s-dev-21 | ✅ Läuft |
| DEV-VM k8s-dev-22 | ✅ Läuft |
| DEV-VM k8s-dev-23 | ✅ Läuft |
| K3s Cluster | ⏳ Noch nicht installiert |
| TEST-VMs | 🔲 Phase 8 |
| PROD-VMs | 🔲 Phase 8 |

---

## Geschätzte Zeitplanung

| Phase | Geschätzte Dauer |
|-------|------------------|
| 2 | 1-2 Tage |
| 3 | 2-3 Tage |
| 4 | 2-3 Tage |
| 5 | 2-3 Tage |
| 6 | 3-5 Tage |
| 7 | 2-3 Tage |
| 8 | 2-3 Tage |
| 9 | 3-5 Tage |
| 10 | 2-3 Tage |

**Gesamt:** ca. 20-32 Arbeitstage

---

## Wichtige Links

- **GitHub Repository:** https://github.com/dhenkeeneg/eneg-k8s-infrastructure-v2
- **Projektplanung:** [K8s-GitOps-Infrastruktur-Projektplanung.md](../K8s-GitOps-Infrastruktur-Projektplanung.md)
