# Phase 8c: PROD Rollout — Handoff-Dokument

**Erstellt:** 26.03.2026
**Status:** Vorbereitet, noch nicht gestartet

---

## Ausgangslage

Phase 8b-continued ist vollstaendig abgeschlossen. Alle 6 Pilot-Apps laufen auf DEV und TEST
inklusive Post-Deployment-Konfiguration (AD/LDAP, OIDC, SMTP, S3, Backups).

### Projektplanung

- **Aktuelle Version:** `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.10.md`
- **Handoff Phase 8b:** `docs/phases/phase-08b-continued-handoff.md`
- **ADR Overlay-Pattern:** `docs/decisions/ADR-001-kustomize-overlay-pattern.md`

### Arbeitsumgebungen

- **Windows-Laptop:** `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\`
- **MacMini/MacBook:** `/Users/danielhenke/git/eneg-k8s-infrastructure-v2/`
- **k8s-mgmt-10 (192.168.180.10):** `~/git/eneg-k8s-infrastructure-v2/`

### Regeln

- Desktop Commander fuer Dateierstellung/-aenderung
- Keine git commit/push durch Claude — nur Anweisungen
- Keine SSH-Befehle auf Servern durch Claude — nur Anweisungen
- SOPS-Verschluesselung immer auf k8s-mgmt-10
- GitOps-Ansatz: Alle Aenderungen ueber Git, nicht direkt auf Servern

---

## Aktueller Cluster-Status

### DEV-Cluster (VLAN 180, 192.168.180.0/24)

| Komponente | Version | Status |
|------------|---------|--------|
| K3s | v1.35.1+k3s1 | 3 Nodes (.21/.22/.23) |
| ArgoCD | v3.3.0 | https://argocd-dev-v2.eneg.de |
| Traefik | v3.6.7 | LB: 192.168.180.100 |
| Alle Pilot-Apps | - | Synced + Healthy |

### TEST-Cluster (VLAN 179, 192.168.179.0/24)

| Komponente | Version | Status |
|------------|---------|--------|
| K3s | v1.35.1+k3s1 | 3 Nodes (.21/.22/.23) |
| ArgoCD | v3.3.0 | https://argocd-test.eneg.de |
| Traefik | v3.6.7 | LB: 192.168.179.100 |
| Alle Pilot-Apps | - | Synced + Healthy, Post-Deployment konfiguriert |
| Alle Backups | - | Laufen taeglich erfolgreich |

### TEST Apps mit Auth-Status

| App | URL | Auth | Status |
|-----|-----|------|--------|
| OpenProject | https://openproject-test.eneg.de | LDAP (AD direkt) | ✅ inkl. SMTP + S3 |
| Odoo | https://odoo-test.eneg.de | Lokal | ✅ |
| i-doit | https://idoit-test.eneg.de | Lokal | ✅ |
| IT-Info-Versand | https://it-info-versand-test.eneg.de | Keycloak OIDC | ✅ |
| n8n | https://n8n-test.eneg.de | Lokal (CE) | ✅ |
| Keycloak | https://keycloak-test.eneg.de | Admin lokal | ✅ Realm eNeG, AD/LDAP |
| Garage WebUI | https://s3-gui-test.eneg.de | HTTP Basic Auth | ✅ |

---

## PROD-Cluster Zielkonfiguration

### Netzwerk

| Parameter | Wert |
|-----------|------|
| VLAN | 178 |
| Netzwerk | 192.168.178.0/24 |
| Gateway | 192.168.178.247 |
| DNS | 192.168.161.104-106 |
| Node 1 | k8s-prod-21 / 192.168.178.21 |
| Node 2 | k8s-prod-22 / 192.168.178.22 |
| Node 3 | k8s-prod-23 / 192.168.178.23 |
| Traefik LB | 192.168.178.100 |
| MetalLB Pool | 192.168.178.151-199 |

### Ressourcen (pro Node)

| Parameter | Wert |
|-----------|------|
| vCPU | 8 |
| RAM | 24 GB |
| Disk | 768 GB |

### VM-Verteilung auf Hosts

| Host | PROD VM |
|------|---------|
| s2842 (ESXi 8.03) | k8s-prod-21 |
| s2843 (ESXi 8.03) | k8s-prod-22 |
| s3168 (ESXi 8.03) | k8s-prod-23 |

### DNS-Eintraege (bei IONOS anzulegen)

PROD nutzt Wildcard-DNS (anders als DEV/TEST mit Einzel-CNAMEs):

```
traefik-prod.eneg.de      -> 192.168.178.100  (A-Record)
*.eneg.de                 -> 192.168.178.100  (A-Record, Wildcard)
```

Alternativ einzelne Eintraege wie bei TEST, falls Wildcard Konflikte verursacht:

```
argocd-prod.eneg.de       -> traefik-prod.eneg.de  (CNAME)
openproject.eneg.de       -> traefik-prod.eneg.de  (CNAME)
odoo.eneg.de              -> traefik-prod.eneg.de  (CNAME)
keycloak.eneg.de          -> traefik-prod.eneg.de  (CNAME)
n8n.eneg.de               -> traefik-prod.eneg.de  (CNAME)
idoit.eneg.de             -> traefik-prod.eneg.de  (CNAME)
it-info-versand.eneg.de   -> traefik-prod.eneg.de  (CNAME)
s3-gui.eneg.de            -> traefik-prod.eneg.de  (CNAME)
longhorn-prod.eneg.de     -> traefik-prod.eneg.de  (CNAME)
```

---

## Ausfuehrungsplan Phase 8c

### Voraussetzungen (vor Start pruefen)

- [ ] VLAN 178 im Netzwerk konfiguriert und routbar
- [ ] DNS-Eintraege bei IONOS angelegt
- [ ] vSphere Folder fuer PROD erstellt (vCenter-A)
- [ ] S3-Buckets auf NAS10 fuer PROD angelegt:
  - `k8s-prod-postgres-backup`
  - `k8s-prod-mariadb-backup`
  - `k8s-prod-garage-backup`
  - `k8s-prod-odoo-backup`
- [ ] NAS10 S3-Credentials fuer PROD-Buckets (Account: `s3-k8s-prod`)

### Schritt 1: OpenTofu — VMs erstellen

Analog zu `terraform/environments/test/`, neues Verzeichnis `terraform/environments/prod/`:

- 3 VMs: k8s-prod-21/22/23
- 8 vCPU, 24GB RAM, 768GB Disk
- VLAN 178, IPs .21/.22/.23
- VM-Verteilung: je 1 VM pro Host (Anti-Affinity)

```bash
# Auf k8s-mgmt-10:
cd ~/git/eneg-k8s-infrastructure-v2/terraform/environments/prod
tofu init
tofu plan
tofu apply
```

### Schritt 2: Ansible — K3s installieren

Neues Inventory `ansible/inventory/prod/`:

- hosts.yml mit k8s-prod-21/22/23
- group_vars/all.yml mit PROD-spezifischen Werten

```bash
# SSH-Keys verteilen (vor Ansible!)
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.178.21
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.178.22
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.178.23

