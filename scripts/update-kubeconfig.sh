#!/usr/bin/env bash
# =============================================================================
# update-kubeconfig.sh
# Mergt kubeconfig-Dateien für DEV (K3s), DEV-MicroK8s, TEST und PROD
# zu ~/.kube/config und benennt die Contexts passend um.
#
# Ausführung: auf k8s-mgmt-10
# Usage: ./scripts/update-kubeconfig.sh [--scp]
#        --scp   Optional: Datei nach dem Merge per scp auf andere Hosts verteilen
#
# Erwartete kubeconfig-Dateien im Repo-Root:
#   kubeconfig-dev.yaml          → Context: k8s-dev            (K3s, k8s-dev-21/22/23)
#   kubeconfig-dev-microk8s.yaml → Context: k8s-dev-microk8s   (MicroK8s, k8s-dev-01/02/03)
#   kubeconfig-test.yaml         → Context: k8s-test           (K3s, k8s-test-21/22/23)
#   kubeconfig-prod.yaml         → Context: k8s-prod           (K3s, k8s-prod-21/22/23)
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_DEV="${REPO_DIR}/kubeconfig-dev.yaml"
KUBECONFIG_DEV_MICROK8S="${REPO_DIR}/kubeconfig-dev-microk8s.yaml"
KUBECONFIG_TEST="${REPO_DIR}/kubeconfig-test.yaml"
KUBECONFIG_PROD="${REPO_DIR}/kubeconfig-prod.yaml"
KUBE_CONFIG_TARGET="${HOME}/.kube/config"

# MicroK8s API-Server (k8s-dev-01)
MICROK8S_API_IP="192.168.180.11"
MICROK8S_API_PORT="16443"

# Hosts für optionale scp-Verteilung – bei Bedarf eintragen
SCP_HOSTS=(
  # "admin-ubuntu@<macmini-ip>"
  # "admin-ubuntu@<macbook-ip>"
  # "dhenke@<windows-ip>"
)

# -----------------------------------------------------------------------------
echo "==> Prüfe kubeconfig-Dateien in ${REPO_DIR}..."

FOUND_FILES=()

if [[ -f "${KUBECONFIG_DEV}" ]]; then
  echo "    [OK] kubeconfig-dev.yaml"
  FOUND_FILES+=("${KUBECONFIG_DEV}")
else
  echo "    [SKIP] kubeconfig-dev.yaml nicht gefunden"
fi

if [[ -f "${KUBECONFIG_DEV_MICROK8S}" ]]; then
  echo "    [OK] kubeconfig-dev-microk8s.yaml"
  FOUND_FILES+=("${KUBECONFIG_DEV_MICROK8S}")
else
  echo "    [SKIP] kubeconfig-dev-microk8s.yaml nicht gefunden"
fi

if [[ -f "${KUBECONFIG_TEST}" ]]; then
  echo "    [OK] kubeconfig-test.yaml"
  FOUND_FILES+=("${KUBECONFIG_TEST}")
else
  echo "    [SKIP] kubeconfig-test.yaml nicht gefunden"
fi

if [[ -f "${KUBECONFIG_PROD}" ]]; then
  echo "    [OK] kubeconfig-prod.yaml"
  FOUND_FILES+=("${KUBECONFIG_PROD}")
else
  echo "    [SKIP] kubeconfig-prod.yaml nicht gefunden"
fi

if [[ ${#FOUND_FILES[@]} -eq 0 ]]; then
  echo "FEHLER: Keine kubeconfig-Dateien gefunden in ${REPO_DIR}"
  exit 1
fi

# -----------------------------------------------------------------------------
echo "==> Benenne Contexts um..."

# K3s kubeconfigs: default → umbenannt
if [[ -f "${KUBECONFIG_DEV}" ]]; then
  sed -i.bak 's/: default$/: k8s-dev/g' "${KUBECONFIG_DEV}"
  echo "    [OK] kubeconfig-dev.yaml:  default → k8s-dev"
fi

if [[ -f "${KUBECONFIG_TEST}" ]]; then
  sed -i.bak 's/: default$/: k8s-test/g' "${KUBECONFIG_TEST}"
  echo "    [OK] kubeconfig-test.yaml: default → k8s-test"
fi

if [[ -f "${KUBECONFIG_PROD}" ]]; then
  sed -i.bak 's/: default$/: k8s-prod/g' "${KUBECONFIG_PROD}"
  echo "    [OK] kubeconfig-prod.yaml: default → k8s-prod"
fi

# MicroK8s kubeconfig: microk8s-* → k8s-dev-microk8s + Server-URL korrigieren
if [[ -f "${KUBECONFIG_DEV_MICROK8S}" ]]; then
  sed -i.bak \
    -e 's/: microk8s-cluster$/: k8s-dev-microk8s/g' \
    -e 's/: microk8s$/: k8s-dev-microk8s/g' \
    -e 's/: admin$/: k8s-dev-microk8s/g' \
    -e "s|https://127.0.0.1:16443|https://${MICROK8S_API_IP}:${MICROK8S_API_PORT}|g" \
    "${KUBECONFIG_DEV_MICROK8S}"
  echo "    [OK] kubeconfig-dev-microk8s.yaml: microk8s-* → k8s-dev-microk8s"
  echo "    [OK] kubeconfig-dev-microk8s.yaml: Server 127.0.0.1:16443 → ${MICROK8S_API_IP}:${MICROK8S_API_PORT}"
fi

# -----------------------------------------------------------------------------
echo "==> Merge zu ${KUBE_CONFIG_TARGET}..."

mkdir -p "${HOME}/.kube"

# Backup der bestehenden config
if [[ -f "${KUBE_CONFIG_TARGET}" ]]; then
  cp "${KUBE_CONFIG_TARGET}" "${KUBE_CONFIG_TARGET}.bak"
  echo "    [OK] Backup: ${KUBE_CONFIG_TARGET}.bak"
fi

# Merge aller gefundenen Dateien
KUBECONFIG_MERGE=$(IFS=':'; echo "${FOUND_FILES[*]}")
KUBECONFIG="${KUBECONFIG_MERGE}" kubectl config view --merge --flatten > "${KUBE_CONFIG_TARGET}"

chmod 600 "${KUBE_CONFIG_TARGET}"
echo "    [OK] Berechtigungen gesetzt (600)"

# -----------------------------------------------------------------------------
echo ""
echo "==> Verfügbare Contexts:"
kubectl config get-contexts

# -----------------------------------------------------------------------------
# Optionale scp-Verteilung
if [[ "${1:-}" == "--scp" ]]; then
  echo ""
  if [[ ${#SCP_HOSTS[@]} -eq 0 ]]; then
    echo "    [WARN] --scp angegeben, aber keine SCP_HOSTS konfiguriert."
    echo "           Bitte Hosts oben im Script eintragen."
  else
    echo "==> Verteile config per scp..."
    for HOST in "${SCP_HOSTS[@]}"; do
      echo -n "    --> ${HOST} ... "
      scp "${KUBE_CONFIG_TARGET}" "${HOST}:~/.kube/config" && echo "[OK]" || echo "[FEHLER]"
    done
  fi
fi

# -----------------------------------------------------------------------------
echo ""
echo "==> Fertig! Context wechseln mit:"
echo "    kubectl config use-context k8s-dev"
echo "    kubectl config use-context k8s-dev-microk8s"
echo "    kubectl config use-context k8s-test"
echo "    kubectl config use-context k8s-prod"
