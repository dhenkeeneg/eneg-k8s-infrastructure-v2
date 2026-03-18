#!/usr/bin/env bash
# =============================================================================
# update-kubeconfig.sh
# Mergt kubeconfig-Dateien für DEV und TEST zu ~/.kube/config
# Usage: ./scripts/update-kubeconfig.sh [--scp]
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_DEV="${REPO_DIR}/kubeconfig-dev.yaml"
KUBECONFIG_TEST="${REPO_DIR}/kubeconfig-test.yaml"
KUBE_CONFIG_TARGET="${HOME}/.kube/config"

# Hosts für optionale scp-Verteilung – bei Bedarf eintragen
SCP_HOSTS=(
  # "dhenke@<macmini-ip>"
  # "dhenke@<macbook-ip>"
  # "dhenke@<windows-ip>"
)

echo "==> Prüfe kubeconfig-Dateien in ${REPO_DIR}..."
FOUND_ANY=false
[[ -f "${KUBECONFIG_DEV}" ]]  && { echo "    [OK] kubeconfig-dev.yaml";  FOUND_ANY=true; } || echo "    [SKIP] kubeconfig-dev.yaml nicht gefunden"
[[ -f "${KUBECONFIG_TEST}" ]] && { echo "    [OK] kubeconfig-test.yaml"; FOUND_ANY=true; } || echo "    [SKIP] kubeconfig-test.yaml nicht gefunden"
[[ "${FOUND_ANY}" == "false" ]] && { echo "FEHLER: Keine kubeconfig-Dateien gefunden"; exit 1; }

echo "==> Benenne Contexts um..."
[[ -f "${KUBECONFIG_DEV}" ]]  && { sed -i.bak 's/: default$/: k8s-dev/g'  "${KUBECONFIG_DEV}";  echo "    [OK] kubeconfig-dev.yaml:  default → k8s-dev"; }
[[ -f "${KUBECONFIG_TEST}" ]] && { sed -i.bak 's/: default$/: k8s-test/g' "${KUBECONFIG_TEST}"; echo "    [OK] kubeconfig-test.yaml: default → k8s-test"; }

echo "==> Merge zu ${KUBE_CONFIG_TARGET}..."
mkdir -p "${HOME}/.kube"
[[ -f "${KUBE_CONFIG_TARGET}" ]] && { cp "${KUBE_CONFIG_TARGET}" "${KUBE_CONFIG_TARGET}.bak"; echo "    [OK] Backup: ${KUBE_CONFIG_TARGET}.bak"; }

if [[ -f "${KUBECONFIG_DEV}" && -f "${KUBECONFIG_TEST}" ]]; then
  KUBECONFIG="${KUBECONFIG_DEV}:${KUBECONFIG_TEST}" kubectl config view --merge --flatten > "${KUBE_CONFIG_TARGET}"
elif [[ -f "${KUBECONFIG_DEV}" ]]; then
  KUBECONFIG="${KUBECONFIG_DEV}" kubectl config view --merge --flatten > "${KUBE_CONFIG_TARGET}"
else
  KUBECONFIG="${KUBECONFIG_TEST}" kubectl config view --merge --flatten > "${KUBE_CONFIG_TARGET}"
fi

chmod 600 "${KUBE_CONFIG_TARGET}"
echo "    [OK] Berechtigungen gesetzt (600)"

echo ""
echo "==> Verfügbare Contexts:"
kubectl config get-contexts

if [[ "${1:-}" == "--scp" ]]; then
  echo ""
  if [[ ${#SCP_HOSTS[@]} -eq 0 ]]; then
    echo "    [WARN] --scp angegeben, aber keine SCP_HOSTS konfiguriert."
  else
    echo "==> Verteile config per scp..."
    for HOST in "${SCP_HOSTS[@]}"; do
      echo -n "    --> ${HOST} ... "
      scp "${KUBE_CONFIG_TARGET}" "${HOST}:~/.kube/config" && echo "[OK]" || echo "[FEHLER]"
    done
  fi
fi

echo ""
echo "==> Fertig! Context wechseln mit:"
echo "    kubectl config use-context k8s-dev"
echo "    kubectl config use-context k8s-test"
