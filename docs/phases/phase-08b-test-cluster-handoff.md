# Phase 8b: TEST-Cluster Aufbau — Handoff-Dokument

**Erstellt:** 16.03.2026  
**Zuletzt bearbeitet:** 16.03.2026  
**Zweck:** Nahtlose Fortsetzung in einem neuen Chat

---

## Abgeschlossen in Phase 8a (16.03.2026)

### Kustomize-Overlay Refactoring

Die Infrastruktur-Manifeste (Phase 2-4) wurden von DEV-spezifischen base-Manifesten
auf generische base + Environment-Overlays umgestellt. Betrifft:

- **MetalLB:** `kubernetes/environments/{dev,test}/metallb/` — IP-Pools, L2Advertisement
- **Traefik:** `kubernetes/environments/{dev,test}/traefik/` — values-override, Certificate
- **Longhorn:** `kubernetes/environments/{dev,test}/longhorn/` — Dashboard Ingress
- **ArgoCD:** `kubernetes/environments/{dev,test}/argocd/` — URL-Patch, Ingress

ArgoCD App-Definitionen in `kubernetes/environments/dev/infrastructure/` zeigen
jetzt auf Overlay-Pfade. Bootstrap-Dateien fuer TEST sind erstellt.

**Verifiziert:** Alle DEV Apps Synced + Healthy, alle Dashboards erreichbar.

**Dokumentation:**
- Projektplan aktualisiert: `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.4.md` (Version 2.7)
- Entscheidungsdokument: `docs/decisions/ADR-001-kustomize-overlay-pattern.md`

---

## Naechste Schritte: Phase 8b — TEST-Cluster VMs und K3s

### Voraussetzungen (bereits erledigt)
- [x] VLAN 179 eingerichtet und routbar
- [x] vSphere Folder `eNeG-VM-K8s/TEST` existiert
- [x] Port Group fuer VLAN 179 auf allen drei ESXi-Hosts vorhanden
- [x] Kubernetes Overlays fuer TEST vorbereitet (metallb, traefik, longhorn, argocd)
- [x] Bootstrap-Dateien fuer TEST erstellt

### Offene Voraussetzungen
- [ ] DNS-Eintraege anlegen (beim DNS-Admin):
  - `k8s-test-21.eneg.de` -> 192.168.179.21
  - `k8s-test-22.eneg.de` -> 192.168.179.22
  - `k8s-test-23.eneg.de` -> 192.168.179.23
  - `traefik-test.eneg.de` -> 192.168.179.100 (A-Record)
  - `argocd-test.eneg.de` -> traefik-test.eneg.de (CNAME)
  - `longhorn-test.eneg.de` -> traefik-test.eneg.de (CNAME)

### Schritt 1: OpenTofu — TEST-VMs erstellen

Erstelle `terraform/environments/test/` analog zu `terraform/environments/dev/`:
- `main.tf` — Provider-Konfiguration (identisch, gleicher vCenter)
- `variables.tf` — TEST-spezifisch: VLAN 179, 6 vCPU, 16384 MB RAM, 512 GB Disk
- `vms.tf` — k8s-test-21/22/23 auf s2842/s2843/s3168, Folder `eNeG-VM-K8s/TEST`
- `outputs.tf` — VM-Outputs
- `folders.tf` — vSphere Folder
- `credentials.example.tfvars` — Beispiel-Credentials

Ausfuehrung auf k8s-mgmt-10:
```bash
cd ~/git/eneg-k8s-infrastructure-v2/terraform/environments/test
tofu init
tofu plan -var-file="credentials.auto.tfvars"
tofu apply -var-file="credentials.auto.tfvars"
```

### Schritt 2: Ansible — K3s auf TEST installieren

Erstelle `ansible/inventory/test/hosts.ini` analog zu `ansible/inventory/dev/hosts.ini`:
- k8s-test-21 (192.168.179.21) als initial_server
- k8s-test-22, k8s-test-23 als additional_servers

Ausfuehrung auf k8s-mgmt-10:
```bash
cd ~/git/eneg-k8s-infrastructure-v2
ansible-playbook -i ansible/inventory/test/hosts.ini ansible/playbooks/01-setup-ssh-keys.yml
ansible-playbook -i ansible/inventory/test/hosts.ini ansible/playbooks/04-longhorn-prerequisites.yml
ansible-playbook -i ansible/inventory/test/hosts.ini ansible/playbooks/02-install-k3s.yml
```

