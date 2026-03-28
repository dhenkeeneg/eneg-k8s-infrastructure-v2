#!/bin/bash
# =============================================================================
# Phase 8c PROD: Reparatur-Script fuer fehlende 6 Secrets
# Ausfuehren auf k8s-mgmt-10
# =============================================================================
# Erstellt die 6 fehlenden/kaputten Secrets:
#   1. idoit ghcr-pull-secret (kaputt, neu erstellen)
#   2. openproject-secrets
#   3. odoo-secrets
#   4. odoo-backup-credentials
#   5. it-info-versand-secrets
#   6. it-info-versand ghcr-pull-secret
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
    echo "  FEHLER: $dst ist nur $size Bytes!"
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
  echo ""
  echo "--- Ende ---"
  echo ""
  read -p "OK? Verschluesseln und Klartext loeschen? (j/n) " answer
  if [ "$answer" != "j" ] && [ "$answer" != "y" ]; then
    echo "Abgebrochen. Klartext bleibt: $file"
    exit 1
  fi
}

echo "========================================"
echo "Phase 8c: 6 fehlende PROD Secrets"
echo "========================================"
echo ""

# --- Externe Werte abfragen ---
read -p "NAS10 S3 Secret Key (s3-k8s-prod): " NAS10_SECRET
read -p "SMTP Username: " SMTP_USER
read -p "SMTP Passwort: " SMTP_PASS
read -p "GitHub PAT (ghcr.io read:packages): " GITHUB_PAT

GHCR_AUTH=$(echo -n "dhenkeeneg:${GITHUB_PAT}" | base64)

# --- DB-Passwoerter aus bereits verschluesselten CNPG-Secrets holen ---
echo "Lese bestehende DB-Passwoerter aus CNPG-Secrets..."
PW_OPENPROJECT=$(sops --decrypt $PROD/cnpg-secrets/openproject-db-credentials.enc.yaml | grep 'password:' | awk '{print $2}' | tr -d '"')
PW_ODOO=$(sops --decrypt $PROD/cnpg-secrets/odoo-db-credentials.enc.yaml | grep 'password:' | awk '{print $2}' | tr -d '"')
PW_ITINFO=$(sops --decrypt $PROD/cnpg-secrets/it-info-versand-db-credentials.enc.yaml | grep 'password:' | awk '{print $2}' | tr -d '"')
echo "  OpenProject DB-PW: ${PW_OPENPROJECT:0:8}..."
echo "  Odoo DB-PW: ${PW_ODOO:0:8}..."
echo "  it-info-versand DB-PW: ${PW_ITINFO:0:8}..."
echo ""

# --- App-spezifische Keys generieren ---
ODOO_ADMIN=$(openssl rand -hex 24)
OP_SECRET_KEY=$(openssl rand -hex 64)
OP_HOCUSPOCUS=$(openssl rand -hex 32)
ITINFO_SESSION=$(openssl rand -hex 32)
ITINFO_FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)

echo "App-Keys generiert."
echo ""

# =====================================================================
# 1/6: idoit ghcr-pull-secret (kaputt, neu erstellen)
# =====================================================================
echo "=== 1/6: idoit ghcr-pull-secret (Reparatur) ==="
cd $PROD/apps/idoit/secrets
rm -f ghcr-pull-secret.enc.yaml

# GHCR-Secret per Python schreiben (vermeidet heredoc/YAML-Escaping)
python3 -c "
import json, yaml

doc = {
    'apiVersion': 'v1',
    'kind': 'Secret',
    'metadata': {
        'name': 'ghcr-pull-secret',
        'namespace': 'idoit',
        'labels': {
            'app.kubernetes.io/managed-by': 'argocd'
        }
    },
    'type': 'kubernetes.io/dockerconfigjson',
    'stringData': {
        '.dockerconfigjson': json.dumps({
            'auths': {
                'ghcr.io': {
                    'username': 'dhenkeeneg',
                    'password': '${GITHUB_PAT}',
                    'auth': '${GHCR_AUTH}'
                }
            }
        })
    }
}

with open('ghcr-pull-secret.yaml', 'w') as f:
    f.write('---\n')
    yaml.dump(doc, f, default_flow_style=False, allow_unicode=True)
"

show_and_confirm "$PROD/apps/idoit/secrets/ghcr-pull-secret.yaml"
encrypt_and_verify ghcr-pull-secret.yaml ghcr-pull-secret.enc.yaml