# K3s installieren
cd ~/git/eneg-k8s-infrastructure-v2
ansible-playbook -i ansible/inventory/prod/hosts.yml ansible/playbooks/k3s-install.yml
```

### Schritt 3: Kubernetes Environment-Overlays erstellen

Neues Verzeichnis `kubernetes/environments/prod/` analog zu test/:

**Infrastruktur-Overlays (kopieren von test, IPs anpassen):**
- `prod/metallb/` — IP-Pool: 192.168.178.151-199
- `prod/traefik/` — LB-IP: 192.168.178.100, Hostnames: *-prod.eneg.de oder *.eneg.de
- `prod/longhorn/` — Dashboard-Ingress: longhorn-prod.eneg.de
- `prod/argocd/` — URL-Patch + Ingress: argocd-prod.eneg.de

**CNPG + MariaDB (kopieren von test, Bucket-Namen anpassen):**
- `prod/cnpg-cluster/` — S3-Bucket: k8s-prod-postgres-backup
- `prod/cnpg-backup/` — S3-Bucket: k8s-prod-postgres-backup
- `prod/cnpg-secrets/` — Neue Secrets generieren + SOPS-verschluesseln
- `prod/mariadb-cluster/` — S3-Bucket: k8s-prod-mariadb-backup
- `prod/mariadb-secrets/` — Neue Secrets generieren + SOPS-verschluesseln

**Garage (kopieren von test):**
- `prod/garage/` — Node-IDs: Platzhalter, nach erstem Start auslesen und eintragen
- `prod/garage-secrets/` — Neue Secrets generieren
- `prod/garage-backup/` — S3-Bucket: k8s-prod-garage-backup
- `prod/garage-backup-secrets/` — NAS10-Credentials fuer PROD

**Apps (kopieren von test, Hostnames anpassen):**
- `prod/apps/n8n/` — n8n.eneg.de
- `prod/apps/keycloak/` — keycloak.eneg.de
- `prod/apps/openproject/` — openproject.eneg.de (inkl. SMTP, S3, LDAP)
- `prod/apps/odoo/` — odoo.eneg.de (inkl. Backup CronJob)
- `prod/apps/idoit/` — idoit.eneg.de
- `prod/apps/it-info-versand/` — it-info-versand.eneg.de

### Schritt 4: ArgoCD Bootstrap

- `kubernetes/bootstrap/prod-argocd-app.yaml` — ArgoCD Self-Management
- `kubernetes/bootstrap/prod-infrastructure-app.yaml` — App-of-Apps

```bash
# Auf k8s-mgmt-10:
KUBECONFIG=~/git/eneg-k8s-infrastructure-v2/kubeconfig-prod.yaml

