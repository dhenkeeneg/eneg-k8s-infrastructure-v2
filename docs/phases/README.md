# Phasen-Übersicht

**Projekt:** eNeG K8s Infrastructure v2  
**Stand:** 18.02.2026

---

## Status-Übersicht

| Phase | Beschreibung | Status | Dokumentation |
|-------|--------------|--------|---------------|
| 0 | Vorbereitung & Workstation Setup | ✅ Abgeschlossen | [phase-0-vorbereitung.md](phase-0-vorbereitung.md) |
| 1 | Ubuntu-Template & VM-Automatisierung | ✅ Abgeschlossen | [phase-1-vm-automatisierung.md](phase-1-vm-automatisierung.md) |
| 2 | K3s DEV-Cluster | ✅ Abgeschlossen | [phase-02-abschluss.md](phase-02-abschluss.md) |
| 3 | GitOps-Fundament (ArgoCD, SOPS, GitHub) | ✅ Abgeschlossen | [phase-03-abschluss.md](phase-03-abschluss.md) / [phase-03b-abschluss.md](phase-03b-abschluss.md) |
| 4 | Kubernetes-Basis (MetalLB, Traefik, Cert-Manager, Longhorn) | ✅ Abgeschlossen | [phase-04-abschluss.md](phase-04-abschluss.md) |
| 5 | Datenbank-Cluster (CloudNativePG, MariaDB Galera) | ⏳ Nächste | - |
| 6 | Pilot-Apps (n8n, OpenProject, Odoo) | 🔲 Offen | - |
| 7 | Monitoring-Stack | 🔲 Offen | - |
| 8 | TEST & PROD Rollout | 🔲 Offen | - |
| 9 | Security & Härtung | 🔲 Offen | - |
| 10 | Backup & Dokumentation | 🔲 Offen | - |

---

## Aktueller Stand (18.02.2026)

**Letzte abgeschlossene Phase:** Phase 4  
**Aktuelle Infrastruktur:**

| Komponente | Version | Status |
|------------|---------|--------|
| Management-VM (k8s-mgmt-10) | Ubuntu 24.04 | ✅ Läuft |
| DEV-VM k8s-dev-21 | Ubuntu 24.04, 384GB | ✅ Läuft |
| DEV-VM k8s-dev-22 | Ubuntu 24.04, 384GB | ✅ Läuft |
| DEV-VM k8s-dev-23 | Ubuntu 24.04, 384GB | ✅ Läuft |
| K3s Cluster | v1.35.1+k3s1 | ✅ Läuft (3-Node HA) |
| ArgoCD | v3.3.0 | ✅ Synced + Healthy |
| MetalLB | v0.15.3 | ✅ Synced + Healthy |
| Traefik | v3.6.7 | ✅ Synced + Healthy |
| Cert-Manager | v1.17.2 | ✅ Synced + Healthy |
| IONOS Webhook | latest | ✅ Synced + Healthy |
| Longhorn | v1.9.2 | ✅ Synced + Healthy |
| Ubuntu Template | 24.04.4 | ✅ Aktualisiert (s3168) |
| TEST-VMs | - | 🔲 Phase 8 |
| PROD-VMs | - | 🔲 Phase 8 |

---

## Wichtige Links

- **GitHub Repository:** https://github.com/dhenkeeneg/eneg-k8s-infrastructure-v2
- **ArgoCD:** https://argocd-dev-v2.eneg.de
- **Longhorn Dashboard:** https://longhorn-dev-v2.eneg.de
- **Traefik Dashboard:** https://traefik-dev.eneg.de
- **Projektplanung:** [K8s-GitOps-Infrastruktur-Projektplanung.md](../K8s-GitOps-Infrastruktur-Projektplanung.md)
