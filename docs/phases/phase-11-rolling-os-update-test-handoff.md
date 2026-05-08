# Phase 11 - Rolling OS-Update TEST Cluster — Handoff-Plan

**Status:** ⏳ In Vorbereitung
**Datum:** 08.05.2026 (Plan erstellt)
**Cluster:** k8s-test (TEST, VLAN 179)
**Owner:** Daniel Henke
**Vorgaengerblock:** Phase 12b CoreDNS HA PROD (07.05.) + imagePullPolicy-Cleanup (08.05.)
**Bezugsdokument:** `docs/phases/phase-11-rolling-os-update-dev.md`

---

## 1. Ziel und Scope

Sequenzielles OS-Update aller 3 TEST-Nodes (k8s-test-21/22/23) inkl.
Reboot. Kernel + Userspace-Pakete werden aktualisiert. Pro Node:

1. vSphere-Snapshot anlegen (govc)
2. CNPG Primary-Switchover falls Primary auf Ziel-Node
3. Pre-Drain Maintenance-Modes aktivieren (CNPG, Longhorn, Galera)
4. Cordon + Drain (Timeout 900s)
5. APT Update + Upgrade
6. Reboot
7. Uncordon + Verifikation
8. Post-Drain Cleanup (Maintenance-Modes zuruecksetzen)
9. **Snapshot BEHALTEN** (manuelle Loeschung danach)
10. Cooldown 60s, dann naechster Node

**Reihenfolge** (Playbook-Default `order: reverse_sorted`): k8s-test-23 → -22 → -21.

---

## 2. Status der Vorbedingungen

### 2.1 Verbesserungen seit DEV-Vorfall 30.04.

| Mitigation | Status | Bemerkung |
|---|---|---|
| CoreDNS HA in TEST | ✅ Aktiv seit 06.05.2026 | 3 Pods auf 3 Nodes, PDB minAvailable=2, RESTARTS=0 |
| imagePullPolicy auf IfNotPresent | ✅ Erledigt 08.05.2026 | App-Deployments + ArgoCD-Workloads alle 3 Cluster |
| Lehrbuchkonforme Drain-Tasks im Playbook | ✅ Im Repo | `pre_drain_prep.yml` + `post_drain_cleanup.yml` |
| Drain-Timeout 900s | ✅ Default-Wert | `drain_timeout_seconds: 900` |
| Bug-Fixes Playbook (Jinja, kubectl-Plugin) | ✅ Im Repo | Aus DEV-Lessons |

### 2.2 Restrisiko: Zot-HA NICHT in TEST

| Aspekt | Status | Bewertung |
|---|---|---|
| TEST hat eigenen Zot | ❌ Nein | Phase 9a Etappe B steht noch aus (Block 4 der Roadmap) |
| TEST nutzt DEV-Zot | ✅ Ja | Cross-VLAN (179 → 180), Mirror-Konfiguration in containerd |
| Internet-Fallback | ✅ Ja | containerd registries.yaml hat Default-Endpoints (docker.io, quay.io, ghcr.io, registry.k8s.io) |
| DEV-Zot ist HA | ✅ Ja | Phase 12 Plan A am 06.05.: 3 Replicas + Anti-Affinity |

**Bewertung:** Restrisiko niedrig bis mittel. DEV-Zot ist HA, Internet-Fallback steht. Kritischer Fall (DEV-Zot OnDemand-Sync-Latenz beim Erstpull eines Multi-Arch-Images) wird durch **Pre-Warming-Phase** (siehe 3.1) abgemildert.

### 2.3 Cluster-Topologie und PDB-Status

**Pod-Verteilung pro Node (Stand 08.05.2026 vor Update):**

| Komponente | k8s-test-21 | k8s-test-22 | k8s-test-23 | Anti-Affinity |
|---|---|---|---|---|
| cnpg-erp | -2 | -1 | -3 | ✅ verteilt |
| cnpg-shared | -1 | -3 | -2 | ✅ verteilt |
| mariadb-galera | -1 | -2 | -0 | ✅ verteilt (1 pro Node!) |
| coredns | 1 | 1 | 1 | ✅ |

**PDBs (relevante):**
- `cnpg-erp` minAvailable=1 — erlaubt 1 Disruption
- `cnpg-shared` minAvailable=1 — erlaubt 1 Disruption
- `mariadb-galera` minAvailable=50% — erlaubt 1 Disruption (1 von 3 down erlaubt)
- `coredns` minAvailable=2 — erlaubt 1 Disruption
- `cnpg-erp-primary` / `cnpg-shared-primary` minAvailable=1 (CNPG-eigene Logik fuer Primary)