# SOPS Age Key deployen
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt

# ArgoCD installieren (Manifest-basiert)
kubectl apply -k kubernetes/base/argocd/

# GitHub Deploy Key
kubectl create secret generic github-ssh-key \
  --namespace argocd \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd_deploy_key

# Bootstrap anwenden
kubectl apply -f kubernetes/bootstrap/prod-argocd-app.yaml
kubectl apply -f kubernetes/bootstrap/prod-infrastructure-app.yaml
```

### Schritt 5: Secrets generieren und verschluesseln

Alle Secrets muessen auf k8s-mgmt-10 neu generiert werden (NICHT von TEST kopieren!):

**Wichtig:** DB-Passwoerter nur mit `openssl rand -hex 24` (keine Sonderzeichen!)

Secrets-Liste:
1. `prod/cnpg-secrets/` — 5x DB-Credentials + S3-Credentials
2. `prod/mariadb-secrets/` — MariaDB Root + App-Credentials
3. `prod/garage-secrets/` — RPC, Admin, Metrics Token + WebUI bcrypt Hash
4. `prod/garage-backup-secrets/` — Garage Read-Key + NAS10 Credentials
5. `prod/apps/keycloak/secrets/` — DB-Passwort + Admin-Passwort
6. `prod/apps/n8n/secrets/` — DB-Passwort + Encryption Key
7. `prod/apps/openproject/secrets/` — DB-URL, Secret-Key, S3-Keys, SMTP, Hocuspocus
8. `prod/apps/odoo/secrets/` — DB-Passwort + Admin-Passwort
9. `prod/apps/odoo/backup/secrets/` — NAS10-Credentials
10. `prod/apps/idoit/secrets/` — DB-Passwort + ghcr-pull-secret
11. `prod/apps/it-info-versand/secrets/` — DB-Passwort, Session, OIDC, SMTP, ghcr-pull-secret

### Schritt 6: Post-Deployment Konfiguration

Nach ArgoCD-Sync und alle Pods Running:

**6a. Garage:**
- Node-IDs auslesen und in ConfigMap eintragen (nach erstem Start)
- API Keys erstellen: `openproject-app`, `garage-backup-readonly`
- Buckets erstellen: `openproject-assets`
- WebUI-Passwort sicher dokumentieren

**6b. CNPG / MariaDB:**
- Pruefen ob Cluster healthy: `kubectl get cluster -n databases`
- Pruefen ob Backups laufen: `kubectl get scheduledbackup -n databases`

**6c. OpenProject:**
- DB-Migration manuell starten (beim ersten Start):
  ```
  kubectl run openproject-migrate --image=openproject/openproject:17.1.2-slim \
    -n openproject --rm -it --restart=Never \
    --env="DATABASE_URL=..." -- bash -c "cd /app && bundle exec rails db:migrate"
  ```
- LDAP-Authentifizierung in der Web-UI konfigurieren (wie TEST)
- Admin-Passwort aendern (default: admin/admin)
- S3-Attachments testen (Datei hochladen)
- SMTP testen (Benutzer einladen)

**6d. Odoo:**
- DB-Initialisierung manuell starten:
  ```
  kubectl run odoo-init --image=odoo:18 -n odoo --rm -it --restart=Never \
    --env="..." -- odoo -i base -d odoo --stop-after-init --no-http
  ```

**6e. Keycloak:**
- Realm `eNeG` erstellen (ACHTUNG: case-sensitive!)
- AD/LDAP User Federation konfigurieren (identisch zu TEST)
- Group Mapper: `ad-groups` (Preserve Group Inheritance: Off)
- OIDC-Clients erstellen:
  - `openproject` (wird in CE nicht genutzt, aber vorbereitet)
  - `it-info-versand` — **Group Membership Mapper nicht vergessen!**
    (Token Claim Name: `groups`, Full group path: Off, ID+access+userinfo: On)
- User-Sync ausfuehren

**6f. it-info-versand:**
- OIDC-Client-Secret von Keycloak in Secret eintragen
- Testen: Login via Keycloak, Gruppenpruefung `k8s-it-infoversand`

### Schritt 7: Verifikation

- [ ] Alle ArgoCD Apps Synced + Healthy
- [ ] Alle Pods Running (kein CrashLoopBackOff)
- [ ] SSL-Zertifikate gueltig (Let's Encrypt Prod)
- [ ] Alle App-URLs erreichbar
- [ ] LDAP-Login in OpenProject funktioniert
- [ ] OIDC-Login in it-info-versand funktioniert
- [ ] E-Mail-Versand in OpenProject funktioniert
- [ ] S3-Attachments in OpenProject funktionieren
- [ ] Alle Backup-CronJobs laufen (nach 24h pruefen)
- [ ] Longhorn Storage healthy
- [ ] CNPG Cluster healthy (3 Instanzen, Replication OK)
- [ ] MariaDB Galera healthy (3 Nodes, Synced)

---

## Kritische Learnings (aus DEV + TEST)

1. **DB-Passwoerter:** Nur `openssl rand -hex 24` — Sonderzeichen (/, %, +) brechen DATABASE_URL
2. **ghcr-pull-secret:** auth-Feld ist reiner Base64-String von "username:token", kein Prefix
3. **OpenProject erster Start:** DB-Migrationen manuell anstossen bevor Web-Pod laeuft
4. **Odoo erster Start:** DB-Initialisierung mit `-i base --stop-after-init --no-http`
5. **Keycloak Realm:** `eNeG` ist case-sensitive in allen URLs (`realms/eNeG`, nicht `realms/eneg`)
6. **Keycloak OIDC Group Mapper:** Clients die gruppenbasierte Auth brauchen, benoetigen
   Group Membership Protocol Mapper im dedicated Client Scope
7. **OpenProject CE:** Kein OIDC (Enterprise-only) — LDAP direkt gegen AD verwenden
8. **OpenProject SMTP:** Ueber ENV-Variablen konfigurieren, nicht Web-UI:
   `OPENPROJECT_EMAIL__DELIVERY__METHOD`, `OPENPROJECT_SMTP__ADDRESS`, etc.
9. **Garage Node-IDs:** Nach erstem Start aus `/var/lib/garage/meta/node_key.pub` auslesen
   und im Format `node_id@hostname:port` in ConfigMap `bootstrap_peers` eintragen
10. **Garage WebUI:** bcrypt-Hash im Secret, Klartext-Passwort sicher in 1Password speichern
11. **SSH-Keys:** Muessen vor Ansible via `ssh-copy-id` verteilt werden
12. **ArgoCD v3.3.0:** ApplicationSet CRD Annotation-Limit, Manifest ggf. zweimal anwenden
13. **ArgoCD hinter Traefik:** `server.insecure: "true"` in argocd-cmd-params-cm noetig
14. **SOPS Secret-Name:** `sops-age` (nicht `age-key`)
15. **Garage DNS-Problem:** Minimales Rust-Image hat keine DNS-Aufloesung —
    Init-Container (busybox) loest Hostnames auf und schreibt in shared emptyDir

---

## SOPS-Konfiguration

- **Age Key:** `age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm`
- **Verschluesselung immer auf k8s-mgmt-10**
- **Regex:** `--encrypted-regex '^(data|stringData)$'`
- **.sops.yaml:** Bereits Regeln fuer `environments/*/apps/*/secrets/` vorhanden

---

## Referenz-Dateien fuer PROD-Erstellung

Alle PROD-Dateien werden als Kopie von TEST erstellt mit angepassten Werten.
Hauptunterschiede TEST -> PROD:

| Parameter | TEST | PROD |
|-----------|------|------|
| VLAN | 179 | 178 |
| Node-IPs | 192.168.179.21-23 | 192.168.178.21-23 |
| Traefik LB | 192.168.179.100 | 192.168.178.100 |
| MetalLB Pool | 192.168.179.151-199 | 192.168.178.151-199 |
| DNS-Suffix | -test.eneg.de | .eneg.de (oder -prod.eneg.de) |
| vCPU/Node | 6 | 8 |
| RAM/Node | 16 GB | 24 GB |
| Disk/Node | 512 GB | 768 GB |
| S3-Bucket Prefix | k8s-test- | k8s-prod- |

---

## Backup-Uebersicht (TEST als Referenz, PROD identisch)

| Backup | Schedule | Ziel | Retention |
|--------|----------|------|-----------|
| CNPG Physical (Barman) shared | 02:00 UTC | NAS10 S3 | 30 Tage |
| CNPG Physical (Barman) erp | 02:15 UTC | NAS10 S3 | 30 Tage |
| CNPG Logical (pg_dump) shared | 03:00 UTC | NAS10 S3 | 32 Tage |
| CNPG Logical (pg_dump) erp | 03:15 UTC | NAS10 S3 | 32 Tage |
| MariaDB Physical | 02:30 UTC | NAS10 S3 | 7 Tage (168h) |
| Garage -> NAS10 (rclone) | 04:00 CET | NAS10 S3 | 32 Tage |
| Odoo Filestore -> NAS10 | 05:00 CET | NAS10 S3 | 32 Tage |

---

*Erstellt am 26.03.2026. Dieses Dokument dient als Startpunkt fuer den neuen Chat.*
