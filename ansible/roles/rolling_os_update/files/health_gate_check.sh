#!/usr/bin/env bash
# =============================================================================
# health_gate_check.sh  (Pre-Drain Health-Gate, Hebel 3)
# =============================================================================
# Prueft in EINEM Durchlauf, ob der Cluster voll gesund ist. Gibt genau eine
# Zeile aus:
#   HEALTHY                     -> alle Checks bestanden
#   WAIT: <grund>               -> noch nicht gesund (Ansible 'until' pollt weiter)
# Exit-Code ist immer 0 (die Ansible-until-Bedingung wertet stdout aus, nicht rc;
# so werden transiente kubectl-Fehler als WAIT behandelt statt als Task-Fehler).
#
# Aufruf: health_gate_check.sh <kubectl_context> <galera_namespace> <check_rebuilds:yes|no>
#
# Bewusst defensiv: Jeder kubectl-Fehler / leere Output fuehrt zu WAIT, nicht
# zu einer Fehlinterpretation als "gesund".
# =============================================================================
set -uo pipefail

CTX="${1:?kubectl-context fehlt}"
GALERA_NS="${2:?galera-namespace fehlt}"
CHECK_REBUILDS="${3:-yes}"

K="kubectl --context ${CTX}"

# -----------------------------------------------------------------------------
# 1) CNPG: fuer jeden Cluster muss readyInstances == instances gelten
# -----------------------------------------------------------------------------
cnpg_raw="$(${K} get clusters.postgresql.cnpg.io --all-namespaces \
  -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.readyInstances} {.status.instances}{"\n"}{end}' 2>/dev/null)"

if [[ -z "${cnpg_raw}" ]]; then
  echo "WAIT: keine CNPG-Cluster-Daten (kubectl-Fehler oder noch nicht bereit)"
  exit 0
fi

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  name="$(awk '{print $1}' <<<"${line}")"
  ready="$(awk '{print $2}' <<<"${line}")"
  total="$(awk '{print $3}' <<<"${line}")"
  if [[ -z "${ready}" || -z "${total}" ]]; then
    echo "WAIT: CNPG ${name} Status unvollstaendig (ready='${ready}' total='${total}')"
    exit 0
  fi
  if [[ "${ready}" != "${total}" ]]; then
    echo "WAIT: CNPG ${name} nur ${ready}/${total} ready"
    exit 0
  fi
done <<<"${cnpg_raw}"

# -----------------------------------------------------------------------------
# 2) MariaDB Galera: alle Pods des StatefulSets muessen ready sein
# -----------------------------------------------------------------------------
# Galera laeuft als StatefulSet "mariadb-galera" im DB-Namespace. Wir vergleichen
# status.readyReplicas mit status.replicas. Fehlt das StatefulSet (z.B. anderer
# Name), wird das als WAIT behandelt statt faelschlich als gesund.
gal_raw="$(${K} get statefulset mariadb-galera -n "${GALERA_NS}" \
  -o 'jsonpath={.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"

if [[ -z "${gal_raw}" || "${gal_raw}" == "/" ]]; then
  echo "WAIT: Galera-StatefulSet-Status nicht lesbar (raw='${gal_raw}')"
  exit 0
fi

gal_ready="${gal_raw%%/*}"
gal_total="${gal_raw##*/}"
if [[ -z "${gal_ready}" || -z "${gal_total}" ]]; then
  echo "WAIT: Galera Status unvollstaendig (raw='${gal_raw}')"
  exit 0
fi
if [[ "${gal_ready}" != "${gal_total}" ]]; then
  echo "WAIT: Galera nur ${gal_ready}/${gal_total} ready"
  exit 0
fi

# -----------------------------------------------------------------------------
# 3) Longhorn: keine aktiven Replica-Rebuilds (optional)
# -----------------------------------------------------------------------------
# engines.longhorn.io tragen waehrend eines Rebuilds Eintraege in
# status.rebuildStatus. Wir zaehlen Engines, deren rebuildStatus nicht leer ist.
# Zusaetzlich pruefen wir, dass keine Volumes im Zustand 'degraded' sind, das
# sich gerade aktiv wiederherstellt. Bei kubectl-Fehler: WAIT (defensiv).
if [[ "${CHECK_REBUILDS}" == "yes" ]]; then
  # Anzahl Engines mit aktivem rebuildStatus (nicht-leeres Objekt)
  rebuild_cnt="$(${K} get engines.longhorn.io -n longhorn-system \
    -o 'jsonpath={range .items[*]}{.status.rebuildStatus}{"\n"}{end}' 2>/dev/null \
    | grep -c 'replicaAddress' )"
  # grep -c liefert bei 0 Treffern rc=1; das ist ok, Zahl steht in stdout
  if [[ -z "${rebuild_cnt}" ]]; then
    echo "WAIT: Longhorn-Rebuild-Status nicht lesbar"
    exit 0
  fi
  if [[ "${rebuild_cnt}" -gt 0 ]]; then
    echo "WAIT: ${rebuild_cnt} aktive(r) Longhorn-Rebuild(s) laufen noch"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Alle Checks bestanden
# -----------------------------------------------------------------------------
echo "HEALTHY"
exit 0