→ **TEST-Verteilung ist deutlich besser als DEV beim Update.** Galera-PDB-Patch wird voraussichtlich nicht ausloesen muessen, weil keine Node 2+ Galera-Pods hat. Playbook macht den Patch trotzdem als Safety-Net automatisch.

---

## 3. Plan in 5 Phasen

### Phase A — Image-Pre-Warming (NEU, aus DEV-Drift-Vorfall 08.05.)

**Ziel:** Sicherstellen, dass kritische Images auf allen 3 TEST-Nodes lokal cached sind, bevor der Drain beginnt. So vermeiden wir die Race Condition aus DEV (Pod re-scheduled auf Node ohne Image im Cache → ImagePullBackOff durch DEV-Zot OnDemand-Sync-Latenz).

#### A1 — Image-Inventur erstellen

Alle aktiv genutzten Images im TEST-Cluster sammeln (auf k8s-mgmt-10):

```bash
cd ~/git/eneg-k8s-infrastructure-v2

kubectl --context k8s-test get pods -A \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
  | grep -v '^$' | sort -u > /tmp/test-images-active.txt

wc -l /tmp/test-images-active.txt
# Erwartet: 50-70 unique Images
```

#### A2 — Image-Cache pro Node erfassen

```bash
ansible k3s_servers -i ansible/inventory/test/hosts.ini \
  -m shell -a "sudo k3s ctr images list -q | sort -u" \
  > /tmp/test-images-cached-raw.txt 2>&1
```

Manuelle Sichtung: welche Images aus A1 fehlen auf welcher Node?

#### A3 — Privatabdeckung: Custom-Images aus eigenem GHCR-Repo

Aus DEV-Lesson: `dhenkeeneg/*`-Images muessen mit `--user` gepullt werden, weil GHCR private Repos hat und `k3s ctr` die containerd-Mirror-Config umgeht.

Token aus k8s-Secret extrahieren:

```bash
DOCKER_CFG=$(kubectl --context k8s-test get secret -n it-info-versand ghcr-pull-secret \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
GHCR_USER=$(echo "$DOCKER_CFG" | jq -r '.auths["ghcr.io"].username')
GHCR_PASS=$(echo "$DOCKER_CFG" | jq -r '.auths["ghcr.io"].password')

echo "Token gelesen: User=$GHCR_USER, PassLen=${#GHCR_PASS}"
```

Pre-Warm der Custom-Images auf alle 3 Nodes (sequenziell):

```bash
for IMG in \
    ghcr.io/dhenkeeneg/eneg-it-info-versand:de4d0c0 \
    ghcr.io/dhenkeeneg/idoit-open:37 \
    ghcr.io/dhenkeeneg/prometheus-msteams:v1.5.4 ; do
  echo ""
  echo "=== Pulling $IMG ==="
  ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
    -m shell -a "sudo k3s ctr images pull --user ${GHCR_USER}:${GHCR_PASS} ${IMG}" \
    --forks 1
done

unset DOCKER_CFG GHCR_USER GHCR_PASS
```

#### A4 — Public-Images: kritische Komponenten

Die wichtigsten Images, die bei Drain neu auf einer Node landen koennten — sicherstellen dass alle 3 Nodes sie haben. `k3s ctr` ohne `--user` reicht hier (oeffentlich) und nutzt automatisch die Mirror-Konfiguration falls registry-dev.eneg.de das Image hat:

```bash
# CoreDNS (kritischste Komponente)
ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
  -m shell -a "sudo k3s ctr images pull docker.io/rancher/mirrored-coredns-coredns:1.14.1" \
  --forks 1

# ArgoCD (pruefen, ist meist schon ueberall)
ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
  -m shell -a "sudo k3s ctr images pull quay.io/argoproj/argocd:v3.3.0" \
  --forks 1

# Longhorn-CSI-Plugins (haben kaskadierende Folgen wenn down)
for IMG in \
    docker.io/longhornio/longhorn-manager:v1.9.2 \
    docker.io/longhornio/longhorn-engine:v1.9.2 \
    docker.io/longhornio/longhorn-instance-manager:v1.9.2 \
    docker.io/longhornio/csi-attacher:v4.9.0-20250709 \
    docker.io/longhornio/csi-provisioner:v5.3.0-20250709 \
    docker.io/longhornio/csi-resizer:v1.14.0-20250709 \
    docker.io/longhornio/csi-snapshotter:v8.3.0-20250709 ; do
  ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
    -m shell -a "sudo k3s ctr images pull ${IMG}" \
    --forks 1
done

# CNPG (Operator + Plugin)
for IMG in \
    ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1 \
    ghcr.io/cloudnative-pg/postgresql:17.9-standard-bookworm \
    ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.11.0 \
    ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.11.0 ; do
  ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
    -m shell -a "sudo k3s ctr images pull ${IMG}" \
    --forks 1
done

# MariaDB
ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
  -m shell -a "sudo k3s ctr images pull docker.io/library/mariadb:11.8.6" \
  --forks 1

# MariaDB-Operator (private Registry, geht direkt)
ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
  -m shell -a "sudo k3s ctr images pull docker-registry3.mariadb.com/mariadb-operator/mariadb-operator:25.10.4" \
  --forks 1

# Monitoring-Kernkomponenten
for IMG in \
    quay.io/prometheus/prometheus:v3.11.0 \
    quay.io/thanos/thanos:v0.41.0 \
    quay.io/prometheus/alertmanager:v0.31.1 \
    quay.io/prometheus/blackbox-exporter:v0.28.0 \
    quay.io/prometheus/node-exporter:v1.11.0 \
    docker.io/grafana/grafana:12.4.2 \
    docker.io/grafana/loki:3.6.7 \
    docker.io/grafana/alloy:v1.15.0 ; do
  ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
    -m shell -a "sudo k3s ctr images pull ${IMG}" \
    --forks 1
done

# Velero
for IMG in \
    docker.io/velero/velero:v1.17.1 \
    docker.io/velero/velero-plugin-for-aws:v1.13.0 ; do
  ansible k3s_servers -i ansible/inventory/test/hosts.ini -b \
    -m shell -a "sudo k3s ctr images pull ${IMG}" \
    --forks 1
done
```

#### A5 — Verifikation Cache nach Pre-Warming

```bash
ansible k3s_servers -i ansible/inventory/test/hosts.ini \
  -m shell -a "sudo k3s ctr images list -q | wc -l"
```

Erwartung: Auf allen 3 Nodes mind. ~70 Images im Cache, in der gleichen Groessenordnung.

---

### Phase B — Snapshot-Konfiguration

Standard-Default ist `snapshot_delete_on_success: true`. Daniel moechte fuer TEST die Snapshots behalten und manuell loeschen → Override per Variable noetig.

**Empfehlung:** `-e snapshot_delete_on_success=false` beim Playbook-Aufruf.

---

### Phase C — Playbook-Aufruf

**Pre-Flight Smoke-Test (optional, empfohlen):**

```bash
cd ~/git/eneg-k8s-infrastructure-v2

ansible-playbook -i ansible/inventory/test/hosts.ini \
  ansible/playbooks/08-rolling-os-update.yml \
  -e target_env=test \
  --tags pre-checks
```

Erwartung: alle Pre-Checks gruen (Cluster ready, Velero recent, govc reachable, etc).

**Vollstaendiger Run:**

```bash
ansible-playbook -i ansible/inventory/test/hosts.ini \
  ansible/playbooks/08-rolling-os-update.yml \
  -e target_env=test \
  -e snapshot_delete_on_success=false
```

**Reihenfolge:** k8s-test-23 → k8s-test-22 → k8s-test-21 (`order: reverse_sorted`)

**Ablauf pro Node** (der Playbook macht das automatisch sequenziell):

| # | Schritt | Approx. Dauer |
|---|---|---|
| 1 | vSphere-Snapshot via govc | 30-60s |
| 2 | CNPG Primary-Switchover (falls noetig) | 30-90s |
| 3 | Pre-Drain Maintenance-Mode (CNPG/Longhorn/Galera) | 10-30s |
| 4 | Cordon + Drain (Timeout 900s) | 1-5 min |
| 5 | APT Update + Upgrade | 1-3 min |
| 6 | Reboot + Wait-for-SSH | 1-3 min |
| 7 | Uncordon + Verifikation | 30-60s |
| 8 | Post-Drain Cleanup (Maintenance-Modes off) | 10-30s |
| 9 | Snapshot loeschen (**uebersprungen wegen Override!**) | n/a |
| 10 | Cooldown 60s | 60s |

**Geschaetzte Gesamtdauer:** 30-50 min fuer alle 3 Nodes inkl. Cooldown.

---

### Phase D — Verifikation

Bei jedem `verify` Schritt im Playbook (Schritt 7 pro Node) wird automatisch geprueft:
- Node Ready
- Alle Pods auf der Node Running (mit Toleranzen)
- CNPG-Cluster healthy
- Drain-Counter normalisiert

**Manuell danach (auf k8s-mgmt-10 oder via MCP):**