# =====================================================================
# 2/6: OpenProject App-Secrets
# =====================================================================
echo "=== 2/6: OpenProject App-Secrets ==="
echo "  HINWEIS: s3-keys und oidc-client-secret = Platzhalter"
cd $PROD/apps/openproject/secrets
cat > openproject-secrets.yaml << ENDOFYAML
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
ENDOFYAML
show_and_confirm "$PROD/apps/openproject/secrets/openproject-secrets.yaml"
encrypt_and_verify openproject-secrets.yaml openproject-secrets.enc.yaml

# =====================================================================
# 3/6: Odoo App-Secrets
# =====================================================================
echo "=== 3/6: Odoo App-Secrets ==="
cd $PROD/apps/odoo/secrets
cat > odoo-secrets.yaml << ENDOFYAML
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
ENDOFYAML
show_and_confirm "$PROD/apps/odoo/secrets/odoo-secrets.yaml"
encrypt_and_verify odoo-secrets.yaml odoo-secrets.enc.yaml

# =====================================================================
# 4/6: Odoo Backup Credentials
# =====================================================================
echo "=== 4/6: Odoo Backup Credentials ==="
cd $PROD/apps/odoo/backup/secrets
cat > odoo-backup-credentials.yaml << ENDOFYAML
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
ENDOFYAML
show_and_confirm "$PROD/apps/odoo/backup/secrets/odoo-backup-credentials.yaml"
encrypt_and_verify odoo-backup-credentials.yaml odoo-backup-credentials.enc.yaml

# =====================================================================
# 5/6: it-info-versand App-Secrets
# =====================================================================
echo "=== 5/6: it-info-versand App-Secrets ==="
echo "  HINWEIS: keycloak-client-secret = Platzhalter"
cd $PROD/apps/it-info-versand/secrets
cat > it-info-versand-secrets.yaml << ENDOFYAML
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
ENDOFYAML
show_and_confirm "$PROD/apps/it-info-versand/secrets/it-info-versand-secrets.yaml"
encrypt_and_verify it-info-versand-secrets.yaml it-info-versand-secrets.enc.yaml

# =====================================================================
# 6/6: it-info-versand ghcr-pull-secret
# =====================================================================
echo "=== 6/6: it-info-versand ghcr-pull-secret ==="

cd $PROD/apps/it-info-versand/secrets

# GHCR-Secrets per Python schreiben (vermeidet heredoc/YAML-Escaping-Probleme)
python3 -c "
import json, yaml

doc = {
    'apiVersion': 'v1',
    'kind': 'Secret',
    'metadata': {
        'name': 'ghcr-pull-secret',
        'namespace': 'it-info-versand',
        'labels': {
            'app.kubernetes.io/managed-by': 'argocd'
        }
    },
    'type': 'kubernetes.io/dockerconfigjson',
    'stringData': {
        '.dockerconfigjson': json.dumps({
            'auths': {
                'ghcr.io': {
                    'username': 'dhenkeeneg',
                    'password': '${GITHUB_PAT}',
                    'auth': '${GHCR_AUTH}'
                }
            }
        })
    }
}
with open('ghcr-pull-secret.yaml', 'w') as f:
    f.write('---\n')
    yaml.dump(doc, f, default_flow_style=False, allow_unicode=True)
"
show_and_confirm "$PROD/apps/it-info-versand/secrets/ghcr-pull-secret.yaml"
encrypt_and_verify ghcr-pull-secret.yaml ghcr-pull-secret.enc.yaml

# =====================================================================
echo ""
echo "========================================"
echo "FERTIG! 6 fehlende Secrets erstellt."
echo "========================================"
echo ""
echo "Neue verschluesselte Secrets:"
find $PROD -name "*.enc.yaml" | sort
echo ""
echo "NOCH OFFEN (nach Deploy):"
echo "  1. garage-backup-secrets/garage-backup-credentials.enc.yaml"
echo "  2. openproject-secrets: s3-keys aktualisieren"
echo "  3. openproject-secrets: oidc-client-secret aktualisieren"
echo "  4. it-info-versand-secrets: keycloak-client-secret aktualisieren"
echo ""
echo "Naechster Schritt:"
echo "  cd $REPO"
echo "  git add kubernetes/environments/prod/"
echo "  git commit -m 'Phase 8c: PROD secrets encrypted'"
echo "  git push"
