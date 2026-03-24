# Phase 8b: TEST-Cluster Aufbau — Abschlussdokument

**Erstellt:** 16.03.2026  
**Abgeschlossen:** 16.03.2026  
**Zweck:** Dokumentation des TEST-Cluster Aufbaus

---

## Ergebnis

Der TEST-Cluster (VLAN 179) ist vollstaendig aufgebaut und betriebsbereit.
Alle Infrastruktur-Komponenten (Phase 2-4) laufen identisch zum DEV-Cluster.

### Cluster-Uebersicht

| Node | IP | Host | Datastore | Status |
|------|-----|------|-----------|--------|
| k8s-test-21 | 192.168.179.21 | s2842.eneg.de | S2842_SSD_01_VMS | Ready |
| k8s-test-22 | 192.168.179.22 | s2843.eneg.de | S2843_SSD_01_VMS | Ready |
| k8s-test-23 | 192.168.179.23 | s3168.eneg.de | S3168_SSD_01_VMS | Ready |

**Ressourcen pro Node:** 6 vCPU, 16 GB RAM, 512 GB Disk
**K3s Version:** v1.35.1+k3s1
**kubeconfig:** `kubeconfig-test.yaml` auf k8s-mgmt-10

### ArgoCD Applications (11/11 Synced + Healthy)

| Application | Sync | Health | Quelle |
|---|---|---|---|
| argocd | Synced | Healthy | environments/test/argocd (Overlay) |
| test-infrastructure | Synced | Healthy | environments/test/infrastructure (App-of-Apps) |
| metallb | Synced | Healthy | environments/test/metallb (Overlay) |
| traefik | Synced | Healthy | Multi-Source: base + test override |
| cert-manager | Synced | Healthy | base (Helm) |
| cert-manager-config | Synced | Healthy | base (ClusterIssuers) |
| cert-manager-secrets | Synced | Healthy | base (KSOPS) |
| cert-manager-webhook-ionos | Synced | Healthy | Helm Chart |
| longhorn | Synced | Healthy | base (Helm) |
| longhorn-ingress | Synced | Healthy | environments/test/longhorn (Overlay) |
| longhorn-storageclass | Synced | Healthy | base (StorageClass) |

### Dashboards und Zertifikate

| Dashboard | URL | Zertifikat |
|---|---|---|
| ArgoCD | https://argocd-test.eneg.de | Ready (letsencrypt-prod) |
| Traefik | https://traefik-test.eneg.de | Ready (letsencrypt-prod) |
| Longhorn | https://longhorn-test.eneg.de | Ready (letsencrypt-prod) |

---

## Durchgefuehrte Schritte

### Schritt 1: OpenTofu — VMs erstellt
- `terraform/environments/test/` erstellt (main.tf, variables.tf, vms.tf, outputs.tf, folders.tf)
- 3 VMs deployed: k8s-test-21/22/23 auf s2842/s2843/s3168
- Folder: eNeG-VM-K8s/TEST, VLAN 179

### Schritt 2: Ansible — K3s installiert
- `ansible/inventory/test/hosts.ini` erstellt
- `ansible/inventory/test/group_vars/all.yml` erstellt (K3s-Config, SSH-Keys, TLS SANs)
- Playbooks ausgefuehrt: 01-setup-ssh-keys, 04-longhorn-prerequisites, 02-install-k3s
- K3s v1.35.1+k3s1 HA-Cluster mit embedded etcd

### Schritt 3: ArgoCD Bootstrap
- ArgoCD v3.3.0 installiert (Manifest-basiert)
- SOPS Age Key Secret (`sops-age`) im argocd Namespace erstellt
- KSOPS Patch auf repo-server angewendet
- GitHub Deploy Key Secret erstellt (SOPS-entschluesselt)
- ArgoCD Self-Management + App-of-Apps bootstrapped

### Schritt 4: Infrastruktur-Apps
- 9 ArgoCD App-Definitionen in `kubernetes/environments/test/infrastructure/` erstellt
- Alle Apps automatisch gesynced und healthy

