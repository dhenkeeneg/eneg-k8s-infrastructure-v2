#!/bin/bash
# =============================================================================
# Phase 8c PROD: Secret-Generierung und SOPS-Verschluesselung
# Ausfuehren auf k8s-mgmt-10
# =============================================================================
#
# VORAUSSETZUNGEN:
# - Repository ist aktuell: cd ~/git/eneg-k8s-infrastructure-v2 && git pull
# - SOPS Age Key vorhanden: ~/.config/sops/age/keys.txt
# - NAS10 S3 Secret Key fuer Account s3-k8s-prod bereit
# - SMTP-Credentials bereit
# - GitHub PAT (fuer ghcr.io) bereit
#
# WICHTIG: Alle Passwoerter nur mit openssl rand -hex 24 generieren!
# (Keine Sonderzeichen die DATABASE_URL oder YAML brechen)
#
# ABLAUF:
# 1. cd in Secret-Verzeichnis
# 2. Template kopieren: cp <name>.yaml.template <name>.yaml
# 3. Passwoerter generieren und eintragen
# 4. SOPS verschluesseln
# 5. Klartextdatei loeschen
# 6. Pruefen ob .enc.yaml nicht leer ist
# =============================================================================

set -e
REPO=~/git/eneg-k8s-infrastructure-v2
PROD=$REPO/kubernetes/environments/prod
AGE_KEY="age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm"
SOPS_OPTS="--encrypt --age $AGE_KEY --encrypted-regex ^(data|stringData)$"

echo "========================================"
echo "Phase 8c: PROD Secrets generieren"
echo "========================================"
echo ""

# --- SCHRITT 1: CNPG S3-Credentials ---
echo "=== 1/11: CNPG S3-Credentials ==="
echo "Benoetigt: NAS10 S3 Secret Key fuer Account s3-k8s-prod"
cd $PROD/cnpg-secrets
cp s3-credentials.yaml.template s3-credentials.yaml
echo ">>> Bitte s3-credentials.yaml editieren: SECRET_ACCESS_KEY eintragen"
echo ">>> Dann: Enter druecken"
read -p "Bereit? "
sops $SOPS_OPTS s3-credentials.yaml > s3-credentials.enc.yaml
rm s3-credentials.yaml
echo "Groesse: $(wc -c < s3-credentials.enc.yaml) Bytes"
echo ""

# --- SCHRITT 2: CNPG DB-Credentials (5 Apps) ---
echo "=== 2/11: CNPG DB-Credentials (5 Apps) ==="
echo "Fuer jede App: openssl rand -hex 24 -> Passwort eintragen"
cd $PROD/cnpg-secrets

for APP in n8n openproject odoo keycloak it-info-versand; do
  echo ""
  echo "--- $APP ---"
  cp ${APP}-db-credentials.yaml.template ${APP}-db-credentials.yaml
  echo ">>> Bitte ${APP}-db-credentials.yaml editieren: password eintragen"
  echo ">>> MERKEN: Dieses Passwort wird spaeter auch im App-Secret benoetigt!"
  read -p "Bereit? "
  sops $SOPS_OPTS ${APP}-db-credentials.yaml > ${APP}-db-credentials.enc.yaml
  rm ${APP}-db-credentials.yaml
  echo "Groesse: $(wc -c < ${APP}-db-credentials.enc.yaml) Bytes"
done
echo ""

# --- SCHRITT 3: MariaDB Credentials ---
echo "=== 3/11: MariaDB Root + S3-Credentials ==="
echo "Benoetigt: ROOT_PASSWORD (openssl rand -hex 24) + NAS10 S3 Secret Key"
cd $PROD/mariadb-secrets
cp mariadb-credentials.yaml.template mariadb-credentials.yaml
echo ">>> Bitte mariadb-credentials.yaml editieren:"
echo ">>>   ROOT_PASSWORD: generieren mit openssl rand -hex 24"
echo ">>>   S3_SECRET_ACCESS_KEY: NAS10 Key eintragen"
read -p "Bereit? "
sops $SOPS_OPTS mariadb-credentials.yaml > mariadb-credentials.enc.yaml
rm mariadb-credentials.yaml
echo "Groesse: $(wc -c < mariadb-credentials.enc.yaml) Bytes"
echo ""

