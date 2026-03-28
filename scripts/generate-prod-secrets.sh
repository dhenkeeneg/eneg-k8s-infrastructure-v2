#!/bin/bash
# =============================================================================
# Phase 8c PROD: Automatische Secret-Generierung + SOPS-Verschluesselung
# Ausfuehren auf k8s-mgmt-10
# =============================================================================
# Generiert alle Passwoerter automatisch, erstellt die YAML-Dateien,
# zeigt jede Datei mit eingetragenen Werten an und verschluesselt nach
# Bestaetigung.
#
# 4 Werte muessen manuell eingegeben werden:
#   - NAS10 S3 Secret Key (s3-k8s-prod)
#   - SMTP Username
#   - SMTP Passwort
#   - GitHub PAT (ghcr.io, read:packages)
# =============================================================================

set -e
REPO=~/git/eneg-k8s-infrastructure-v2
PROD=$REPO/kubernetes/environments/prod
AGE_KEY="age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm"

encrypt_and_verify() {
  local src="$1"
  local dst="$2"
  sops --encrypt --age "$AGE_KEY" --encrypted-regex '^(data|stringData)$' "$src" > "$dst"
  local size=$(wc -c < "$dst")
  if [ "$size" -lt 10 ]; then
    echo "FEHLER: $dst ist nur $size Bytes - Verschluesselung fehlgeschlagen!"
    exit 1
  fi
  rm "$src"
  echo "  -> Verschluesselt: $dst ($size Bytes)"
}

show_and_confirm() {
  local file="$1"
  echo ""
  echo "--- Inhalt von $file ---"
  cat "$file"
  echo "--- Ende ---"
  echo ""
  read -p "OK? Verschluesseln und Klartext loeschen? (j/n) " answer
  if [ "$answer" != "j" ] && [ "$answer" != "y" ]; then
    echo "Abgebrochen. Klartext bleibt: $file"
    exit 1
  fi
}

echo "========================================"
echo "Phase 8c: PROD Secrets automatisch generieren"
echo "========================================"
echo ""

# --- Externe Werte abfragen ---
read -p "NAS10 S3 Secret Key (Account s3-k8s-prod): " NAS10_SECRET
read -p "SMTP Username: " SMTP_USER
read -p "SMTP Passwort: " SMTP_PASS
read -p "GitHub PAT (ghcr.io read:packages): " GITHUB_PAT

GHCR_AUTH=$(echo -n "dhenkeeneg:${GITHUB_PAT}" | base64)

# --- Alle DB-Passwoerter generieren ---
PW_N8N=$(openssl rand -hex 24)
PW_OPENPROJECT=$(openssl rand -hex 24)
PW_ODOO=$(openssl rand -hex 24)
PW_KEYCLOAK=$(openssl rand -hex 24)
PW_ITINFO=$(openssl rand -hex 24)
PW_IDOIT=$(openssl rand -hex 24)
PW_MARIADB_ROOT=$(openssl rand -hex 24)

# App-spezifische Keys
N8N_ENCRYPTION=$(openssl rand -hex 32)
KC_ADMIN=$(openssl rand -hex 24)
IDOIT_ADMIN=$(openssl rand -hex 16)
ODOO_ADMIN=$(openssl rand -hex 24)
OP_SECRET_KEY=$(openssl rand -hex 64)
OP_HOCUSPOCUS=$(openssl rand -hex 32)
ITINFO_SESSION=$(openssl rand -hex 32)

# Garage Tokens
GARAGE_RPC=$(openssl rand -hex 32)
GARAGE_ADMIN=$(openssl rand -hex 32)
GARAGE_METRICS=$(openssl rand -hex 32)

echo ""
echo "Alle Passwoerter generiert. Starte Secret-Erstellung..."
echo ""

# =====================================================================
# 1/12: CNPG S3-Credentials
# =====================================================================
echo "=== 1/12: CNPG S3-Credentials ==="
cd $PROD/cnpg-secrets
cat > s3-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-s3-credentials
  namespace: databases
  labels:
    app.kubernetes.io/part-of: cloudnative-pg
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  ACCESS_KEY_ID: "s3-k8s-prod"
  SECRET_ACCESS_KEY: "${NAS10_SECRET}"
  S3_ENDPOINT: "http://nas10.eneg.de:8010"
EOF
show_and_confirm "$PROD/cnpg-secrets/s3-credentials.yaml"
encrypt_and_verify s3-credentials.yaml s3-credentials.enc.yaml

# =====================================================================
# 2/12: CNPG DB-Credentials (5 Apps)
# =====================================================================
echo "=== 2/12: CNPG DB-Credentials (5 Apps) ==="

for APP_INFO in "n8n:n8n:${PW_N8N}" "openproject:openproject:${PW_OPENPROJECT}" "odoo:odoo:${PW_ODOO}" "keycloak:keycloak:${PW_KEYCLOAK}" "it-info-versand:it_info_versand:${PW_ITINFO}"; do
  IFS=':' read -r APP_NAME DB_USER APP_PW <<< "$APP_INFO"
  echo ""
  echo "--- ${APP_NAME} ---"
  cat > ${APP_NAME}-db-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${APP_NAME}-db-credentials
  namespace: databases
  labels:
    app.kubernetes.io/part-of: cloudnative-pg
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  username: "${DB_USER}"
  password: "${APP_PW}"
