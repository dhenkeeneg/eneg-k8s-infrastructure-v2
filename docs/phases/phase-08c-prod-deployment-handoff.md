# Phase 8c: PROD Rollout — Handoff-Dokument (Abschluss Deployment)

**Erstellt:** 29.03.2026
**Aktualisiert:** 30.03.2026
**Status:** ✅ ABGESCHLOSSEN (inkl. Post-Deployment-Konfiguration)

---

## Was wurde in dieser Session erledigt

### Overlay-Erstellung (komplett)

Alle fehlenden PROD-Overlay-Dateien wurden erstellt:

**Garage (4 Verzeichnisse):**
- `prod/garage/statefulset.yaml` — neu erstellt (komplett, 160 Zeilen)
- `prod/garage/webui-deployment.yaml` — neu erstellt
- `prod/garage-secrets/` — kustomization, secret-generator, template
- `prod/garage-backup/cronjob.yaml` — Bucket: `k8s-prod-garage-backup`
- `prod/garage-backup-secrets/` — kustomization, secret-generator, template

**6 App-Overlays:**
- `prod/apps/n8n/` — 5 Dateien + secrets/ (n8n.eneg.de)
- `prod/apps/keycloak/` — 4 Dateien + secrets/ (keycloak.eneg.de)
- `prod/apps/idoit/` — 5 Dateien + secrets/ (idoit.eneg.de)
- `prod/apps/it-info-versand/` — 4 Dateien + secrets/ (it-info-versand.eneg.de)
- `prod/apps/openproject/` — 4 Dateien + secrets/ (openproject.eneg.de)
- `prod/apps/odoo/` — 5 Dateien + secrets/ + backup/ + backup/secrets/ (odoo.eneg.de)

**ArgoCD Infrastructure (37 App-Definitionen):**
- `prod/infrastructure/*.yaml` — per PowerShell-Script kopiert und Pfade angepasst

**Bootstrap (2 Dateien):**
- `kubernetes/bootstrap/prod-argocd-app.yaml`
- `kubernetes/bootstrap/prod-infrastructure-app.yaml`

### Secrets (18 von 19 erstellt)

Alle Secrets auf k8s-mgmt-10 generiert und SOPS-verschluesselt:

| # | Secret | Verzeichnis | Status |
|---|--------|-------------|--------|
| 1 | CNPG S3-Credentials | `prod/cnpg-secrets/s3-credentials.enc.yaml` | ✅ |
| 2 | n8n DB-Credentials | `prod/cnpg-secrets/n8n-db-credentials.enc.yaml` | ✅ |
| 3 | OpenProject DB-Credentials | `prod/cnpg-secrets/openproject-db-credentials.enc.yaml` | ✅ |
| 4 | Odoo DB-Credentials | `prod/cnpg-secrets/odoo-db-credentials.enc.yaml` | ✅ |
| 5 | Keycloak DB-Credentials | `prod/cnpg-secrets/keycloak-db-credentials.enc.yaml` | ✅ |
| 6 | IT-Info-Versand DB-Credentials | `prod/cnpg-secrets/it-info-versand-db-credentials.enc.yaml` | ✅ |
| 7 | MariaDB Root + S3 | `prod/mariadb-secrets/mariadb-credentials.enc.yaml` | ✅ |
| 8 | MariaDB i-doit DB | `prod/mariadb-secrets/idoit-db-credentials.enc.yaml` | ✅ |
| 9 | Garage Secrets | `prod/garage-secrets/garage-secrets.enc.yaml` | ✅ |
| 10 | n8n App-Secrets | `prod/apps/n8n/secrets/n8n-secrets.enc.yaml` | ✅ |
| 11 | Keycloak App-Secrets | `prod/apps/keycloak/secrets/keycloak-secrets.enc.yaml` | ✅ |
| 12 | i-doit App-Secrets | `prod/apps/idoit/secrets/idoit-secrets.enc.yaml` | ✅ |
| 13 | i-doit ghcr-pull-secret | `prod/apps/idoit/secrets/ghcr-pull-secret.enc.yaml` | ✅ |
| 14 | OpenProject App-Secrets | `prod/apps/openproject/secrets/openproject-secrets.enc.yaml` | ✅ (Platzhalter: S3-Keys, OIDC) |
| 15 | Odoo App-Secrets | `prod/apps/odoo/secrets/odoo-secrets.enc.yaml` | ✅ |
| 16 | Odoo Backup Credentials | `prod/apps/odoo/backup/secrets/odoo-backup-credentials.enc.yaml` | ✅ |
| 17 | IT-Info-Versand App-Secrets | `prod/apps/it-info-versand/secrets/it-info-versand-secrets.enc.yaml` | ✅ (Platzhalter: Keycloak OIDC) |
| 18 | IT-Info-Versand ghcr-pull-secret | `prod/apps/it-info-versand/secrets/ghcr-pull-secret.enc.yaml` | ✅ |
| 19 | Garage Backup Credentials | `prod/garage-backup-secrets/garage-backup-credentials.enc.yaml` | ❌ Nach Garage API Key-Erstellung |