# --- SCHRITT 4: MariaDB i-doit DB-Credentials ---
echo "=== 4/11: MariaDB i-doit DB-Credentials ==="
echo "WICHTIG: Dasselbe Passwort wie spaeter in idoit-secrets!"
cd $PROD/mariadb-secrets
cp idoit-db-credentials.yaml.template idoit-db-credentials.yaml
echo ">>> Bitte idoit-db-credentials.yaml editieren: password eintragen"
echo ">>> MERKEN: Dieses Passwort wird auch in idoit-secrets benoetigt!"
read -p "Bereit? "
sops $SOPS_OPTS idoit-db-credentials.yaml > idoit-db-credentials.enc.yaml
rm idoit-db-credentials.yaml
echo "Groesse: $(wc -c < idoit-db-credentials.enc.yaml) Bytes"
echo ""

# --- SCHRITT 5: Garage Secrets ---
echo "=== 5/11: Garage Secrets ==="
echo "Benoetigt: RPC_SECRET, ADMIN_TOKEN, METRICS_TOKEN (je openssl rand -hex 32)"
echo "           WebUI bcrypt Hash: htpasswd -nbBC 10 'admin' 'DEIN_PASSWORT'"
cd $PROD/garage-secrets
cp garage-secrets.yaml.template garage-secrets.yaml
echo ">>> Bitte garage-secrets.yaml editieren:"
echo ">>>   rpc-secret, admin-token, metrics-token: je openssl rand -hex 32"
echo ">>>   webui-auth: admin:<bcrypt-hash>"
echo ">>>   WebUI-Passwort sicher in 1Password speichern!"
read -p "Bereit? "
sops $SOPS_OPTS garage-secrets.yaml > garage-secrets.enc.yaml
rm garage-secrets.yaml
echo "Groesse: $(wc -c < garage-secrets.enc.yaml) Bytes"
echo ""

# --- SCHRITT 6: Garage Backup Secrets ---
echo "=== 6/11: Garage Backup Credentials ==="
echo "HINWEIS: Garage-Keys werden erst nach Garage-Deploy erstellt!"
echo "         Diesen Schritt UEBERSPRINGEN und spaeter nachholen."
echo "         (garage-backup-credentials.enc.yaml wird spaeter erstellt)"
echo ""

# --- SCHRITT 7: n8n Secrets ---
echo "=== 7/11: n8n App-Secrets ==="
cd $PROD/apps/n8n/secrets
cat > n8n-secrets.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: n8n-secrets
  namespace: n8n
  labels:
    app.kubernetes.io/name: n8n
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  encryption-key: "HIER_ENCRYPTION_KEY"
  db-password: "HIER_DASSELBE_DB_PASSWORT_WIE_CNPG"
TEMPLATE
echo ">>> Bitte n8n-secrets.yaml editieren:"
echo ">>>   encryption-key: openssl rand -hex 32"
echo ">>>   db-password: DASSELBE wie in cnpg-secrets/n8n-db-credentials"
read -p "Bereit? "
sops $SOPS_OPTS n8n-secrets.yaml > n8n-secrets.enc.yaml
rm n8n-secrets.yaml
echo "Groesse: $(wc -c < n8n-secrets.enc.yaml) Bytes"
echo ""

# --- SCHRITT 8: Keycloak Secrets ---
echo "=== 8/11: Keycloak App-Secrets ==="
cd $PROD/apps/keycloak/secrets
cat > keycloak-secrets.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-secrets
  namespace: keycloak
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  db-password: "HIER_DASSELBE_DB_PASSWORT_WIE_CNPG"
  admin-password: "HIER_ADMIN_PASSWORT"
TEMPLATE
echo ">>> Bitte keycloak-secrets.yaml editieren:"
echo ">>>   db-password: DASSELBE wie in cnpg-secrets/keycloak-db-credentials"
echo ">>>   admin-password: openssl rand -hex 24"
echo ">>>   Admin-Passwort sicher in 1Password speichern!"
read -p "Bereit? "
sops $SOPS_OPTS keycloak-secrets.yaml > keycloak-secrets.enc.yaml
rm keycloak-secrets.yaml
echo "Groesse: $(wc -c < keycloak-secrets.enc.yaml) Bytes"
echo ""

# --- SCHRITT 9: i-doit Secrets + ghcr-pull-secret ---
echo "=== 9/11: i-doit App-Secrets + ghcr-pull-secret ==="
cd $PROD/apps/idoit/secrets

cat > idoit-secrets.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: idoit-secrets
  namespace: idoit
  labels:
    app.kubernetes.io/name: idoit
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  db-password: "HIER_DASSELBE_DB_PASSWORT_WIE_MARIADB"
  admin-password: "HIER_ADMIN_PASSWORT"