EOF
  show_and_confirm "$PROD/cnpg-secrets/${APP_NAME}-db-credentials.yaml"
  encrypt_and_verify ${APP_NAME}-db-credentials.yaml ${APP_NAME}-db-credentials.enc.yaml
done

# =====================================================================
# 3/12: MariaDB Root + S3 Credentials
# =====================================================================
echo "=== 3/12: MariaDB Root + S3 Credentials ==="
cd $PROD/mariadb-secrets
cat > mariadb-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-credentials
  namespace: databases
  labels:
    app.kubernetes.io/part-of: mariadb-galera
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  ROOT_PASSWORD: "${PW_MARIADB_ROOT}"
  S3_ACCESS_KEY_ID: "s3-k8s-prod"
  S3_SECRET_ACCESS_KEY: "${NAS10_SECRET}"
  S3_ENDPOINT: "http://nas10.eneg.de:8010"
EOF
show_and_confirm "$PROD/mariadb-secrets/mariadb-credentials.yaml"
encrypt_and_verify mariadb-credentials.yaml mariadb-credentials.enc.yaml

# =====================================================================
# 4/12: MariaDB i-doit DB-Credentials
# =====================================================================
echo "=== 4/12: MariaDB i-doit DB-Credentials ==="
cat > idoit-db-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: idoit-db-credentials
  namespace: databases
  labels:
    app.kubernetes.io/name: idoit
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  password: "${PW_IDOIT}"
EOF
show_and_confirm "$PROD/mariadb-secrets/idoit-db-credentials.yaml"
encrypt_and_verify idoit-db-credentials.yaml idoit-db-credentials.enc.yaml

# =====================================================================
# 5/12: Garage Secrets (ohne WebUI - bcrypt muss manuell)
# =====================================================================
echo "=== 5/12: Garage Secrets ==="
echo "HINWEIS: Fuer das WebUI-Passwort muss ein bcrypt-Hash erstellt werden."
read -p "WebUI Admin-Passwort eingeben (wird gehasht): " GARAGE_WEBUI_PW
GARAGE_BCRYPT=$(htpasswd -nbBC 10 'admin' "$GARAGE_WEBUI_PW" | cut -d: -f2)
cd $PROD/garage-secrets
cat > garage-secrets.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: garage-secrets
  namespace: garage
  labels:
    app.kubernetes.io/name: garage
    app.kubernetes.io/part-of: infrastructure
    app.kubernetes.io/managed-by: argocd
type: Opaque
stringData:
  rpc-secret: "${GARAGE_RPC}"
  admin-token: "${GARAGE_ADMIN}"
  metrics-token: "${GARAGE_METRICS}"
  webui-auth: "admin:${GARAGE_BCRYPT}"
EOF
show_and_confirm "$PROD/garage-secrets/garage-secrets.yaml"
encrypt_and_verify garage-secrets.yaml garage-secrets.enc.yaml

# =====================================================================
# 6/12: Garage Backup Secrets (SKIP - erst nach Garage-Deploy)
# =====================================================================
echo ""
echo "=== 6/12: Garage Backup Secrets - UEBERSPRUNGEN ==="
echo "  -> Wird nach Garage-Deploy erstellt (Garage API Keys benoetigt)"
echo ""

# =====================================================================
# 7/12: n8n App-Secrets
# =====================================================================
echo "=== 7/12: n8n App-Secrets ==="
cd $PROD/apps/n8n/secrets
cat > n8n-secrets.yaml << EOF
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
  encryption-key: "${N8N_ENCRYPTION}"
  db-password: "${PW_N8N}"
EOF
show_and_confirm "$PROD/apps/n8n/secrets/n8n-secrets.yaml"
encrypt_and_verify n8n-secrets.yaml n8n-secrets.enc.yaml

# =====================================================================
# 8/12: Keycloak App-Secrets
# =====================================================================
echo "=== 8/12: Keycloak App-Secrets ==="
cd $PROD/apps/keycloak/secrets
cat > keycloak-secrets.yaml << EOF
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
  db-password: "${PW_KEYCLOAK}"
  admin-password: "${KC_ADMIN}"
EOF
show_and_confirm "$PROD/apps/keycloak/secrets/keycloak-secrets.yaml"
encrypt_and_verify keycloak-secrets.yaml keycloak-secrets.enc.yaml

# =====================================================================
# 9/12: i-doit App-Secrets + ghcr-pull-secret
# =====================================================================
echo "=== 9/12: i-doit App-Secrets ==="
cd $PROD/apps/idoit/secrets
cat > idoit-secrets.yaml << EOF
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
  db-password: "${PW_IDOIT}"
  admin-password: "${IDOIT_ADMIN}"
EOF
show_and_confirm "$PROD/apps/idoit/secrets/idoit-secrets.yaml"
encrypt_and_verify idoit-secrets.yaml idoit-secrets.enc.yaml