---

## Kritische Learnings (fuer PROD-Rollout beachten)

### 1. SSH-Key Verteilung vor Ansible
Das Packer-Template enthaelt keinen SSH-Key — nur Passwort-Login. Ansible Playbook
`01-setup-ssh-keys.yml` benoetigt aber Key-basierte Authentifizierung. Loesung:
**Vor** dem ersten Ansible-Lauf muss `ssh-copy-id` manuell von k8s-mgmt-10 ausgefuehrt werden:
```bash
ssh-copy-id admin-ubuntu@<ip-node-1>
ssh-copy-id admin-ubuntu@<ip-node-2>
ssh-copy-id admin-ubuntu@<ip-node-3>
```
**Empfehlung fuer Zukunft:** SSH Public Key von k8s-mgmt-10 im Packer-Template hinterlegen
(in `user-data.pkrtpl.hcl` unter `late-commands` oder als `ssh_authorized_keys` in cloud-init).

### 2. Ansible group_vars muessen pro Environment existieren
Das Ansible Inventory braucht nicht nur `hosts.ini`, sondern auch `group_vars/all.yml` mit:
- `k3s_version`, `k3s_server_url`, `k3s_tls_san` (environment-spezifische IPs/Hostnames)
- `k3s_disable` (traefik, servicelb, local-storage)
- `ssh_authorized_keys` (alle SSH-Keys: mgmt, Windows, Mac)
- `system_timezone`, `system_locale`

Ohne `group_vars/all.yml` schlaegt Playbook 01 mit `'ssh_authorized_keys' is undefined` fehl.

### 3. SOPS Secret-Name: `sops-age` (nicht `age-key`)
Der KSOPS-Patch (`argocd-repo-server-ksops-patch.yaml`) referenziert ein Secret namens
**`sops-age`** (nicht `age-key`). Bei der manuellen Secret-Erstellung muss dieser Name
verwendet werden:
```bash
kubectl create secret generic sops-age -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
```

### 4. ApplicationSet CRD zu gross fuer Annotation
Bei ArgoCD v3.3.0 ist die `ApplicationSet` CRD zu gross fuer die Standard-Annotation
`kubectl.kubernetes.io/last-applied-configuration` (262144 Byte Limit). Das fuehrt dazu,
dass die CRD nicht korrekt installiert wird und der `applicationset-controller` in
CrashLoopBackOff geraet mit dem Fehler:
`no matches for kind "ApplicationSet" in version "argoproj.io/v1alpha1"`

**Loesung:** Manifest nochmal anwenden (`kubectl apply -f install.yaml`), dann den
applicationset-controller Pod loeschen — Kubernetes erstellt einen neuen Pod, der dann
die CRD findet. Der Fehler bei der CRD-Installation kann ignoriert werden, da die CRD
trotzdem registriert wird (nur die Annotation fehlt).

### 5. ArgoCD `server.insecure` fuer TLS-Terminierung durch Traefik
Wenn Traefik TLS terminiert und ArgoCD hinter Traefik laeuft, muss in der ConfigMap
`argocd-cmd-params-cm` der Parameter `server.insecure: "true"` gesetzt werden.
Ohne diesen Parameter entsteht eine Redirect-Schleife (ERR_TOO_MANY_REDIRECTS),
weil ArgoCD selbst versucht, auf HTTPS zu redirecten.

```bash
kubectl -n argocd patch configmap argocd-cmd-params-cm \
  --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment argocd-server
```

**Hinweis:** Die ArgoCD Self-Management App korrigiert dies spaeter automatisch ueber
die base ConfigMap (`kubernetes/base/argocd/argocd-cmd-params-cm.yaml`), sobald der
erste Sync laeuft. Das manuelle Patchen ist nur fuer den initialen Bootstrap noetig.

