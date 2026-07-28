#!/usr/bin/env bash
# =============================================================================
# health_gate_check.sh  (Health-Gate fuer Rolling-OS-Update)
# =============================================================================
# Prueft in EINEM Durchlauf, ob der Cluster voll gesund ist. Gibt genau eine
# Zeile aus:
#   HEALTHY        -> alle aktivierten Checks bestanden
#   WAIT: <grund>  -> noch nicht gesund (Ansible 'until' pollt weiter)
# Exit-Code ist immer 0. Die until-Bedingung wertet stdout aus, nicht rc, damit
# transiente kubectl-Fehler als WAIT behandelt werden und nicht als Task-Fehler.
#
# Aufruf ueber Umgebungsvariablen (frueher Positionsargumente - bei sieben
# Schaltern nicht mehr lesbar):
#   HG_CTX                   kubectl-Context                        (Pflicht)
#   HG_GALERA_NS             Namespace des Galera-StatefulSets      (databases)
#   HG_CHECK_REBUILDS        aktive Longhorn-Rebuilds pruefen       (yes)
#   HG_CHECK_LH_ROBUSTNESS   Longhorn-Volume-Robustness pruefen     (yes)
#   HG_CHECK_CNPG_TIMELINE   CNPG-Timeline und Primary pruefen      (yes)
#   HG_CHECK_NODES           Node-Ready und Restcordons pruefen     (yes)
#   HG_CHECK_PENDING_PODS    nicht schedulebare Pods pruefen        (yes)
#   HG_ALLOW_CORDONED        Nodes, die cordoned sein DUERFEN       (leer)
#                            komma-separiert, Escape-Hatch
#
# Feldtrenner in allen jsonpath-Ausgaben ist '|', nicht Whitespace: fehlende
# Felder (z.B. nicht gesetztes .spec.unschedulable) wuerden bei Whitespace die
# Spalten verschieben und zu Fehlurteilen fuehren.
#
# Reihenfolge der Checks ist nach diagnostischer Aussagekraft sortiert - ein
# NotReady-Node erklaert die Folgefehler, also kommt er zuerst. Der erste
# blockierende Check bestimmt die WAIT-Meldung.
#
# Hintergrund:
#   docs/incidents/2026-07-23-dev-os-update-rebuild-storm.md
#   Erweiterung 2026-07-28 nach Timeline-Divergenz cnpg-shared-3 (DEV).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CTX="${HG_CTX:?HG_CTX (kubectl-Context) fehlt}"
GALERA_NS="${HG_GALERA_NS:-databases}"
CHECK_REBUILDS="${HG_CHECK_REBUILDS:-yes}"
CHECK_LH_ROBUSTNESS="${HG_CHECK_LH_ROBUSTNESS:-yes}"
CHECK_CNPG_TIMELINE="${HG_CHECK_CNPG_TIMELINE:-yes}"
CHECK_NODES="${HG_CHECK_NODES:-yes}"
CHECK_PENDING_PODS="${HG_CHECK_PENDING_PODS:-yes}"
ALLOW_CORDONED="${HG_ALLOW_CORDONED:-}"

K="kubectl --context ${CTX}"

# Einheitlicher Ausstieg: eine Zeile, rc 0.
wait_out() { echo "WAIT: $1"; exit 0; }

# -----------------------------------------------------------------------------
# 1) Nodes: alle Ready, keiner unerwartet cordoned
# -----------------------------------------------------------------------------
# Adressiert den Fall k8s-prod-23 (25.-28.07.2026): ein Node blieb nach einem
# abgebrochenen Wartungsfenster drei Tage cordoned, wodurch drei DB-Pods
# dauerhaft Pending waren. Das faellt hier sofort auf.
if [[ "${CHECK_NODES}" == "yes" ]]; then
  nodes_raw="$(${K} get nodes -o 'jsonpath={range .items[*]}{.metadata.name}|{.spec.unschedulable}|{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null)"

  [[ -z "${nodes_raw}" ]] && wait_out "Node-Liste nicht lesbar (kubectl-Fehler?)"

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    IFS='|' read -r n_name n_unsched n_ready <<<"${line}"

    if [[ "${n_ready}" != "True" ]]; then
      wait_out "Node ${n_name} nicht Ready (Ready=${n_ready:-unbekannt})"
    fi
    if [[ "${n_unsched}" == "true" && ",${ALLOW_CORDONED}," != *",${n_name},"* ]]; then
      wait_out "Node ${n_name} ist cordoned (SchedulingDisabled) - Restcordon aus einem frueheren Lauf?"
    fi
  done <<<"${nodes_raw}"