```bash
# 1. Alle Nodes Ready?
kubectl --context k8s-test get nodes -o wide

# 2. Kernel-Version aktualisiert?
ansible k3s_servers -i ansible/inventory/test/hosts.ini \
  -m shell -a "uname -r"

# 3. Alle ArgoCD-Apps Synced/Healthy?
kubectl --context k8s-test get applications.argoproj.io -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# 4. Keine ungesunden Pods?
kubectl --context k8s-test get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide

# 5. CNPG-Cluster healthy?
kubectl --context k8s-test get cluster.postgresql.cnpg.io -A
kubectl --context k8s-test get backups.postgresql.cnpg.io -A | head -20

# 6. MariaDB Galera healthy?
kubectl --context k8s-test get mariadb -A
kubectl --context k8s-test get pods -n databases -l app.kubernetes.io/instance=mariadb-galera

# 7. CoreDNS HA: 3/3 auf 3 Nodes, RESTARTS niedrig?
kubectl --context k8s-test get pods -n kube-system -o wide \
  | grep coredns

# 8. Maintenance-Modes alle zurueckgesetzt?
kubectl --context k8s-test get cluster.postgresql.cnpg.io -A \
  -o jsonpath='{range .items[*]}{.metadata.name}: maintenanceWindow.inProgress={.spec.nodeMaintenanceWindow.inProgress}{"\n"}{end}'

kubectl --context k8s-test get settings.longhorn.io node-drain-policy -n longhorn-system

kubectl --context k8s-test get pdb mariadb-galera -n databases \
  -o jsonpath='{.spec.minAvailable}'

# 9. Aktive Alerts? (nur Watchdog erwartet)
kubectl --context k8s-test get -n monitoring alerts.monitoring.coreos.com 2>/dev/null \
  || echo "(keine direkte Alert-API, im Alertmanager UI checken)"
```

---

### Phase E — Cleanup (manuelles Snapshot-Loeschen)

Nach erfolgreicher Verifikation und ggf. kurzer Beobachtung:

```bash
# Snapshot-Liste pro VM auflisten
for vm in k8s-test-21 k8s-test-22 k8s-test-23; do
  echo "=== ${vm} ==="
  govc snapshot.tree -vm "${vm}" 2>/dev/null || echo "(kein govc-Output)"
done
```

Zum Loeschen pro VM:

```bash
govc snapshot.remove -vm k8s-test-21 ansible-osupdate-test-k8s-test-21-<timestamp>
govc snapshot.remove -vm k8s-test-22 ansible-osupdate-test-k8s-test-22-<timestamp>
govc snapshot.remove -vm k8s-test-23 ansible-osupdate-test-k8s-test-23-<timestamp>
```

(Genaue Timestamp-Namen aus Playbook-Output entnehmen.)

---

## 4. Risiken und Mitigation

| Risiko | Wahrscheinlichkeit | Impact | Mitigation |
|---|---|---|---|
| Image-Pull haengt waehrend Drain (DEV 30.04. wiederholt) | 🟡 mittel | Hoch | **Phase A Pre-Warming** + CoreDNS HA + imagePullPolicy IfNotPresent + DEV-Zot ist HA |
| Galera-PDB blockiert Drain | 🟢 niedrig | Mittel | Gute Verteilung (1 Pod/Node), Playbook patcht trotzdem als Safety-Net |
| Kernel-Update bricht Boot | 🟢 sehr niedrig | Sehr hoch | vSphere-Snapshot vor Update, manuelle Behaltung, Rollback per Snapshot |
| CNPG-Plugin nach Reboot down | 🟢 niedrig | Mittel | Recovery-Pattern aus DEV: `kubectl rollout restart` |
| Longhorn Volume-Detach-Hang | 🟢 niedrig | Mittel | Drain-Timeout 900s + drain-policy override |
| Cross-VLAN DEV-Zot-Verfuegbarkeit | 🟢 niedrig | Mittel | DEV-Zot ist HA + Internet-Fallback aktiv |

---

## 5. Was wir aus DEV uebernehmen

✅ Lehrbuchkonforme Drain-Strategie (CNPG / Longhorn / Galera Maintenance-Modes)
✅ Drain-Timeout 900s
✅ Sequentielle Reihenfolge (`serial: 1`, `order: reverse_sorted`)
✅ vSphere-Snapshots vor Drain
✅ CNPG Primary-Switchover automatisch
✅ Cooldown 60s zwischen Nodes
✅ Pre-Checks-Phase im Playbook
✅ Recovery-Tools dokumentiert (siehe DEV-Doku Abschnitt 5)
✅ Image-Pre-Warming als zwingender Vor-Schritt (NEU aus 08.05. Drift)