### 6. ArgoCD Bootstrap-Reihenfolge (exakt)
Die korrekte Reihenfolge fuer den ArgoCD Bootstrap auf einem neuen Cluster:
1. `kubectl create namespace argocd`
2. `kubectl apply -n argocd -f .../install.yaml` (CRDs + Deployments)
3. Warten: `kubectl -n argocd rollout status deployment argocd-server`
4. Secret erstellen: `sops-age` (Age Key fuer KSOPS)
5. KSOPS Patch: `kubectl patch deployment argocd-repo-server -n argocd --patch-file ...`
6. Warten: `kubectl -n argocd rollout status deployment argocd-repo-server`
7. Deploy Key: `kubectl apply -f <(sops -d .../repository-secret.enc.yaml)`
8. Self-Management: `kubectl apply -f kubernetes/bootstrap/{env}-argocd-app.yaml`
9. App-of-Apps: `kubectl apply -f kubernetes/bootstrap/{env}-infrastructure-app.yaml`
10. Fix: `server.insecure: "true"` in argocd-cmd-params-cm (falls Redirect-Loop)

### 7. LVM-Partition nicht automatisch erweitert nach vSphere Clone
Das Packer-Template erstellt VMs mit LVM-Layout und ~47 GB Root-Partition (Template-Groesse).
Wenn vSphere die Disk beim Clone vergroessert (z.B. auf 512 GB), wird die LVM-Partition
**nicht automatisch** auf die volle Disk-Groesse erweitert, obwohl `cloud-initramfs-growroot`
und `growpart`/`resize_rootfs` in der cloud-init User-Data konfiguriert sind.

**Symptom:** Longhorn meldet `disks are unavailable; precheck new replica failed` weil nur
~49 GB statt 512 GB zur Verfuegung stehen. `df -h /` zeigt ~47 GB.

**Manuelle Loesung (fuer bestehende Nodes):**
```bash
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

**Permanenter Fix (im Packer-Template):**
Ein systemd-Service `extend-lvm.service` wurde hinzugefuegt, der beim ersten Boot nach dem
Clone automatisch Partition, PV, LV und Filesystem auf die volle Disk erweitert. Der Service
nutzt ein Marker-File (`/etc/.extend-lvm-marker`), damit er nur einmal ausgefuehrt wird.
Datei: `packer/ubuntu-24.04/http/user-data.pkrtpl.hcl`

**PROD-Hinweis:** Dieser Fix ist erst im naechsten Template-Build wirksam. Fuer PROD-Nodes
muss entweder ein neues Template gebaut werden oder die manuelle Loesung nach dem Clone
angewendet werden (in Ansible Playbook integrieren).

---

## Erstellte/Geaenderte Dateien

### Neu erstellt
- `terraform/environments/test/main.tf`
- `terraform/environments/test/variables.tf`
- `terraform/environments/test/vms.tf`
- `terraform/environments/test/outputs.tf`
- `terraform/environments/test/folders.tf`
- `terraform/environments/test/credentials.example.tfvars`
- `terraform/environments/test/README.md`
- `ansible/inventory/test/hosts.ini`
- `ansible/inventory/test/group_vars/all.yml`
- `ansible/inventory/test/group_vars/secrets.example.yml`
- `kubernetes/environments/test/infrastructure/metallb-app.yaml`
- `kubernetes/environments/test/infrastructure/traefik-app.yaml`
- `kubernetes/environments/test/infrastructure/longhorn-app.yaml`
- `kubernetes/environments/test/infrastructure/longhorn-ingress-app.yaml`
- `kubernetes/environments/test/infrastructure/longhorn-storageclass-app.yaml`
- `kubernetes/environments/test/infrastructure/cert-manager-app.yaml`
- `kubernetes/environments/test/infrastructure/cert-manager-config-app.yaml`
- `kubernetes/environments/test/infrastructure/cert-manager-secrets-app.yaml`
- `kubernetes/environments/test/infrastructure/cert-manager-webhook-ionos-app.yaml`