TEMPLATE
echo ">>> Bitte idoit-secrets.yaml editieren:"
echo ">>>   db-password: DASSELBE wie in mariadb-secrets/idoit-db-credentials"
echo ">>>   admin-password: openssl rand -hex 16"
read -p "Bereit? "
sops $SOPS_OPTS idoit-secrets.yaml > idoit-secrets.enc.yaml
rm idoit-secrets.yaml
echo "Groesse: $(wc -c < idoit-secrets.enc.yaml) Bytes"

# ghcr-pull-secret (gleicher PAT fuer alle Umgebungen)
echo ""
echo "--- ghcr-pull-secret ---"
echo "Benoetigt: GitHub PAT mit read:packages"
echo "auth-Feld: echo -n 'dhenkeeneg:GITHUB_PAT' | base64"
cat > ghcr-pull-secret.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-pull-secret
  namespace: idoit
  labels:
    app.kubernetes.io/managed-by: argocd
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "ghcr.io": {
          "username": "dhenkeeneg",
          "password": "HIER_GITHUB_PAT_TOKEN",
          "auth": "HIER_BASE64_VON_USERNAME:TOKEN"
        }
      }
    }
TEMPLATE
echo ">>> Bitte ghcr-pull-secret.yaml editieren:"
echo ">>>   password: GitHub PAT eintragen"
echo ">>>   auth: echo -n 'dhenkeeneg:DEIN_PAT' | base64  (NUR Base64, kein Prefix!)"
read -p "Bereit? "
sops $SOPS_OPTS ghcr-pull-secret.yaml > ghcr-pull-secret.enc.yaml
rm ghcr-pull-secret.yaml
echo "Groesse: $(wc -c < ghcr-pull-secret.enc.yaml) Bytes"
echo ""

# --- SCHRITT 10: OpenProject Secrets ---
echo "=== 10/11: OpenProject App-Secrets ==="
echo "HINWEIS: S3-Keys werden erst nach Garage-Deploy erstellt!"
echo "         S3-Keys und OIDC-Client-Secret werden als Platzhalter eingetragen"
echo "         und nach Garage/Keycloak-Setup aktualisiert."
cd $PROD/apps/openproject/secrets
cat > openproject-secrets.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: openproject-secrets
  namespace: openproject
  labels:
    app.kubernetes.io/name: openproject
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  secret-key-base: "HIER_SECRET_KEY_BASE"
  hocuspocus-secret: "HIER_HOCUSPOCUS_SECRET"
  database-url: "postgres://openproject:HIER_DB_PASSWORT@cnpg-erp-rw.databases.svc.cluster.local:5432/openproject"
  s3-access-key-id: "PLATZHALTER_GARAGE_DEPLOY"
  s3-secret-access-key: "PLATZHALTER_GARAGE_DEPLOY"
  oidc-client-secret: "PLATZHALTER_KEYCLOAK_DEPLOY"
  smtp-username: "HIER_SMTP_USERNAME"
  smtp-password: "HIER_SMTP_PASSWORT"
TEMPLATE
echo ">>> Bitte openproject-secrets.yaml editieren:"
echo ">>>   secret-key-base: openssl rand -hex 64"
echo ">>>   hocuspocus-secret: openssl rand -hex 32"
echo ">>>   database-url: DB-Passwort DASSELBE wie cnpg-secrets/openproject-db-credentials"
echo ">>>   s3-access-key-id: PLATZHALTER_GARAGE_DEPLOY (spaeter ersetzen)"
echo ">>>   s3-secret-access-key: PLATZHALTER_GARAGE_DEPLOY (spaeter ersetzen)"
echo ">>>   oidc-client-secret: PLATZHALTER_KEYCLOAK_DEPLOY (spaeter ersetzen)"
echo ">>>   smtp-username + smtp-password: SMTP-Credentials eintragen"
read -p "Bereit? "
sops $SOPS_OPTS openproject-secrets.yaml > openproject-secrets.enc.yaml
rm openproject-secrets.yaml
echo "Groesse: $(wc -c < openproject-secrets.enc.yaml) Bytes"
echo ""

# --- SCHRITT 11: Odoo Secrets ---
echo "=== 11a/11: Odoo App-Secrets ==="
cd $PROD/apps/odoo/secrets
cat > odoo-secrets.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: odoo-secrets
  namespace: odoo
  labels:
    app.kubernetes.io/name: odoo
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  db-password: "HIER_DASSELBE_DB_PASSWORT_WIE_CNPG"
  admin-password: "HIER_ADMIN_PASSWORT"
TEMPLATE
echo ">>> Bitte odoo-secrets.yaml editieren:"
echo ">>>   db-password: DASSELBE wie in cnpg-secrets/odoo-db-credentials"
echo ">>>   admin-password: openssl rand -hex 24"
read -p "Bereit? "
sops $SOPS_OPTS odoo-secrets.yaml > odoo-secrets.enc.yaml
rm odoo-secrets.yaml
echo "Groesse: $(wc -c < odoo-secrets.enc.yaml) Bytes"
echo ""

