#!/bin/bash
# =============================================================================
# Phase 8c PROD: Reparatur — 6 fehlende Secrets
# Ausfuehren auf k8s-mgmt-10
# =============================================================================
# Fuer jedes Secret:
#   1. Kopiert Template -> YAML
#   2. Generiert Passwoerter und traegt sie per sed ein
#   3. Zeigt die fertige Datei an
#   4. Verschluesselt mit SOPS nach Bestaetigung
#   5. Loescht Klartext
#
# GHCR-Secrets: Template wird kopiert, PAT + auth manuell eingetragen per nano
# =============================================================================

set -e
REPO=~/git/eneg-k8s-infrastructure-v2
PROD=$REPO/kubernetes/environments/prod
AGE="age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm"
SOPS_ENC="sops --encrypt --age $AGE --encrypted-regex ^(data|stringData)$"

encrypt_and_verify() {
  local src="$1"
  local enc="$2"
  sops --encrypt --age "$AGE" --encrypted-regex '^(data|stringData)$' "$src" > "$enc"
  local size=$(wc -c < "$enc")
  if [ "$size" -lt 50 ]; then
    echo "  FEHLER: $enc nur $size Bytes — Verschluesselung fehlgeschlagen!"
    exit 1
  fi
  rm "$src"
  echo "  OK: $enc ($size Bytes)"
}

confirm_and_encrypt() {
  local yaml="$1"
  local enc="$2"
  echo ""
  echo "=== Datei: $yaml ==="
  cat "$yaml"
  echo ""
  read -p "Verschluesseln? (j/n) " answer
  if [ "$answer" != "j" ] && [ "$answer" != "y" ]; then
    echo "Abgebrochen."
    exit 1
  fi
  encrypt_and_verify "$yaml" "$enc"
}

echo "========================================"
echo "Phase 8c: 6 fehlende PROD Secrets"
echo "========================================"

# --- DB-Passwoerter aus bestehenden CNPG-Secrets lesen ---
echo ""
echo "Lese DB-Passwoerter aus bestehenden CNPG-Secrets..."
PW_OP=$(sops --decrypt $PROD/cnpg-secrets/openproject-db-credentials.enc.yaml 2>/dev/null | grep 'password:' | awk '{print $2}' | tr -d '"')
PW_ODOO=$(sops --decrypt $PROD/cnpg-secrets/odoo-db-credentials.enc.yaml 2>/dev/null | grep 'password:' | awk '{print $2}' | tr -d '"')
PW_ITINFO=$(sops --decrypt $PROD/cnpg-secrets/it-info-versand-db-credentials.enc.yaml 2>/dev/null | grep 'password:' | awk '{print $2}' | tr -d '"')
echo "  OpenProject: ${PW_OP:0:8}..."
echo "  Odoo:        ${PW_ODOO:0:8}..."
echo "  IT-Info:     ${PW_ITINFO:0:8}..."


# =====================================================================
# 1/6: idoit ghcr-pull-secret
# =====================================================================
echo ""
echo "=== 1/6: idoit ghcr-pull-secret ==="
echo "Oeffne nano — trage PAT und auth (base64) ein, speichere."
echo "  auth erzeugen: echo -n 'dhenkeeneg:DEIN_PAT' | base64"
cd $PROD/apps/idoit/secrets
rm -f ghcr-pull-secret.enc.yaml
cp ghcr-pull-secret.yaml.template ghcr-pull-secret.yaml
read -p "Enter zum Oeffnen von nano..."
nano ghcr-pull-secret.yaml
confirm_and_encrypt ghcr-pull-secret.yaml ghcr-pull-secret.enc.yaml

# =====================================================================
# 2/6: OpenProject Secrets
# =====================================================================
echo ""
echo "=== 2/6: OpenProject Secrets ==="
cd $PROD/apps/openproject/secrets
cp openproject-secrets.yaml.template openproject-secrets.yaml

# Generiere Keys
OP_SKB=$(openssl rand -hex 64)
OP_HPS=$(openssl rand -hex 32)

# Trage generierte Werte + DB-PW ein
sed -i "s|HIER_SECRET_KEY_BASE|${OP_SKB}|" openproject-secrets.yaml
sed -i "s|HIER_HOCUSPOCUS_SECRET|${OP_HPS}|" openproject-secrets.yaml
sed -i "s|HIER_DB_PASSWORT|${PW_OP}|" openproject-secrets.yaml