## 6. Was anders ist gegenueber DEV

- **CoreDNS HA aktiv** → keine SPOF mehr fuer DNS-Resolution
- **imagePullPolicy IfNotPresent** → kein Always-Pull bei Pod-Restart
- **Galera-Verteilung sauber** → Galera-PDB-Patch hoechstwahrscheinlich gar nicht noetig
- **Kernel-Update wahrscheinlich** → DEV blieb auf 6.8.0-71, TEST hat schon -110, evtl. neuere im Repo verfuegbar
- **Mehr Apps deployed** → Pilot-Apps alle aktiv (n8n, Keycloak, OpenProject, Odoo, idoit, it-info-versand)
- **Snapshot-Behaltung** → `snapshot_delete_on_success=false`, manuelle Loeschung danach

---

## 7. Vorgehensweise (Schritt-fuer-Schritt fuer Daniel)

> **Hinweis:** Diese Liste fuehrt nur die Top-Level-Schritte auf. Details siehe Abschnitte 3.A bis 3.E.

| # | Schritt | Wer macht's | Geschaetzte Dauer |
|---|---|---|---|
| 1 | Phase A1+A2: Image-Inventur + Cache-Status | Daniel auf k8s-mgmt-10 | 5 min |
| 2 | Phase A3+A4: Pre-Warming auf alle 3 Nodes | Daniel auf k8s-mgmt-10 | 10-15 min |
| 3 | Phase A5: Verifikation Cache | Daniel + Claude per MCP | 2 min |
| 4 | Phase C Pre-Flight Smoke-Test | Daniel | 2 min |
| 5 | Phase C voller Run (sequentiell -23 → -22 → -21) | Daniel | 30-50 min |
| 6 | Phase D Verifikation | Claude per MCP + Daniel | 5-10 min |
| 7 | Phase E Snapshots loeschen | Daniel | 5 min |
| 8 | Doku-Abschluss `phase-11-rolling-os-update-test.md` | Claude + Daniel | 10 min |

**Gesamtdauer geschaetzt:** ~1,5-2 Stunden inkl. Doku.

---

## 8. Was passiert bei Problemen

**Bei Drain-Timeout / haengender Maintenance-Operation:**
- Playbook bricht ab (`any_errors_fatal: true`)
- Snapshot ist da → Rollback moeglich (govc snapshot revert)
- Recovery-Tools aus DEV-Doku Abschnitt 5

**Bei Volume-Expansion-Deadlock:** Runbook `docs/runbooks/longhorn-volume-expansion-deadlock.md`

**Bei DEV-Zot-Ausfall waehrend Drain:**
- containerd faellt automatisch auf Internet-Fallback
- Bei privaten Images (`dhenkeeneg/*`): Pre-Warming hat das Risiko schon weggenommen

**Bei kaskadierendem Cluster-Ausfall (wie DEV 30.04.):**
- CoreDNS-HA verhindert das Hauptproblem von damals
- Recovery-Pattern: alter Pod loeschen, neuer rolled aus, ggf. CNPG-Operator neu starten

---

## 9. Naechste Schritte nach Abschluss

1. Burn-in: kurze Beobachtung (~1-2h Alerts/Logs), 24h NICHT zwingend laut Daniel
2. Snapshots loeschen (Phase E)
3. Doku `phase-11-rolling-os-update-test.md` erstellen (analog zu DEV-Doku)
4. Roadmap aktualisieren: Block 2 ✅, Block 3 (PROD-OS-Update) wird als naechstes anstehen

---

## 10. Bezugsdokumente

- `docs/phases/phase-11-rolling-os-update-dev.md` — DEV-Erfahrung + Lessons (Hauptreferenz!)
- `docs/phases/phase-12-ha-improvements-completed.md` — CoreDNS HA + Zot HA Hintergrund
- `docs/phases/phase-12b-prod-completed.md` — Letzter abgeschlossener Block
- `docs/phases/imagepullpolicy-cleanup-2026-05-08.md` — Mini-Block 08.05. (Pre-Warming-Pattern)
- `docs/phases/phase-09a-security-registries.md` — Zot-Setup, TEST/Internet-Fallback
- `docs/runbooks/longhorn-volume-expansion-deadlock.md` — Volume-Workaround
- `docs/phases/roadmap-handoff-2026-05-06.md` — Master-Roadmap

---

*Plan erstellt 08.05.2026, bereit zur Ausfuehrung nach Daniels Freigabe.*