echo "=== 11b/11: Odoo Backup Credentials ==="
cd $PROD/apps/odoo/backup/secrets
cat > odoo-backup-credentials.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: odoo-backup-credentials
  namespace: odoo
  labels:
    app.kubernetes.io/name: odoo-backup
    app.kubernetes.io/part-of: pilot-apps
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  NAS10_ACCESS_KEY_ID: "s3-k8s-prod"
  NAS10_SECRET_ACCESS_KEY: "HIER_NAS10_SECRET_KEY"
TEMPLATE
echo ">>> Bitte odoo-backup-credentials.yaml editieren:"
echo ">>>   NAS10_SECRET_ACCESS_KEY: NAS10 S3 Secret Key eintragen"
read -p "Bereit? "
sops $SOPS_OPTS odoo-backup-credentials.yaml > odoo-backup-credentials.enc.yaml
rm odoo-backup-credentials.yaml
echo "Groesse: $(wc -c < odoo-backup-credentials.enc.yaml) Bytes"
echo ""

# --- SCHRITT 12: it-info-versand Secrets + ghcr-pull-secret ---
echo "=== 12/11: it-info-versand App-Secrets ==="
cd $PROD/apps/it-info-versand/secrets
cat > it-info-versand-secrets.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: it-info-versand-secrets
  namespace: it-info-versand
  labels:
    app.kubernetes.io/name: it-info-versand
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  db-password: "HIER_DASSELBE_PASSWORT_WIE_CNPG"
  session-secret: "HIER_SESSION_SECRET"
  encryption-key: "HIER_FERNET_KEY"
  smtp-username: "HIER_SMTP_USERNAME"
  smtp-password: "HIER_SMTP_PASSWORT"
  keycloak-client-secret: "PLATZHALTER_KEYCLOAK_DEPLOY"
TEMPLATE
echo ">>> Bitte it-info-versand-secrets.yaml editieren:"
echo ">>>   db-password: DASSELBE wie cnpg-secrets/it-info-versand-db-credentials"
echo ">>>   session-secret: openssl rand -hex 32"
echo ">>>   encryption-key: python3 -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\""
echo ">>>   smtp-username + smtp-password: SMTP-Credentials eintragen"
echo ">>>   keycloak-client-secret: PLATZHALTER_KEYCLOAK_DEPLOY (spaeter ersetzen)"
read -p "Bereit? "
sops $SOPS_OPTS it-info-versand-secrets.yaml > it-info-versand-secrets.enc.yaml
rm it-info-versand-secrets.yaml
echo "Groesse: $(wc -c < it-info-versand-secrets.enc.yaml) Bytes"

# ghcr-pull-secret fuer it-info-versand
echo ""
echo "--- ghcr-pull-secret (it-info-versand) ---"
cat > ghcr-pull-secret.yaml << 'TEMPLATE'
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-pull-secret
  namespace: it-info-versand
  labels:
    app.kubernetes.io/managed-by: argocd
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "ghcr.io": {
          "username": "dhenkeeneg",
          "password": "HIER_GITHUB_PAT_TOKEN",
          "auth": "HIER_BASE64_VON_USERNAME:TOKEN"
        }
      }
    }
TEMPLATE
echo ">>> Bitte ghcr-pull-secret.yaml editieren (gleicher PAT wie i-doit)"
read -p "Bereit? "
sops $SOPS_OPTS ghcr-pull-secret.yaml > ghcr-pull-secret.enc.yaml
rm ghcr-pull-secret.yaml
echo "Groesse: $(wc -c < ghcr-pull-secret.enc.yaml) Bytes"
echo ""

# =============================================================================
echo "========================================"
echo "FERTIG! Zusammenfassung:"
echo "========================================"
echo ""
echo "Verschluesselte Secrets erstellt:"
find $PROD -name "*.enc.yaml" -newer $PROD/cnpg-secrets/kustomization.yaml | sort
echo ""
echo "NOCH OFFEN (nach Garage/Keycloak Deploy):"
echo "  - garage-backup-secrets/garage-backup-credentials.enc.yaml"
echo "  - openproject-secrets: s3-access-key-id, s3-secret-access-key aktualisieren"
echo "  - openproject-secrets: oidc-client-secret aktualisieren"
echo "  - it-info-versand-secrets: keycloak-client-secret aktualisieren"
echo ""
echo "Naechster Schritt: git add + commit + push, dann ArgoCD Bootstrap"
