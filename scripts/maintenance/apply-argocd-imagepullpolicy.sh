#!/usr/bin/env bash
# =============================================================================
# Apply ArgoCD imagePullPolicy Patches
# =============================================================================
# Wendet die Strategic Merge Patches aus
#   kubernetes/base/argocd/argocd-imagepullpolicy-patch.yaml
# auf alle 7 ArgoCD-Workloads im Ziel-Cluster an.
#
# Pattern analog zu argocd-repo-server-ksops-patch.yaml:
# ArgoCD kann sich nicht selbst patchen, deshalb manueller Apply per Skript.
#
# Aufruf:
#   ./apply-argocd-imagepullpolicy.sh <kubectl-context>
#
# Beispiel:
#   ./apply-argocd-imagepullpolicy.sh k8s-dev
#   ./apply-argocd-imagepullpolicy.sh k8s-test
#   ./apply-argocd-imagepullpolicy.sh k8s-prod
#
# Eigenschaften:
#   - Idempotent (mehrfacher Aufruf ist ungefaehrlich)
#   - Kein externer Abhaengigkeit ausser kubectl + bash + awk
#   - Verifiziert das Ergebnis am Ende
# =============================================================================

set -euo pipefail

CONTEXT="${1:-}"

usage() {
  cat <<EOF
Usage: $0 <kubectl-context>

Verfuegbare Contexts: k8s-dev | k8s-test | k8s-prod

Setzt imagePullPolicy: IfNotPresent fuer alle ArgoCD-Workloads.
Hintergrund: ArgoCD kann sich nicht selbst patchen, deshalb manueller Apply.
EOF
}

if [[ -z "$CONTEXT" ]]; then
  usage
  exit 1
fi

# --- Validierung ------------------------------------------------------------

if ! command -v kubectl >/dev/null 2>&1; then
  echo "FEHLER: kubectl nicht im PATH gefunden." >&2
  exit 1
fi

if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CONTEXT}"; then
  echo "FEHLER: Context '${CONTEXT}' nicht in kubectl-Konfiguration gefunden." >&2
  echo "Verfuegbare Contexts:" >&2
  kubectl config get-contexts -o name >&2
  exit 1
fi

# --- Pfade ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PATCH_FILE="${REPO_ROOT}/kubernetes/base/argocd/argocd-imagepullpolicy-patch.yaml"

if [[ ! -f "${PATCH_FILE}" ]]; then
  echo "FEHLER: Patch-Datei nicht gefunden: ${PATCH_FILE}" >&2
  exit 1
fi

echo "=========================================="
echo "ArgoCD imagePullPolicy Patch Apply"
echo "=========================================="
echo "Cluster:    ${CONTEXT}"
echo "Patch-File: ${PATCH_FILE}"
echo ""

# --- Multi-Doc YAML in Einzeldateien splitten -------------------------------

TMPDIR=$(mktemp -d -t argocd-patch.XXXXXX)
trap 'rm -rf "${TMPDIR}"' EXIT

# Splittet die Multi-Doc YAML an "---" Markern in einzelne Dateien.
# Erste Sektion (vor erstem ---) wird auch erfasst und bei Verarbeitung gefiltert.
awk -v tmpdir="${TMPDIR}" '
BEGIN { i = 0; outfile = sprintf("%s/patch-00.yaml", tmpdir) }
/^---[[:space:]]*$/ {
  i++
  outfile = sprintf("%s/patch-%02d.yaml", tmpdir, i)
  next
}
{ print > outfile }
' "${PATCH_FILE}"

# --- Patches applizieren ----------------------------------------------------

APPLIED=0
SKIPPED=0
FAILED=0