echo "Generierte Keys eingetragen. SMTP noch manuell eintragen."
echo "Oeffne nano — trage SMTP-Username und SMTP-Passwort ein."
read -p "Enter zum Oeffnen von nano..."
nano openproject-secrets.yaml
confirm_and_encrypt openproject-secrets.yaml openproject-secrets.enc.yaml

# =====================================================================
# 3/6: Odoo Secrets
# =====================================================================
echo ""
echo "=== 3/6: Odoo Secrets ==="
cd $PROD/apps/odoo/secrets
cp odoo-secrets.yaml.template odoo-secrets.yaml

ODOO_ADMIN=$(openssl rand -hex 24)

sed -i "s|HIER_DB_PASSWORT_EINTRAGEN|${PW_ODOO}|" odoo-secrets.yaml
sed -i "s|HIER_ADMIN_PASSWORT_EINTRAGEN|${ODOO_ADMIN}|" odoo-secrets.yaml

confirm_and_encrypt odoo-secrets.yaml odoo-secrets.enc.yaml

# =====================================================================
# 4/6: Odoo Backup Credentials
# =====================================================================
echo ""
echo "=== 4/6: Odoo Backup Credentials ==="
cd $PROD/apps/odoo/backup/secrets
cp odoo-backup-credentials.yaml.template odoo-backup-credentials.yaml

echo "Oeffne nano — trage NAS10 SECRET_ACCESS_KEY ein."
read -p "Enter zum Oeffnen von nano..."
nano odoo-backup-credentials.yaml
confirm_and_encrypt odoo-backup-credentials.yaml odoo-backup-credentials.enc.yaml

# =====================================================================
# 5/6: it-info-versand Secrets
# =====================================================================
echo ""
echo "=== 5/6: it-info-versand Secrets ==="
cd $PROD/apps/it-info-versand/secrets
cp it-info-versand-secrets.yaml.template it-info-versand-secrets.yaml

ITINFO_SESSION=$(openssl rand -hex 32)
ITINFO_FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)

sed -i "s|HIER_DASSELBE_PASSWORT_WIE_IN_DB_CREDENTIALS|${PW_ITINFO}|" it-info-versand-secrets.yaml
sed -i "s|HIER_SESSION_SECRET|${ITINFO_SESSION}|" it-info-versand-secrets.yaml
sed -i "s|HIER_FERNET_KEY|${ITINFO_FERNET}|" it-info-versand-secrets.yaml

echo "DB-PW, Session-Secret und Fernet-Key eingetragen."
echo "Oeffne nano — trage SMTP-Username und SMTP-Passwort ein."
read -p "Enter zum Oeffnen von nano..."
nano it-info-versand-secrets.yaml
confirm_and_encrypt it-info-versand-secrets.yaml it-info-versand-secrets.enc.yaml

# =====================================================================
# 6/6: it-info-versand ghcr-pull-secret
# =====================================================================
echo ""
echo "=== 6/6: it-info-versand ghcr-pull-secret ==="
echo "Oeffne nano — trage PAT und auth (base64) ein (gleich wie bei idoit)."
cd $PROD/apps/it-info-versand/secrets
rm -f ghcr-pull-secret.enc.yaml
cp ghcr-pull-secret.yaml.template ghcr-pull-secret.yaml
read -p "Enter zum Oeffnen von nano..."
nano ghcr-pull-secret.yaml
confirm_and_encrypt ghcr-pull-secret.yaml ghcr-pull-secret.enc.yaml

# =====================================================================
echo ""
echo "========================================"
echo "FERTIG! Alle 6 fehlenden Secrets erstellt."
echo "========================================"
echo ""
echo "Pruefung — alle enc.yaml:"
find $PROD -name "*.enc.yaml" | sort
echo ""
echo "Anzahl: $(find $PROD -name '*.enc.yaml' | wc -l) (erwartet: 19)"
echo ""
echo "Naechster Schritt auf k8s-mgmt-10:"
echo "  cd $REPO"
echo "  git add kubernetes/environments/prod/"
echo "  git commit -m 'Phase 8c: PROD secrets encrypted'"
echo "  git push"