fi

# -----------------------------------------------------------------------------
# 2) CNPG: readyInstances == spec.instances, kein Switchover, eine Timeline
# -----------------------------------------------------------------------------
# Referenz ist bewusst .spec.instances (Soll) und nicht .status.instances (Ist):
# fehlt ein Pod komplett, sinkt .status.instances mit, und ready==status waere
# faelschlich erfuellt.
cnpg_raw="$(${K} get clusters.postgresql.cnpg.io --all-namespaces -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}|{.status.readyInstances}|{.spec.instances}|{.status.currentPrimary}|{.status.targetPrimary}{"\n"}{end}' 2>/dev/null)"

if [[ -z "${cnpg_raw}" ]]; then
  wait_out "keine CNPG-Cluster-Daten (kubectl-Fehler oder noch nicht bereit)"
fi

if [[ "${CHECK_CNPG_TIMELINE}" == "yes" ]] && ! command -v python3 >/dev/null 2>&1; then
  wait_out "python3 auf dem Ansible-Controller nicht gefunden (fuer CNPG-Timeline-Check erforderlich)"
fi

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  IFS='|' read -r c_full c_ready c_total c_cur c_tgt <<<"${line}"
  c_ns="${c_full%%/*}"
  c_name="${c_full##*/}"

  if [[ -z "${c_ready}" || -z "${c_total}" ]]; then
    wait_out "CNPG ${c_full} Status unvollstaendig (ready='${c_ready}' soll='${c_total}')"
  fi
  if [[ "${c_ready}" != "${c_total}" ]]; then
    wait_out "CNPG ${c_full} nur ${c_ready}/${c_total} ready"
  fi

  [[ "${CHECK_CNPG_TIMELINE}" != "yes" ]] && continue

  if [[ -z "${c_cur}" ]]; then
    wait_out "CNPG ${c_full}: currentPrimary noch nicht gesetzt"
  fi
  if [[ "${c_cur}" != "${c_tgt}" ]]; then
    wait_out "CNPG ${c_full}: Switchover laeuft (currentPrimary=${c_cur}, targetPrimary=${c_tgt})"
  fi

  c_irs="$(${K} get clusters.postgresql.cnpg.io "${c_name}" -n "${c_ns}" -o 'jsonpath={.status.instancesReportedState}' 2>/dev/null)"
  if [[ -z "${c_irs}" ]]; then
    wait_out "CNPG ${c_full}: instancesReportedState leer"
  fi

  c_verdict="$(python3 "${SCRIPT_DIR}/hg_cnpg_timeline.py" "${c_irs}" "${c_total}" 2>&1)"
  if [[ "${c_verdict}" != "OK" ]]; then
    wait_out "CNPG ${c_full}: ${c_verdict}"
  fi
done <<<"${cnpg_raw}"

# -----------------------------------------------------------------------------
# 3) MariaDB Galera: alle Pods des StatefulSets ready
# -----------------------------------------------------------------------------
# Fehlt das StatefulSet (z.B. anderer Name), wird das als WAIT behandelt statt
# faelschlich als gesund.
gal_raw="$(${K} get statefulset mariadb-galera -n "${GALERA_NS}" -o 'jsonpath={.status.readyReplicas}|{.status.replicas}' 2>/dev/null)"

if [[ -z "${gal_raw}" || "${gal_raw}" == "|" ]]; then
  wait_out "Galera-StatefulSet-Status nicht lesbar (raw='${gal_raw}')"
fi

IFS='|' read -r gal_ready gal_total <<<"${gal_raw}"
if [[ -z "${gal_ready}" || -z "${gal_total}" ]]; then
  wait_out "Galera Status unvollstaendig (raw='${gal_raw}')"
fi
if [[ "${gal_ready}" != "${gal_total}" ]]; then
  wait_out "Galera nur ${gal_ready}/${gal_total} ready"
fi