for f in "${TMPDIR}"/patch-*.yaml; do
  # Nur Dateien mit kind:-Eintrag verarbeiten (Header-Kommentar ueberspringen)
  if ! grep -qE '^kind:[[:space:]]+(Deployment|StatefulSet)[[:space:]]*$' "${f}"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  KIND_RAW=$(grep -E '^kind:[[:space:]]+' "${f}" | head -1 | awk '{print $2}')
  NAME=$(awk '/^metadata:/{flag=1; next} flag && /^[^[:space:]]/{flag=0} flag && /^[[:space:]]+name:/{print $2; exit}' "${f}")
  NS=$(awk '/^metadata:/{flag=1; next} flag && /^[^[:space:]]/{flag=0} flag && /^[[:space:]]+namespace:/{print $2; exit}' "${f}")

  KIND_LC=$(echo "${KIND_RAW}" | tr '[:upper:]' '[:lower:]')

  if [[ -z "${KIND_LC}" || -z "${NAME}" || -z "${NS}" ]]; then
    echo "WARN: Unvollstaendige Patch-Datei (${f}), ueberspringe."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  printf "  -> %s/%s in %s ... " "${KIND_LC}" "${NAME}" "${NS}"

  if kubectl --context "${CONTEXT}" patch "${KIND_LC}" "${NAME}" -n "${NS}" \
       --type=strategic --patch-file "${f}" >/dev/null 2>&1; then
    echo "OK"
    APPLIED=$((APPLIED + 1))
  else
    echo "FEHLER"
    echo "       Details:"
    kubectl --context "${CONTEXT}" patch "${KIND_LC}" "${NAME}" -n "${NS}" \
       --type=strategic --patch-file "${f}" 2>&1 | sed 's/^/       /'
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Zusammenfassung ==="
echo "Patched:   ${APPLIED}"
echo "Skipped:   ${SKIPPED}"
echo "Failed:    ${FAILED}"
echo ""

# --- Verifikation -----------------------------------------------------------

echo "=== Verifikation: aktuelle imagePullPolicy ==="
echo ""
printf "%-50s %-30s %-15s\n" "WORKLOAD" "CONTAINER" "PULL_POLICY"
printf "%-50s %-30s %-15s\n" "--------" "---------" "-----------"

# Deployments
for d in argocd-applicationset-controller argocd-dex-server argocd-notifications-controller \
         argocd-redis argocd-repo-server argocd-server; do
  policies=$(kubectl --context "${CONTEXT}" get deployment "${d}" -n argocd \
             -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.imagePullPolicy};{end}' 2>/dev/null || echo "n/a")
  if [[ "${policies}" == "n/a" ]]; then
    printf "%-50s %-30s %-15s\n" "deployment/${d}" "(nicht gefunden)" "-"
    continue
  fi
  IFS=';' read -ra ENTRIES <<< "${policies}"
  for e in "${ENTRIES[@]}"; do
    [[ -z "${e}" ]] && continue
    cname="${e%%=*}"
    cpolicy="${e##*=}"
    printf "%-50s %-30s %-15s\n" "deployment/${d}" "${cname}" "${cpolicy}"
  done
  # InitContainers
  init_policies=$(kubectl --context "${CONTEXT}" get deployment "${d}" -n argocd \
                  -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name}={.imagePullPolicy};{end}' 2>/dev/null || echo "")
  IFS=';' read -ra IENTRIES <<< "${init_policies}"
  for e in "${IENTRIES[@]}"; do
    [[ -z "${e}" ]] && continue
    cname="${e%%=*}"
    cpolicy="${e##*=}"
    printf "%-50s %-30s %-15s\n" "deployment/${d}" "init:${cname}" "${cpolicy}"
  done
done

# StatefulSet
ss_policy=$(kubectl --context "${CONTEXT}" get statefulset argocd-application-controller -n argocd \
            -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.imagePullPolicy};{end}' 2>/dev/null || echo "n/a")
IFS=';' read -ra ENTRIES <<< "${ss_policy}"
for e in "${ENTRIES[@]}"; do
  [[ -z "${e}" ]] && continue
  cname="${e%%=*}"
  cpolicy="${e##*=}"
  printf "%-50s %-30s %-15s\n" "statefulset/argocd-application-controller" "${cname}" "${cpolicy}"
done

echo ""
echo "=== Pod-Status (Re-Roll laeuft, falls AGE niedrig) ==="
kubectl --context "${CONTEXT}" get pods -n argocd \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,AGE:.metadata.creationTimestamp
echo ""

if [[ ${FAILED} -gt 0 ]]; then
  echo "FERTIG mit Fehlern (${FAILED} Patches gescheitert)." >&2
  exit 1
fi

echo "FERTIG. Alle Patches erfolgreich angewendet."