echo "--- ghcr-pull-secret (idoit) ---"
cat > ghcr-pull-secret.yaml << EOF
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
          "password": "${GITHUB_PAT}",
          "auth": "${GHCR_AUTH}"
        }
      }
    }
EOF
show_and_confirm "$PROD/apps/idoit/secrets/ghcr-pull-secret.yaml"
encrypt_and_verify ghcr-pull-secret.yaml ghcr-pull-secret.enc.yaml

# =====================================================================
# 10/12: OpenProject App-Secrets
# =====================================================================
echo "=== 10/12: OpenProject App-Secrets ==="
echo "  HINWEIS: s3-keys und oidc-client-secret = Platzhalter (nach Garage/Keycloak)"
cd $PROD/apps/openproject/secrets
cat > openproject-secrets.yaml << EOF
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
  secret-key-base: "${OP_SECRET_KEY}"
  hocuspocus-secret: "${OP_HOCUSPOCUS}"
  database-url: "postgres://openproject:${PW_OPENPROJECT}@cnpg-erp-rw.databases.svc.cluster.local:5432/openproject"
  s3-access-key-id: "PLATZHALTER_GARAGE_DEPLOY"
  s3-secret-access-key: "PLATZHALTER_GARAGE_DEPLOY"
  oidc-client-secret: "PLATZHALTER_KEYCLOAK_DEPLOY"
  smtp-username: "${SMTP_USER}"
  smtp-password: "${SMTP_PASS}"
EOF
show_and_confirm "$PROD/apps/openproject/secrets/openproject-secrets.yaml"
encrypt_and_verify openproject-secrets.yaml openproject-secrets.enc.yaml

# =====================================================================
# 11/12: Odoo App-Secrets + Backup Credentials
# =====================================================================
echo "=== 11/12: Odoo App-Secrets ==="
cd $PROD/apps/odoo/secrets
cat > odoo-secrets.yaml << EOF
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
  db-password: "${PW_ODOO}"
  admin-password: "${ODOO_ADMIN}"
EOF
show_and_confirm "$PROD/apps/odoo/secrets/odoo-secrets.yaml"
encrypt_and_verify odoo-secrets.yaml odoo-secrets.enc.yaml

echo "--- Odoo Backup Credentials ---"
cd $PROD/apps/odoo/backup/secrets
cat > odoo-backup-credentials.yaml << EOF
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
  NAS10_SECRET_ACCESS_KEY: "${NAS10_SECRET}"
EOF
show_and_confirm "$PROD/apps/odoo/backup/secrets/odoo-backup-credentials.yaml"
encrypt_and_verify odoo-backup-credentials.yaml odoo-backup-credentials.enc.yaml

# =====================================================================
# 12/12: it-info-versand App-Secrets + ghcr-pull-secret
# =====================================================================
echo "=== 12/12: it-info-versand App-Secrets ==="
echo "  HINWEIS: keycloak-client-secret = Platzhalter (nach Keycloak-Deploy)"
ITINFO_FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)
cd $PROD/apps/it-info-versand/secrets
cat > it-info-versand-secrets.yaml << EOF
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
  db-password: "${PW_ITINFO}"
  session-secret: "${ITINFO_SESSION}"
  encryption-key: "${ITINFO_FERNET}"
  smtp-username: "${SMTP_USER}"
  smtp-password: "${SMTP_PASS}"
  keycloak-client-secret: "PLATZHALTER_KEYCLOAK_DEPLOY"
EOF
show_and_confirm "$PROD/apps/it-info-versand/secrets/it-info-versand-secrets.yaml"
encrypt_and_verify it-info-versand-secrets.yaml it-info-versand-secrets.enc.yaml

echo "--- ghcr-pull-secret (it-info-versand) ---"
cat > ghcr-pull-secret.yaml << EOF
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
          "password": "${GITHUB_PAT}",
          "auth": "${GHCR_AUTH}"
        }
      }
    }
EOF
show_and_confirm "$PROD/apps/it-info-versand/secrets/ghcr-pull-secret.yaml"
encrypt_and_verify ghcr-pull-secret.yaml ghcr-pull-secret.enc.yaml

# =====================================================================
echo ""
echo "========================================"
echo "FERTIG! Alle Secrets erstellt."
echo "========================================"
echo ""
echo "Verschluesselte Secrets:"
find $PROD -name "*.enc.yaml" -newer $REPO/scripts/generate-prod-secrets.sh | sort
echo ""
echo "NOCH OFFEN (nach Deploy):"
echo "  1. garage-backup-secrets/garage-backup-credentials.enc.yaml (nach Garage-Deploy)"
echo "  2. openproject-secrets: s3-keys aktualisieren (nach Garage-Deploy)"
echo "  3. openproject-secrets: oidc-client-secret (nach Keycloak-Deploy)"
echo "  4. it-info-versand-secrets: keycloak-client-secret (nach Keycloak-Deploy)"
echo ""
echo "Naechster Schritt:"
echo "  cd $REPO"
echo "  git add kubernetes/environments/prod/"
echo "  git commit -m 'Phase 8c: PROD secrets encrypted'"
echo "  git push"