# -----------------------------------------------------------------------------
# 4) Longhorn: Volume-Robustness
# -----------------------------------------------------------------------------
# Der Rebuild-Check (Block 5) sieht nur LAUFENDE Rebuilds. Wir haben
# replicaReplenishmentWaitInterval=1200s gesetzt - bis zu 20 Minuten nach
# Rueckkehr eines Nodes existiert also ein degradiertes Volume, fuer das noch
# KEIN Rebuild laeuft. Ohne diesen Block meldet das Gate in diesem Fenster
# HEALTHY, der naechste Drain startet, und der Rebuild springt mitten hinein.
#
# Detached Volumes melden robustness='unknown' - das ist der Normalzustand
# ungenutzter Volumes und darf NICHT blockieren. Geprueft wird daher nur:
#   - attached Volumes muessen 'healthy' sein
#   - 'faulted' blockiert immer, unabhaengig vom State
if [[ "${CHECK_LH_ROBUSTNESS}" == "yes" ]]; then
  lh_raw="$(${K} get volumes.longhorn.io -n longhorn-system -o 'jsonpath={range .items[*]}{.metadata.name}|{.status.state}|{.status.robustness}{"\n"}{end}' 2>/dev/null)"

  [[ -z "${lh_raw}" ]] && wait_out "Longhorn-Volume-Liste nicht lesbar"

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    IFS='|' read -r v_name v_state v_rob <<<"${line}"

    if [[ "${v_rob}" == "faulted" ]]; then
      wait_out "Longhorn-Volume ${v_name} ist FAULTED (state=${v_state:-unbekannt})"
    fi
    if [[ "${v_state}" == "attached" && "${v_rob}" != "healthy" ]]; then
      wait_out "Longhorn-Volume ${v_name} attached, aber robustness=${v_rob:-unbekannt} (Rebuild steht ggf. noch aus, replicaReplenishmentWaitInterval)"
    fi
  done <<<"${lh_raw}"
fi

# -----------------------------------------------------------------------------
# 5) Longhorn: keine aktiven Replica-Rebuilds
# -----------------------------------------------------------------------------
# engines.longhorn.io tragen waehrend eines Rebuilds Eintraege in
# status.rebuildStatus. Gezaehlt werden Engines mit nicht-leerem rebuildStatus.
if [[ "${CHECK_REBUILDS}" == "yes" ]]; then
  rebuild_cnt="$(${K} get engines.longhorn.io -n longhorn-system -o 'jsonpath={range .items[*]}{.status.rebuildStatus}{"\n"}{end}' 2>/dev/null | grep -c 'replicaAddress')"
  # grep -c liefert bei 0 Treffern rc=1; das ist ok, die Zahl steht in stdout.
  if [[ -z "${rebuild_cnt}" ]]; then
    wait_out "Longhorn-Rebuild-Status nicht lesbar"
  fi
  if [[ "${rebuild_cnt}" -gt 0 ]]; then
    wait_out "${rebuild_cnt} aktive(r) Longhorn-Rebuild(s) laufen noch"
  fi
fi

# -----------------------------------------------------------------------------
# 6) Pods: keiner Pending-und-nicht-schedulebar
# -----------------------------------------------------------------------------
# Geprueft wird die Condition PodScheduled, nicht die Phase allein: ein Pod, der
# bereits auf einem Node liegt und nur noch Images zieht, ist ebenfalls Pending,
# hat aber PodScheduled=True und ist kein Problem. Blockiert wird nur, wenn der
# Scheduler den Pod NICHT platzieren kann - das Symptom eines Restcordons oder
# fehlender Kapazitaet. Damit braucht der Check keine Zeitheuristik.
#
# Leerer Output bedeutet hier "keine Pending-Pods". Dass kubectl erreichbar ist,
# haben die Bloecke 1-5 zu diesem Zeitpunkt bereits belegt.
if [[ "${CHECK_PENDING_PODS}" == "yes" ]]; then
  pend_raw="$(${K} get pods --all-namespaces --field-selector status.phase=Pending -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}|{range .status.conditions[?(@.type=="PodScheduled")]}{.status}{end}{"\n"}{end}' 2>/dev/null)"

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    IFS='|' read -r p_name p_sched <<<"${line}"

    if [[ "${p_sched}" == "False" ]]; then
      wait_out "Pod ${p_name} ist Pending und nicht schedulebar (PodScheduled=False)"
    fi
  done <<<"${pend_raw}"
fi

# -----------------------------------------------------------------------------
# Alle aktivierten Checks bestanden
# -----------------------------------------------------------------------------
echo "HEALTHY"
exit 0
