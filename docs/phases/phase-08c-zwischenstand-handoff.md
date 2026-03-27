# Phase 8c: PROD Rollout — Zwischenstand-Handoff

**Erstellt:** 27.03.2026
**Status:** In Bearbeitung — Overlay-Erstellung ca. 50% fertig

---

## Was wurde in dieser Session erledigt

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
- `vars_files`: 4x hardcoded `../inventory/dev/group_vars/secrets.yml`
  → geaendert zu `"{{ inventory_dir }}/group_vars/secrets.yml"`
- kubeconfig-Dateiname: hardcoded `kubeconfig-dev.yaml`
  → geaendert zu `kubeconfig-{{ k3s_env_name }}.yaml`
  (k3s_env_name wird aus `inventory_dir | basename` abgeleitet)
- **WICHTIG:** Dieser Fix ist noch NICHT committed!

### Schritt 3: Kubernetes Environment-Overlays 🔄 (ca. 50% fertig)

**DNS-Eintraege bei IONOS: ✅ Angelegt**

| Typ | Eintrag | Ziel |
|-----|---------|------|
| A | traefik-prod.eneg.de | 192.168.178.100 |
| CNAME | argocd-prod.eneg.de | traefik-prod.eneg.de |
| CNAME | longhorn-prod.eneg.de | traefik-prod.eneg.de |
| CNAME | s3-prod.eneg.de | traefik-prod.eneg.de |
| CNAME | s3-gui-prod.eneg.de | traefik-prod.eneg.de |
| CNAME | keycloak.eneg.de | traefik-prod.eneg.de |
| CNAME | openproject.eneg.de | traefik-prod.eneg.de |
| CNAME | odoo.eneg.de | traefik-prod.eneg.de |
| CNAME | n8n.eneg.de | traefik-prod.eneg.de |
| CNAME | idoit.eneg.de | traefik-prod.eneg.de |
| CNAME | it-info-versand.eneg.de | traefik-prod.eneg.de |

DNS-Namenskonvention PROD:
- **User-facing Apps:** Ohne Suffix (openproject.eneg.de, odoo.eneg.de, etc.)
- **Interne Tools:** Mit -prod Suffix (argocd-prod, longhorn-prod, s3-prod, s3-gui-prod)

---

## Erstellte PROD-Overlay-Dateien (Ist-Stand)

### ✅ Infrastruktur-Overlays (komplett)

| Verzeichnis | Dateien | Status |
|-------------|---------|--------|
| `kubernetes/environments/prod/metallb/` | ipaddresspool.yaml, kustomization.yaml, l2advertisement.yaml | ✅ Fertig |
| `kubernetes/environments/prod/traefik/` | certificate.yaml, kustomization.yaml, values-override.yaml | ✅ Fertig |
| `kubernetes/environments/prod/longhorn/` | ingress.yaml | ✅ Fertig |
| `kubernetes/environments/prod/argocd/` | argocd-ingress.yaml, kustomization.yaml | ✅ Fertig |

### ✅ Datenbank-Overlays (komplett)

| Verzeichnis | Dateien | Status |
|-------------|---------|--------|
| `prod/cnpg-cluster/` | cnpg-shared.yaml, cnpg-erp.yaml, scheduled-backup.yaml | ✅ Fertig (Bucket: k8s-prod-postgres-wal) |
| `prod/cnpg-backup/` | configmap-backup-script.yaml, cronjob-shared.yaml, cronjob-erp.yaml | ✅ Fertig (Bucket: k8s-prod-postgres-backup) |
| `prod/cnpg-secrets/` | kustomization.yaml, secret-generator.yaml, 6x .yaml.template | ✅ Templates fertig (Verschluesselung auf k8s-mgmt-10) |
| `prod/mariadb-cluster/` | mariadb-galera.yaml, physical-backup.yaml | ✅ Fertig (Bucket: k8s-prod-mariadb-backup) |
| `prod/mariadb-secrets/` | kustomization.yaml, secret-generator.yaml, 2x .yaml.template | ✅ Templates fertig |

