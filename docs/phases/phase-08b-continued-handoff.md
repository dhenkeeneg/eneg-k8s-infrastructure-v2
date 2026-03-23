# Phase 8b-continued: TEST-Umgebung Apps & PROD-Vorbereitung — Handoff-Dokument

**Erstellt:** 16.03.2026  
**Zweck:** Nahtlose Fortsetzung in einem neuen Chat

---

## Aktueller Stand

### TEST-Cluster: Infrastruktur komplett (Phase 2-4)

Der TEST-Cluster (VLAN 179, 3 Nodes) ist aufgebaut und alle Infrastruktur-Komponenten
laufen. 11 ArgoCD Apps sind Synced + Healthy.

| Komponente | Version | Status |
|---|---|---|
| K3s | v1.35.1+k3s1 | 3 Nodes Ready |
| ArgoCD | v3.3.0 | Synced, KSOPS aktiv |
| MetalLB | v0.15.3 | IP-Pool 192.168.179.151-199 |
| Traefik | v3.6.7 (Chart 39.0.0) | LB-IP 192.168.179.100 |
| Cert-Manager | v1.17.2 | ClusterIssuers Ready |
| Longhorn | v1.9.2 | Storage bereit |

**Dashboards:**
- https://argocd-test.eneg.de (admin / aus argocd-initial-admin-secret)
- https://traefik-test.eneg.de
- https://longhorn-test.eneg.de

### DEV-Cluster: Referenz (Phase 2-6 komplett)

Der DEV-Cluster laeuft mit allen Infrastruktur-Komponenten plus Pilot-Apps:
- n8n, OpenProject 17.1.2, Odoo 18 CE, Keycloak 26.5.4, i-doit Open 37
- Garage S3 (3-Node, Replication Factor 2)
- CloudNativePG (cnpg-shared, cnpg-erp) + MariaDB Galera

---

## Naechste Schritte

### Option A: Pilot-Apps nach TEST promoten

Fuer jede App, die nach TEST promoted werden soll:
1. Kustomize-Overlay in `kubernetes/environments/test/` erstellen (Hostnames, Secrets)
2. ArgoCD App-Definition in `kubernetes/environments/test/infrastructure/` erstellen
3. SOPS-verschluesselte Secrets fuer TEST erstellen (auf k8s-mgmt-10)
4. CNPG/MariaDB Cluster-Definitionen fuer TEST erstellen (falls DB noetig)

**Reihenfolge (wie bei DEV, Sync-Waves beachten):**
1. Datenbank-Operator (CNPG Operator, ggf. MariaDB Operator) — bereits in base
2. Datenbank-Secrets (SOPS-verschluesselt)
3. Datenbank-Cluster (CNPG Cluster-Definition)
4. App-Secrets (SOPS-verschluesselt)
5. App-Deployment

**Apps die noch NICHT refactored sind (base ist DEV-spezifisch):**
- `kubernetes/base/apps/` — Alle Pilot-Apps
- `kubernetes/base/cloudnative-pg/` — CNPG Cluster, Backup-CronJobs
- `kubernetes/base/mariadb-galera/` — MariaDB Cluster, Backup-CronJobs
- `kubernetes/base/garage/` — Garage S3 Cluster

Diese muessen analog zum Phase-8a Kustomize-Overlay Refactoring (ADR-001) auf
generische base + Environment-Overlays umgestellt werden, bevor sie nach TEST
deployed werden koennen.

### Option B: PROD-Cluster aufbauen (Phase 8c)

Der PROD-Cluster kann parallel oder nach der TEST-App-Promotion aufgebaut werden.
Die Infrastruktur-Overlays fuer PROD muessen noch erstellt werden.

**PROD-Werte (aus Projektplanung):**
- VLAN 178, Gateway 192.168.178.247
- Nodes: k8s-prod-21/22/23, IPs: 192.168.178.21-23
- Ressourcen: 8 vCPU, 24 GB RAM, 768 GB Disk pro Node
- Traefik LB-IP: 192.168.178.100, MetalLB Pool: .151-.199
- DNS: traefik-prod.eneg.de (oder Wildcard *.eneg.de)

**Vorbereitung noetig:**
- [ ] VLAN 178 eingerichtet und routbar
- [ ] Port Group "VT 178 - K8s Prod" auf allen ESXi-Hosts
- [ ] vSphere Folder `eNeG-VM-K8s/PROD` (existiert laut Doku bereits)
- [ ] DNS-Eintraege: k8s-prod-21/22/23, traefik-prod, argocd-prod, longhorn-prod
- [ ] Kubernetes Overlays: `kubernetes/environments/prod/{metallb,traefik,longhorn,argocd}/`
- [ ] Bootstrap-Dateien: `kubernetes/bootstrap/prod-argocd-app.yaml`, `prod-infrastructure-app.yaml`

---

## Kritische Learnings aus Phase 8b (fuer PROD beachten)

Vollstaendig dokumentiert in `docs/phases/phase-08b-test-cluster-handoff.md`.
Die wichtigsten Punkte in Kurzform:

1. **SSH-Keys vor Ansible:** `ssh-copy-id` von k8s-mgmt-10 auf alle neuen Nodes
2. **Ansible group_vars:** `inventory/{env}/group_vars/all.yml` mit K3s-Config + SSH-Keys
3. **SOPS Secret-Name:** `sops-age` (nicht `age-key`) im argocd Namespace
4. **ApplicationSet CRD:** Manifest ggf. zweimal anwenden, dann Pod loeschen
5. **ArgoCD Redirect-Loop:** `server.insecure: "true"` in argocd-cmd-params-cm patchen
6. **Bootstrap-Reihenfolge:** Siehe exakte 10-Schritt-Anleitung im Abschlussdokument

---

## PROD-Cluster: Ausfuehrungsplan (Kurzfassung)

Basierend auf den TEST-Erfahrungen, optimierte Reihenfolge fuer PROD:

```bash
# 1. Dateien vorbereiten (via Desktop Commander)
#    - terraform/environments/prod/ (VLAN 178, 8 vCPU, 24GB, 768GB)
#    - ansible/inventory/prod/ (hosts.ini + group_vars/all.yml)
#    - kubernetes/environments/prod/{metallb,traefik,longhorn,argocd}/
#    - kubernetes/environments/prod/infrastructure/ (9 App-Definitionen)
#    - kubernetes/bootstrap/prod-argocd-app.yaml
#    - kubernetes/bootstrap/prod-infrastructure-app.yaml

# 2. Commit + Push

# 3. Auf k8s-mgmt-10:
cd ~/git/eneg-k8s-infrastructure-v2 && git pull

# 4. VMs erstellen
cd terraform/environments/prod
cp ../test/credentials.auto.tfvars .  # Gleicher vCenter
tofu init && tofu plan -var-file="credentials.auto.tfvars"
tofu apply -var-file="credentials.auto.tfvars"

# 5. SSH-Keys verteilen (WICHTIG: vor Ansible!)
ssh-copy-id admin-ubuntu@192.168.178.21
ssh-copy-id admin-ubuntu@192.168.178.22
ssh-copy-id admin-ubuntu@192.168.178.23

# 6. Ansible: K3s installieren
cd ~/git/eneg-k8s-infrastructure-v2
ansible-playbook -i ansible/inventory/prod/hosts.ini ansible/playbooks/01-setup-ssh-keys.yml
ansible-playbook -i ansible/inventory/prod/hosts.ini ansible/playbooks/04-longhorn-prerequisites.yml
ansible-playbook -i ansible/inventory/prod/hosts.ini ansible/playbooks/02-install-k3s.yml

# 7. kubeconfig sichern
ssh admin-ubuntu@192.168.178.21 "sudo cat /etc/rancher/k3s/k3s.yaml" | \
  sed 's/127.0.0.1/192.168.178.21/g' > kubeconfig-prod.yaml
export KUBECONFIG=~/git/eneg-k8s-infrastructure-v2/kubeconfig-prod.yaml

# 8. ArgoCD Bootstrap (exakte Reihenfolge!)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml
kubectl -n argocd rollout status deployment argocd-server --timeout=120s
# Falls applicationset-controller CrashLoop: Manifest nochmal anwenden + Pod loeschen
kubectl create secret generic sops-age -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
kubectl patch deployment argocd-repo-server -n argocd \
  --patch-file kubernetes/base/argocd/argocd-repo-server-ksops-patch.yaml
kubectl -n argocd rollout status deployment argocd-repo-server --timeout=120s
kubectl apply -f <(sops -d kubernetes/base/argocd/secrets/repository-secret.enc.yaml)
kubectl apply -f kubernetes/bootstrap/prod-argocd-app.yaml
kubectl apply -f kubernetes/bootstrap/prod-infrastructure-app.yaml

# 9. Redirect-Loop Fix
kubectl -n argocd patch configmap argocd-cmd-params-cm \
  --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment argocd-server
```

---

## Kontext fuer den neuen Chat

Bitte lies zu Beginn des Chats:
1. `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.8.md` — Gesamtueberblick
2. `docs/phases/phase-08b-continued-handoff.md` — Dieses Dokument
3. `docs/phases/phase-08b-test-cluster-handoff.md` — Abschlussdokument Phase 8b (Learnings)
4. `docs/decisions/ADR-001-kustomize-overlay-pattern.md` — Overlay-Entscheidung

## Wichtige Referenzen

| Dokument | Pfad |
|----------|------|
| Projektplan | `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.8.md` |
| Phase 8b Abschluss | `docs/phases/phase-08b-test-cluster-handoff.md` |
| ADR Kustomize | `docs/decisions/ADR-001-kustomize-overlay-pattern.md` |
| DEV Terraform | `terraform/environments/dev/` |
| TEST Terraform | `terraform/environments/test/` |
| DEV Ansible | `ansible/inventory/dev/` |
| TEST Ansible | `ansible/inventory/test/` |
| DEV Infrastructure Apps | `kubernetes/environments/dev/infrastructure/` |
| TEST Infrastructure Apps | `kubernetes/environments/test/infrastructure/` |
| TEST Bootstrap | `kubernetes/bootstrap/test-argocd-app.yaml` |
| SOPS-Anleitung | `docs/SOPS-SECRET-MANAGEMENT.md` |
| kubeconfig DEV | `kubeconfig-dev.yaml` (auf k8s-mgmt-10) |
| kubeconfig TEST | `kubeconfig-test.yaml` (auf k8s-mgmt-10) |