kubeconfig sichern als `kubeconfig-test.yaml`.

### Schritt 3: ArgoCD auf TEST bootstrappen

Auf k8s-mgmt-10 mit kubeconfig-test:
```bash
export KUBECONFIG=~/git/eneg-k8s-infrastructure-v2/kubeconfig-test.yaml

# 1. ArgoCD installieren (gleiche Version wie DEV: v3.3.0)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml

# 2. SOPS Age Key Secret erstellen
kubectl create secret generic age-key -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt

# 3. KSOPS Patch anwenden (repo-server)
kubectl patch deployment argocd-repo-server -n argocd \
  --patch-file kubernetes/base/argocd/argocd-repo-server-ksops-patch.yaml

# 4. GitHub Deploy Key Secret erstellen
kubectl apply -f <(sops -d kubernetes/base/argocd/secrets/repository-secret.enc.yaml)

# 5. ArgoCD Self-Management bootstrappen
kubectl apply -f kubernetes/bootstrap/test-argocd-app.yaml

# 6. App-of-Apps bootstrappen (deployed alle TEST-Infrastruktur-Apps)
kubectl apply -f kubernetes/bootstrap/test-infrastructure-app.yaml
```

### Schritt 4: TEST ArgoCD App-Definitionen erstellen

Die ArgoCD App-Definitionen fuer TEST muessen in
`kubernetes/environments/test/infrastructure/` erstellt werden.
Fuer Phase 2-4 (Infrastruktur) werden diese Apps benoetigt:

- `metallb-app.yaml` — zeigt auf `kubernetes/environments/test/metallb`
- `traefik-app.yaml` — Multi-Source: base values + test override + test certificate
- `longhorn-app.yaml` — zeigt auf base (values sind generisch)
- `longhorn-ingress-app.yaml` — zeigt auf `kubernetes/environments/test/longhorn`
- `longhorn-storageclass-app.yaml` — zeigt auf base (generisch)
- `cert-manager-app.yaml` — zeigt auf base (generisch)
- `cert-manager-config-app.yaml` — zeigt auf base
- `cert-manager-secrets-app.yaml` — zeigt auf base
- `cert-manager-webhook-ionos-app.yaml` — zeigt auf base

**Hinweis:** Die SOPS-verschluesselten Secrets (cert-manager, ArgoCD repo)
verwenden denselben Age-Key wie DEV. Der Key muss auf dem TEST-Cluster
als Secret `age-key` im `argocd` Namespace existieren.

### Schritt 5: Verifizierung

Nach erfolgreichem Bootstrap:
- [ ] Alle ArgoCD Apps Synced + Healthy
- [ ] MetalLB IP-Pool aktiv (192.168.179.151-199)
- [ ] Traefik erreichbar unter https://traefik-test.eneg.de
- [ ] ArgoCD erreichbar unter https://argocd-test.eneg.de
- [ ] Longhorn erreichbar unter https://longhorn-test.eneg.de
- [ ] Let's Encrypt Zertifikate ausgestellt (alle drei Dashboards)

---

## Wichtige Referenzen

| Dokument | Pfad |
|----------|------|
| Projektplan | `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.4.md` |
| ADR Kustomize | `docs/decisions/ADR-001-kustomize-overlay-pattern.md` |
| DEV Terraform | `terraform/environments/dev/` |
| DEV Ansible | `ansible/inventory/dev/hosts.ini` |
| DEV Bootstrap | `kubernetes/bootstrap/dev-infrastructure-app.yaml` |
| TEST Bootstrap | `kubernetes/bootstrap/test-infrastructure-app.yaml` |
| SOPS-Anleitung | `docs/SOPS-SECRET-MANAGEMENT.md` |

## Kontext fuer den neuen Chat

Bitte lies zu Beginn des Chats:
1. `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.4.md` — Gesamtueberblick
2. `docs/phases/phase-08b-test-cluster-handoff.md` — Dieses Dokument
3. `docs/decisions/ADR-001-kustomize-overlay-pattern.md` — Overlay-Entscheidung
4. `terraform/environments/dev/` — als Vorlage fuer TEST
5. `ansible/inventory/dev/hosts.ini` — als Vorlage fuer TEST