### 🔄 Garage-Overlays (teilweise)

| Verzeichnis | Dateien | Status |
|-------------|---------|--------|
| `prod/garage/` | namespace.yaml, configmap.yaml, services.yaml, ingress.yaml | ✅ Fertig |
| `prod/garage/` | statefulset.yaml | ⚠️ UNVOLLSTAENDIG (29 Zeilen, TEST hat 160) — muss neu erstellt werden |
| `prod/garage/` | webui-deployment.yaml | ❌ Fehlt |
| `prod/garage-secrets/` | — | ❌ Fehlt komplett |
| `prod/garage-backup/` | — | ❌ Fehlt komplett |
| `prod/garage-backup-secrets/` | — | ❌ Fehlt komplett |

### ❌ App-Overlays (fehlen komplett)

Alle 6 App-Overlays muessen noch erstellt werden (kopieren von TEST, Hostnames anpassen):

| App | PROD-Hostname | Status |
|-----|---------------|--------|
| n8n | n8n.eneg.de | ❌ Fehlt |
| keycloak | keycloak.eneg.de | ❌ Fehlt |
| openproject | openproject.eneg.de | ❌ Fehlt |
| odoo | odoo.eneg.de | ❌ Fehlt |
| idoit | idoit.eneg.de | ❌ Fehlt |
| it-info-versand | it-info-versand.eneg.de | ❌ Fehlt |

Jede App braucht: deployment.yaml, ingress.yaml, namespace.yaml, service.yaml + secrets/ Verzeichnis
OpenProject hat zusaetzlich: Hocuspocus, Memcached, Seeder, Worker
Odoo hat zusaetzlich: configmap.yaml, backup/ Verzeichnis (CronJob + Secrets)

### ❌ ArgoCD Infrastructure App-Definitionen (fehlen komplett)

`kubernetes/environments/prod/infrastructure/` — ca. 35 ArgoCD Application-Definitionen
(kopieren von `test/infrastructure/`, Pfade auf `environments/prod/` anpassen)

### ❌ Bootstrap-Dateien (fehlen)

- `kubernetes/bootstrap/prod-argocd-app.yaml`
- `kubernetes/bootstrap/prod-infrastructure-app.yaml`

---

## Vorgehensweise fuer naechsten Chat

### Reihenfolge der verbleibenden Arbeiten

1. **Garage fertigstellen:** statefulset.yaml neu erstellen (von TEST kopieren),
   webui-deployment.yaml, garage-secrets/, garage-backup/, garage-backup-secrets/
2. **App-Overlays erstellen:** Fuer jede der 6 Apps die TEST-Variante kopieren
   und Hostnames anpassen (kein -test Suffix fuer user-facing, -prod fuer interne)
3. **ArgoCD Infrastructure-Definitionen:** Alle ~35 App-Definitionen von TEST kopieren,
   Pfade auf `environments/prod/` anpassen
4. **Bootstrap-Dateien:** prod-argocd-app.yaml + prod-infrastructure-app.yaml
5. **Commit + Push** aller Dateien
6. **Secrets generieren + SOPS-verschluesseln** auf k8s-mgmt-10
7. **ArgoCD Bootstrap** auf PROD-Cluster
8. **Post-Deployment Konfiguration** (Garage Node-IDs, Keycloak, Apps)

### Referenz-Dateien

Alle PROD-Dateien werden als Kopie von TEST erstellt. Hauptunterschiede:

| Parameter | TEST | PROD |
|-----------|------|------|
| VLAN | 179 | 178 |
| Node-IPs | 192.168.179.21-23 | 192.168.178.21-23 |
| Traefik LB | 192.168.179.100 | 192.168.178.100 |
| MetalLB Pool | 192.168.179.151-199 | 192.168.178.151-199 |
| DNS (user-facing) | app-test.eneg.de | app.eneg.de |
| DNS (intern) | argocd-test.eneg.de | argocd-prod.eneg.de |
| S3-Bucket Prefix | k8s-test- | k8s-prod- |
| NAS10 S3-Account | s3-k8s-test | s3-k8s-prod |

### Cluster-Status PROD

```
k8s-prod-21   Ready   control-plane,etcd   v1.35.1+k3s1   192.168.178.21
k8s-prod-22   Ready   control-plane,etcd   v1.35.1+k3s1   192.168.178.22
k8s-prod-23   Ready   control-plane,etcd   v1.35.1+k3s1   192.168.178.23
```

- **kubeconfig:** `~/git/eneg-k8s-infrastructure-v2/kubeconfig-prod.yaml` auf k8s-mgmt-10
- **ArgoCD:** Noch nicht installiert (Bootstrap steht aus)

### Garage ConfigMap Hinweis

Die `prod/garage/configmap.yaml` enthaelt Platzhalter-Node-IDs:
```
PLATZHALTER_NODE_ID_0@garage-0.garage-headless...
PLATZHALTER_NODE_ID_1@garage-1.garage-headless...
PLATZHALTER_NODE_ID_2@garage-2.garage-headless...
```
Diese muessen nach dem ersten Garage-Start mit den echten Node-IDs ersetzt werden:
```bash
kubectl exec -n garage garage-0 -- cat /var/lib/garage/meta/node_key.pub
kubectl exec -n garage garage-1 -- cat /var/lib/garage/meta/node_key.pub
kubectl exec -n garage garage-2 -- cat /var/lib/garage/meta/node_key.pub
```

---

## Noch nicht committed

Folgende Aenderungen sind lokal auf dem Windows-Laptop erstellt aber noch NICHT committed:

```
terraform/environments/prod/           # 7 Dateien (OpenTofu PROD)
ansible/inventory/prod/                # 3 Dateien (Ansible PROD)
ansible/playbooks/02-install-k3s.yml   # Fix: dynamische vars_files + kubeconfig Name
kubernetes/environments/prod/          # ~40 Dateien (Overlays, teilweise)
```

### Empfohlener Commit:

```bash
cd C:\Users\dhenke\git\eneg-k8s-infrastructure-v2
git add terraform/environments/prod/
git add ansible/inventory/prod/
git add ansible/playbooks/02-install-k3s.yml
git add kubernetes/environments/prod/
git add docs/phases/phase-08c-zwischenstand-handoff.md
git commit -m "Phase 8c: PROD cluster deployed + K3s installed + partial overlays (WIP)"
git push
```

---

## Kritische Learnings (diese Session)

1. **Playbook 02 kubeconfig-Bug:** Hardcoded `kubeconfig-dev.yaml` ueberschrieb bei PROD-Install
   die DEV-kubeconfig. Fix: Dynamisch aus Inventory-Pfad ableiten.
2. **Playbook 02 vars_files-Bug:** Hardcoded `../inventory/dev/group_vars/secrets.yml` funktionierte
   fuer PROD nur zufaellig (Ansible liest vars_files relativ zum Playbook, nicht zum Inventory).
   Fix: `"{{ inventory_dir }}/group_vars/secrets.yml"`
3. **kubeconfig Recovery:** Falls ueberschrieben, kann sie vom Cluster geholt werden:
   `ssh admin-ubuntu@<NODE-IP> "sudo cat /etc/rancher/k3s/k3s.yaml" | sed 's/127.0.0.1/<NODE-IP>/g'`
4. **Ansible skipped Tasks sind normal:** Rolling-Upgrade-Tasks werden bei Erstinstallation korrekt
   uebersprungen (failed=0, skipped=7 ist OK).

---

*Erstellt am 27.03.2026. Dieses Dokument dient als Startpunkt fuer den neuen Chat.*
