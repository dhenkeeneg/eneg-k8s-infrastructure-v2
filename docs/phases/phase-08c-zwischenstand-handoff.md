# Phase 8c: PROD Rollout — Zwischenstand-Handoff (Update 2)

**Erstellt:** 27.03.2026
**Letztes Update:** 27.03.2026 (Session 2)
**Status:** In Bearbeitung — Overlay-Erstellung ca. 70% fertig

---

## Was wurde in Session 1 erledigt (vorheriger Chat)

### Schritt 1: OpenTofu PROD VMs ✅

- `terraform/environments/prod/` komplett erstellt (7 Dateien)
- 3 VMs: k8s-prod-21/22/23 auf VLAN 178
- 8 vCPU, 24GB RAM, 768GB Disk pro Node
- Port Group: "VT 178 - K8s Prod"
- VMs erfolgreich deployed via `tofu apply` auf k8s-mgmt-10

### Schritt 2: Ansible + K3s Installation ✅

- `ansible/inventory/prod/` erstellt (hosts.ini, group_vars/all.yml, secrets.example.yml)
- K3s v1.35.1+k3s1 erfolgreich installiert (alle 3 Nodes Ready)
- kubeconfig-prod.yaml erstellt und verifiziert

**Playbook-Fix angewendet (02-install-k3s.yml):**
- `vars_files`: dynamisch via `"{{ inventory_dir }}/group_vars/secrets.yml"`
- kubeconfig-Dateiname: dynamisch via `kubeconfig-{{ k3s_env_name }}.yaml`
- **WICHTIG:** Dieser Fix ist noch NICHT committed!

### Schritt 3 (Session 1): Infrastruktur + DB Overlays ✅

- Infrastruktur-Overlays komplett (MetalLB, Traefik, Longhorn, ArgoCD)
- Datenbank-Overlays komplett (CNPG Cluster/Backup/Secrets, MariaDB Cluster/Secrets)
- Garage teilweise (Namespace, ConfigMap, Services, Ingress fertig — StatefulSet war unvollstaendig)
- DNS-Eintraege bei IONOS angelegt

---

## Was wurde in Session 2 erledigt (dieser Chat)

### Garage fertiggestellt ✅

| Verzeichnis | Dateien | Status |
|-------------|---------|--------|
| `prod/garage/` | statefulset.yaml (komplett neu, 160+ Zeilen), webui-deployment.yaml (inkl. Service) | ✅ Fertig |
| `prod/garage-secrets/` | kustomization.yaml, secret-generator.yaml, garage-secrets.yaml.template | ✅ Neu erstellt |
| `prod/garage-backup/` | cronjob.yaml (ConfigMap + CronJob, Bucket: k8s-prod-garage-backup) | ✅ Neu erstellt |
| `prod/garage-backup-secrets/` | kustomization.yaml, secret-generator.yaml, garage-backup-credentials.yaml.template | ✅ Neu erstellt |

### App-Overlays (3 von 6 fertig) ✅

| App | Dateien | Hostname | Status |
|-----|---------|----------|--------|
| n8n | namespace, deployment, ingress, service, secrets/ (kustomization + secret-generator) | n8n.eneg.de | ✅ Fertig |
| Keycloak | namespace, deployment, ingress, service, secrets/ (kustomization + secret-generator) | keycloak.eneg.de | ✅ Fertig |
| i-doit | namespace, deployment, ingress, service, pvc, secrets/ (kustomization + secret-generator) | idoit.eneg.de | ✅ Fertig |

---

## Was noch fehlt (naechster Chat)

### App-Overlays (3 verbleibend) ❌

| App | PROD-Hostname | Besonderheiten | Status |
|-----|---------------|----------------|--------|