### ArgoCD Bootstrap + Cluster-Deployment

- ArgoCD v3.3.0 installiert via Remote-Manifest (`--server-side --force-conflicts`)
- KSOPS Patch auf repo-server angewendet
- `server.insecure: "true"` fuer Traefik gesetzt
- SOPS Age Key Secret (`sops-age`) erstellt
- GitHub Repository Secret manuell erstellt (SSH Deploy Key `~/.ssh/argocd-deploy-key`)
- Bootstrap Apps angewendet (`prod-argocd-app.yaml` + `prod-infrastructure-app.yaml`)

### Fixes waehrend Deployment

1. **LVM nicht erweitert nach vSphere-Clone (Learning #7 erneut)**
   - Alle 3 PROD-Nodes hatten nur 46 GB statt 768 GB
   - Fix: `growpart` + `pvresize` + `lvextend` + `resize2fs` auf allen 3 Nodes
   - Longhorn konnte ohne Platz keine Replicas schedulen → alle DB-Volumes blockiert

2. **GHCR Pull-Secret YAML-Fehler**
   - Heredoc + JSON-Sonderzeichen im Script brachen YAML/SOPS
   - Fix: Manuell per `nano` mit `|` Block-Scalar-Format (wie TEST-Template)
   - Lerning: GHCR-Secrets immer per Template kopieren, nie per Script generieren

3. **it-info-versand ENVIRONMENT-Wert**
   - Script setzte `ENVIRONMENT=production`, App akzeptiert nur `dev`, `test`, `prod`
   - Fix: `production` → `prod` in deployment.yaml

4. **Garage Node-IDs**
   - Platzhalter in ConfigMap mussten durch echte Node-IDs ersetzt werden
   - IDs per Debug-Pod mit `xxd -p` aus Meta-PVCs ausgelesen (Rohformat, nicht Hex)
   - ArgoCD Auto-Sync musste pausiert werden um StatefulSet zu skalieren
   - Layout manuell zugewiesen: `garage layout assign -z dc1 -c 100G` + `layout apply --version 1`

5. **OpenProject DB-Migration**
   - 72 pending Migrations beim ersten Start
   - Fix: `kubectl run openproject-migrate` mit `rails db:migrate`

6. **Odoo DB-Initialisierung**
   - Fix: `kubectl run odoo-init` mit `odoo -i base --stop-after-init --no-http`

### kubeconfig Merge

Alle 3 kubeconfigs auf k8s-mgmt-10 zusammengefuehrt:
- Context `default` → `k8s-dev` umbenannt
- `~/.kube/config` enthaelt: k8s-dev, k8s-test, k8s-prod
- `.bashrc` aktualisiert: `export KUBECONFIG=~/.kube/config`
- k9s kann mit `:ctx` zwischen Clustern wechseln

---

## Aktueller Cluster-Status PROD

### ArgoCD Apps (29.03.2026)

**37 von 39 Apps Synced + Healthy:**

| App | Sync | Health | Anmerkung |
|-----|------|--------|-----------|
| argocd | Synced | Healthy | |
| cert-manager (4 Apps) | Synced | Healthy | |
| cnpg-operator | Synced | Healthy | |
| cnpg-cluster | Synced | Healthy | shared + erp laufen |
| cnpg-databases | Synced | Healthy | |
| cnpg-secrets | Synced | Healthy | |
| cnpg-logical-backup | Synced | Healthy | |
| mariadb-operator + crds | Synced | Healthy | |
| mariadb-cluster | Synced | Healthy | |
| mariadb-secrets | Synced | Healthy | |
| mariadb-idoit-databases | Synced | Healthy | |
| metallb | Synced | Healthy | |
| traefik | Synced | Healthy | |
| longhorn (3 Apps) | Synced | Healthy | |
| garage | Synced | Healthy | Layout zugewiesen, 3 Nodes |
| garage-secrets | Synced | Healthy | |
| garage-backup | Synced | Healthy | |
| n8n + secrets | Synced | Healthy | |
| keycloak + secrets | Synced | Healthy | |
| idoit + secrets | Synced | Healthy | |
| it-info-versand + secrets | Synced | Healthy | |
| openproject + secrets | Synced | Healthy | |
| odoo + secrets + backup + backup-secrets | Synced | Healthy | |
| **garage-backup-secrets** | **Unknown** | Healthy | **Secret #19 fehlt** |
| **prod-infrastructure** | **OutOfSync** | Healthy | **Wegen garage-backup-secrets** |

### Garage Node-IDs (PROD)

| Pod | Node-ID |
|-----|---------|
| garage-0 | `4b17a0c30796df60a63ba338ccdc5876b505242df468b1aa40389e08a13aa76e` |
| garage-1 | `5969a75cbfa419856c15d913a32dd0dd45b8d56ca18db799c653107b309f3d3f` |
| garage-2 | `d0dc02bf1faed9c76434bd28d9f609ce3df19fa88bcad4a477e0de7bc1785eb4` |

### Alle Pods Running

Alle Application-Pods laufen auf dem PROD-Cluster (Stand 29.03.2026):
- ArgoCD (7 Pods), MetalLB, Traefik, Cert-Manager, Longhorn — Running
- CNPG shared (3 Instanzen) + erp (3 Instanzen) — Running
- MariaDB Galera (3 Nodes) — Running
- Garage (3 Pods) + WebUI — Running
- n8n, Keycloak, i-doit, it-info-versand, OpenProject (Web + Worker + Memcached + Hocuspocus), Odoo — Running

---

## Post-Deployment-Konfiguration (noch offen)

### 1. Garage: API Keys + Buckets erstellen

```bash
# Auf k8s-mgmt-10:
export KUBECONFIG=~/.kube/config
kubectl config use-context k8s-prod

# API Key fuer OpenProject erstellen
kubectl exec -n garage garage-0 -- /garage key create openproject-app
kubectl exec -n garage garage-0 -- /garage key info openproject-app

# Bucket fuer OpenProject erstellen
kubectl exec -n garage garage-0 -- /garage bucket create openproject-assets
kubectl exec -n garage garage-0 -- /garage bucket allow openproject-assets --read --write --key openproject-app

# API Key fuer Backup (read-only)
kubectl exec -n garage garage-0 -- /garage key create garage-backup-readonly
kubectl exec -n garage garage-0 -- /garage key info garage-backup-readonly
# Read-only Zugriff auf alle Buckets:
kubectl exec -n garage garage-0 -- /garage bucket allow openproject-assets --read --key garage-backup-readonly
```

### 2. Secret #19: garage-backup-credentials erstellen

Nach Schritt 1 die Garage Backup Credentials verschluesseln:

```bash
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/prod/garage-backup-secrets
cp garage-backup-credentials.yaml.template garage-backup-credentials.yaml
nano garage-backup-credentials.yaml
# Eintragen: GARAGE_ACCESS_KEY_ID + GARAGE_SECRET_ACCESS_KEY (garage-backup-readonly Key)
# Eintragen: NAS10_ACCESS_KEY_ID (s3-k8s-prod) + NAS10_SECRET_ACCESS_KEY
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     garage-backup-credentials.yaml > garage-backup-credentials.enc.yaml
rm garage-backup-credentials.yaml
```

### 3. OpenProject Secrets aktualisieren (S3-Keys + OIDC)

Nach Garage API Key und Keycloak OIDC Client:

```bash
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/prod/apps/openproject/secrets
sops --decrypt openproject-secrets.enc.yaml > openproject-secrets.yaml
nano openproject-secrets.yaml
# Ersetzen: PLATZHALTER_GARAGE_DEPLOY → echte Garage S3-Keys (openproject-app)
# Ersetzen: PLATZHALTER_KEYCLOAK_DEPLOY → Keycloak OIDC Client Secret
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     openproject-secrets.yaml > openproject-secrets.enc.yaml
rm openproject-secrets.yaml
```

### 4. it-info-versand Secret aktualisieren (Keycloak OIDC)

```bash
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/prod/apps/it-info-versand/secrets
sops --decrypt it-info-versand-secrets.enc.yaml > it-info-versand-secrets.yaml
nano it-info-versand-secrets.yaml
# Ersetzen: PLATZHALTER_KEYCLOAK_DEPLOY → Keycloak OIDC Client Secret
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     it-info-versand-secrets.yaml > it-info-versand-secrets.enc.yaml
rm it-info-versand-secrets.yaml
```

### 5. Keycloak PROD konfigurieren

In der Keycloak Web-UI (https://keycloak.eneg.de):

1. **Realm `eNeG` erstellen** (ACHTUNG: case-sensitive!)
2. **AD/LDAP User Federation** konfigurieren (identisch zu TEST)
3. **Group Mapper:** `ad-groups` (Preserve Group Inheritance: Off)
4. **OIDC-Clients erstellen:**
   - `openproject` — Client Secret notieren fuer Schritt 3
   - `it-info-versand` — **Group Membership Mapper nicht vergessen!**
     (Token Claim Name: `groups`, Full group path: Off, ID+access+userinfo: On)
   - Client Secrets notieren fuer Schritt 3 + 4
5. **User-Sync ausfuehren**

### 6. OpenProject LDAP konfigurieren

In der OpenProject Web-UI (https://openproject.eneg.de):
- Admin-Login: admin/admin (Passwort sofort aendern!)
- LDAP-Authentifizierung konfigurieren (direkt gegen AD, wie TEST)
- S3-Attachments testen (Datei hochladen)
- SMTP testen (Benutzer einladen)

### 7. Odoo Erstkonfiguration

In der Odoo Web-UI (https://odoo.eneg.de):
- Admin-Passwort aendern
- Basis-Module konfigurieren

### 8. SSL-Zertifikate + DNS pruefen

Alle URLs auf HTTPS-Erreichbarkeit pruefen:

| App | URL | Typ |
|-----|-----|-----|
| ArgoCD | https://argocd-prod.eneg.de | Intern |
| Longhorn | https://longhorn-prod.eneg.de | Intern |
| Garage WebUI | https://s3-gui-prod.eneg.de | Intern |
| Garage S3 API | https://s3-prod.eneg.de | Intern |
| n8n | https://n8n.eneg.de | User-facing |
| Keycloak | https://keycloak.eneg.de | User-facing |
| OpenProject | https://openproject.eneg.de | User-facing |
| Odoo | https://odoo.eneg.de | User-facing |
| i-doit | https://idoit.eneg.de | User-facing |
| IT-Info-Versand | https://it-info-versand.eneg.de | User-facing |

### 9. Backups pruefen (nach 24h)

- [ ] CNPG Physical Backup (02:00 UTC)
- [ ] CNPG Logical Backup (03:00 UTC)
- [ ] MariaDB Physical Backup (02:30 UTC)
- [ ] Garage → NAS10 Backup (04:00 CET) — erst nach Secret #19
- [ ] Odoo Filestore Backup (05:00 CET)

---

## Post-Deployment-Konfiguration (abgeschlossen 30.03.2026)

### Schritt 1+2: Garage API Keys + Secret #19
- API Key `openproject-app` erstellt, Bucket `openproject-assets` angelegt (read+write)
- API Key `garage-backup-readonly` erstellt (read-only auf openproject-assets)
- `garage-backup-credentials.enc.yaml` (Secret #19) erstellt und verschluesselt
- ArgoCD garage-backup-secrets App nun Synced + Healthy

### Schritt 3: Keycloak PROD
- Realm `eNeG` erstellt (case-sensitive!)
- AD/LDAP User Federation konfiguriert (dc01/dc02/dc03, READ_ONLY)
- Group Mapper `ad-groups` (Preserve Group Inheritance: Off)
- OIDC-Client `it-info-versand` erstellt mit Group Membership Protocol Mapper
  (Token Claim Name: `groups`, Full group path: Off, ID+access+userinfo: On)
- User-Sync erfolgreich

### Schritt 4+5: Secrets aktualisiert
- `it-info-versand-secrets.enc.yaml` — Keycloak OIDC Client Secret eingetragen
- `openproject-secrets.enc.yaml` — Garage S3-Keys eingetragen

### Schritt 6: Commit + Push
- Alle aktualisierten Secrets committed und gepusht
- ArgoCD hat Secrets automatisch gesynct

### Schritt 7: OpenProject PROD
- Admin-Passwort geaendert
- LDAP-Authentifizierung gegen AD konfiguriert
- SMTP getestet und funktioniert (smtpout1.eneg.customers.hosting.zone:587)
- S3-Attachments getestet und funktioniert (nach Pod-Restart)
- **Fix:** Hocuspocus musste in Administration → Documents konfiguriert werden
  (URL + Secret manuell eintragen), plus Documents-Modul pro Projekt aktivieren
- **Fix:** OpenProject-Pods brauchten Restart nach Secret-Update
  (`kubectl rollout restart deployment openproject-web openproject-worker -n openproject`)

### Schritt 8: Odoo PROD
- Admin-Passwort geaendert und dokumentiert

### Schritt 9: SSL/DNS-Pruefung
Alle 10 PROD-URLs erreichbar:

| URL | Status | Bedeutung |
|-----|--------|-----------|
| https://argocd-prod.eneg.de | 200 | OK |
| https://longhorn-prod.eneg.de | 200 | OK |
| https://s3-gui-prod.eneg.de | 200 | OK |
| https://s3-prod.eneg.de | 403 | Erwartet (S3 API ohne Auth) |
| https://n8n.eneg.de | 200 | OK |
| https://keycloak.eneg.de | 302 | Redirect auf Login |
| https://openproject.eneg.de | 302 | Redirect auf Login |
| https://odoo.eneg.de | 303 | Redirect auf Login |
| https://idoit.eneg.de | 200 | OK |
| https://it-info-versand.eneg.de | 302 | Redirect auf Login |

### Schritt 10: Backup-Pruefung (30.03.2026)
| Backup | Status | Anmerkung |
|--------|--------|-----------|
| CNPG Physical (shared+erp) | ✅ | ScheduledBackups laufen |
| CNPG Logical (shared+erp) | ✅ | Complete |
| MariaDB Galera | ✅ | Complete |
| Garage → NAS10 | ✅ | Complete (nach manuellem Test) |
| Odoo Filestore | ✅ | Complete |

---

## Kritische Learnings (diese Session)

1. **LVM-Erweiterung nach vSphere-Clone fehlt weiterhin**
   Trotz cloud-init growpart im Packer-Template wurde die Partition auf den PROD-Nodes
   nicht erweitert (46 GB statt 768 GB). Manueller Fix noetig:
   `growpart /dev/sda 3 && pvresize && lvextend && resize2fs`
   → TODO: Packer-Template/Ansible pruefen warum growpart nicht greift

2. **GHCR Pull-Secrets nie per heredoc/Script generieren**
   JSON-Inhalt + Sonderzeichen in PAT/Base64 brechen Shell-Variablen und YAML.
   Immer per Template (`|` Block-Scalar) + manuell nano verwenden.

3. **ENVIRONMENT-Werte muessen exakt stimmen**
   it-info-versand akzeptiert nur `dev`, `test`, `prod` — nicht `production`.

4. **Garage Node-IDs sind Rohbytes, nicht Hex**
   `node_key.pub` enthaelt Binaerdaten. Auslesen mit `xxd -p | tr -d '\n'`.
   Garage-Image hat kein `cat` (minimales Rust-Binary) — busybox Debug-Pod noetig.

5. **ArgoCD Auto-Sync muss pausiert werden fuer Garage-Wartung**
   Fuer Node-ID-Auslesen: `kubectl patch application garage -n argocd --type merge -p '{"spec":{"syncPolicy":null}}'`
   Danach wieder aktivieren: `...syncPolicy":{"automated":{"prune":true,"selfHeal":true}}...`

6. **ArgoCD Repository-Secret manuell erstellen (Bootstrap Henne-Ei)**
   Das SOPS-verschluesselte Repo-Secret kann erst entschluesselt werden wenn ArgoCD
   laeuft — aber ArgoCD braucht das Repo-Secret um sich selbst zu deployen.
   Fix: Manuell per `kubectl apply` mit SSH-Key via heredoc + sed-Indentation.

7. **kubeconfig Context-Name `default` umbenennen**
   K3s generiert kubeconfig mit Context `default`. Fuer Multi-Cluster-Setups
   umbenennen: `kubectl config rename-context default k8s-prod`

8. **OpenProject Hocuspocus muss in der Web-UI konfiguriert werden**
   Containerized Installations starten Hocuspocus automatisch, aber die Verbindung
   muss in Administration → Documents manuell konfiguriert werden (URL + Secret).
   Zusaetzlich muss das Documents-Modul pro Projekt aktiviert werden:
   Project settings → Modules → Documents aktivieren.

9. **OpenProject-Pods brauchen Restart nach Secret-Update**
   ENV-Variablen werden nur beim Pod-Start gelesen. Nach SOPS-Secret-Update
   und ArgoCD-Sync muessen Web- und Worker-Pods manuell restartet werden:
   `kubectl rollout restart deployment openproject-web openproject-worker -n openproject`

---

## Referenz

### Arbeitsumgebungen
- **Windows-Laptop:** `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\`
- **MacMini/MacBook:** `/Users/danielhenke/git/eneg-k8s-infrastructure-v2/`
- **k8s-mgmt-10 (192.168.180.10):** `~/git/eneg-k8s-infrastructure-v2/`

### Cluster-Zugaenge

| Cluster | Context | kubeconfig | ArgoCD URL |
|---------|---------|------------|------------|
| DEV | k8s-dev | `~/.kube/config` | https://argocd-dev-v2.eneg.de |
| TEST | k8s-test | `~/.kube/config` | https://argocd-test.eneg.de |
| PROD | k8s-prod | `~/.kube/config` | https://argocd-prod.eneg.de |

### SOPS-Verschluesselung

```bash
# Verschluesseln
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     secret.yaml > secret.enc.yaml

# Entschluesseln
sops --decrypt secret.enc.yaml > secret.yaml
```

### Reihenfolge fuer Post-Deployment im neuen Chat

1. Garage API Keys + Buckets erstellen
2. garage-backup-credentials Secret (#19) erstellen + verschluesseln
3. Keycloak: Realm eNeG + AD/LDAP + OIDC-Clients
4. OpenProject Secret: S3-Keys + OIDC-Secret eintragen
5. it-info-versand Secret: Keycloak OIDC-Secret eintragen
6. Commit + Push aller aktualisierten Secrets
7. OpenProject: LDAP + Admin-PW + S3-Test + SMTP-Test
8. Odoo: Admin-PW aendern
9. SSL/DNS-Pruefung aller URLs
10. Backup-Pruefung nach 24h

---

*Erstellt am 29.03.2026. Dieses Dokument dient als Startpunkt fuer den neuen Chat.*
