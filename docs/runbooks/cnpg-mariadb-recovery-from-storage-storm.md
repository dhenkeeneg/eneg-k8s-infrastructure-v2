# Runbook: K8s-Cluster Recovery nach Storage-Storm

**Letzte Aktualisierung:** 2026-05-15 (v3 — Komplettes Recovery von Stateful + Apps)
**Erstmals verifiziert:** DEV-Cluster (k8s-dev), 2026-05-14/15
**Status TEST/PROD:** ausstehend
**Verwandte Docs:**
- `docs/incidents/2026-05-11-mariadb-galera-recovery.md` (Ursprung)
- `docs/runbooks/longhorn-volume-expansion-deadlock.md`

---

## 1. Zweck dieses Runbooks

Komplette Recovery aller Cluster-Komponenten (Stateful Backend + Monitoring +
Backup + Pilot-Apps) nach einem Storage-Storm oder vergleichbaren mehrtaegigen
Ausfall.

Das Runbook deckt drei Phasen ab:
- **Phase A (Stateful):** CNPG-Cluster + MariaDB Galera wiederherstellen
- **Phase B (Plumbing):** Monitoring + Velero reaktivieren (Sichtbarkeit + Sicherheit)
- **Phase C (Apps):** 6 Pilot-Apps in Abhaengigkeitsreihenfolge reaktivieren

Voraussetzung: NAS10 wieder erreichbar + gesund.

Geht davon aus, dass DEV bereits erfolgreich recoverd ist und TEST/PROD
analog behandelt werden sollen.

---

## 2. Goldene Regeln (NON-NEGOTIABLE)

1. **Sequentiell:** Phasen NIE parallel oder vorziehen.
2. **Hibernation immer ZUERST raus** (Phase A.1) — blockiert sonst alles.
3. **selfHeal AUS waehrend Phase A** fuer cnpg-cluster, mariadb-cluster, mariadb-operator.
4. **wait_argocd_sync nach JEDEM Git-Push** (Helper s. Abschnitt 5).
5. **Drift-Check zwischen Phasen** (Cluster-State == Git-State?)
6. **Standbys zuerst** bei Force-Deletes.
7. **Galera-CR replicas=0** muss in Git stehen BEVOR Operator hochgefahren wird.
8. **Daniel commitet/pusht alles selbst.** Claude bereitet Files vor.
9. **HEAD-Check vor jedem Beobachtungs-Loop** — verifizieren dass HEAD wirklich
   den letzten Push enthaelt, NICHT auf "gepushed" Bestaetigung blind vertrauen.
10. **Selbst-Verifikation der Datei** vor Ausgabe des Commit-Befehls (NICHT `git diff` ausgeben).
11. **Einzeilige Commit-Messages** als Default — Heredocs/Unicode/Multi-Liner
    brechen in manchen Shells (verifiziert auf DEV-Recovery 2026-05-15).

---

## 3. Root Causes (verifiziert auf DEV)

### 3.1 NAS10 boto3 InvalidDigest

**Fehler:** `An error occurred (InvalidDigest) when calling the PutObject operation`

**Ursache:** boto3 ≥ 1.36 (Jan 2025) sendet standardmaessig CRC32 Trailing-Checksums.
QNAP QuObjects validiert das inkorrekt.

**Fix:** `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` in
`spec.instanceSidecarConfiguration.env` der ObjectStore-CRs.

### 3.2 Plugin-Sidecar-Cache

env-Vars aus `instanceSidecarConfiguration` werden NUR beim Pod-Recreate in den
Sidecar injiziert. In-place Container-Restarts (kubelet) zaehlen NICHT.

### 3.3 cnpg.io/hibernation blockiert Operator

Hibernation MUSS aus Git entfernt werden — imperativer `kubectl annotate ... hibernation-`
greift nicht weil ArgoCD selfHeal sie aus Git wieder reinpatcht.

### 3.4 Helm-Chart-Default-Replicas unsichtbar fuer ArgoCD

Bei ServerSideApply ist ein nicht-gesetztes Feld kein Drift. Imperative
`kubectl scale --replicas=0` bleibt unsichtbar fuer auto-sync.

**Fix:** `replicas: 1` explizit in Helm-Values setzen.

### 3.5 pg_rewind-Failure nach Primary-Wechsel

Replicas mit divergierender WAL-Historie nach Switchover → `pg_rewind` exit 1.

**Fix:** Pod + Daten-PVC + WAL-PVC loeschen → Operator macht pg_basebackup mit
naechstem freien Index.

### 3.6 ArgoCD "frozen" / "Unknown" Apps

Nach Storage-Storm waren mariadb-operator + mariadb-cluster + loki Apps in stuck
States (revision leer ODER sync=Unknown). Auto-Sync griff nicht mehr.

**Fix:** Application-Controller restarten.

### 3.7 ArgoCD selfHeal-Storms

selfHeal patcht unsere imperativen Aenderungen sofort zurueck (z.B. Hibernation).

**Fix:** selfHeal temporaer auf null setzen waehrend Recovery.

### 3.8 Helm-Chart-Drift bei laenger ausgeschalteten Apps

Auf DEV haben wir entdeckt: viele Helm-Komponenten (Loki, Velero,
Thanos-Compactor) liefen 1/1 obwohl Git replicas:0/enabled:false sagte. ArgoCD
hatte den Drift seit Storm nicht reconciled.

**Bedeutung fuer Recovery:** Vor der Reaktivierung Drift-Inventory machen,
Git mit faktischem Cluster-Stand abgleichen, sonst Recovery-Schritte ueberfluessig
oder gefaehrlich (z.B. Schedule zu frueh aktivieren).

---

## 4. Pre-Flight Checks (BEVOR Recovery startet)

### 4.1 Cluster + Storage

```bash
ENV=test          # oder prod
CTX=k8s-$ENV

kubectl --context $CTX get nodes
# Alle "Ready"

kubectl --context $CTX get volume.longhorn.io -n longhorn-system | grep -cE "error|faulted"
# Soll 0 sein

kubectl --context $CTX get pvc -A | grep -v Bound
# Soll leer sein
```

### 4.2 NAS10 Performance (HART)

```bash
S3_KEY=$(kubectl --context $CTX get secret cnpg-s3-credentials -n databases -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
S3_SECRET=$(kubectl --context $CTX get secret cnpg-s3-credentials -n databases -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)

dd if=/dev/urandom of=/tmp/nas10-precheck.bin bs=1M count=16 2>/dev/null
time s3cmd --host=nas10.eneg.de:8010 --host-bucket="" --no-ssl \
  --access_key=$S3_KEY --secret_key=$S3_SECRET \
  put /tmp/nas10-precheck.bin s3://k8s-$ENV-postgres-wal/test-precheck-$(date +%H%M).bin
rm /tmp/nas10-precheck.bin
```

**KRITERIUM: 16 MB Write Real Time < 5s.** Bei > 30s: NAS10 reboot, dann erneut.

### 4.3 ArgoCD-Health-Check (KRITISCH — Pre-Flight!)

Identifiziert "frozen" Apps bevor sie zum Problem werden.

```bash
# Alle relevanten Apps inspizieren
for app in cnpg-cluster mariadb-cluster mariadb-operator mariadb-operator-crds \
           monitoring thanos loki velero \
           keycloak it-info-versand n8n openproject odoo idoit; do
  echo "=== $app ==="
  kubectl --context $CTX get app $app -n argocd -o jsonpath='
sync={.status.sync.status}
health={.status.health.status}
revision={.status.sync.revision}
opStartedAt={.status.operationState.startedAt}
{"\n"}' 2>&1
done
```

**OK:** `sync=Synced health=Healthy revision=<sha-40-char>` + `opStartedAt` aktuell

**FROZEN (Fix noetig):**
- `revision=` leer
- `opStartedAt` Wochen alt
- `sync=Unknown`

**Fix wenn ≥ 1 App frozen:**

```bash
kubectl --context $CTX rollout restart statefulset argocd-application-controller -n argocd
sleep 30
for app in <frozen-apps>; do
  kubectl --context $CTX annotate app $app -n argocd argocd.argoproj.io/refresh=hard --overwrite
done
sleep 60
# Pre-Flight wiederholen
```

### 4.4 Drift-Inventory

```bash
# Wo ist Cluster-State != Git?
# Helm-Apps: replicas/replicaCount
echo "=== Drift-Check: Helm-Components ==="
for ns_app in "monitoring kube-prometheus-stack-grafana" \
              "monitoring prometheus-kube-prometheus-stack-prometheus" \
              "monitoring thanos-compactor" \
              "monitoring thanos-storegateway" \
              "monitoring loki" \
              "monitoring loki-gateway" \
              "velero velero"; do
  NS=$(echo $ns_app | cut -d' ' -f1)
  APP=$(echo $ns_app | cut -d' ' -f2)
  echo -n "  $NS/$APP: "
  kubectl --context $CTX get deployment,sts $APP -n $NS --no-headers 2>/dev/null | head -1 | awk '{print $2}'
done

# Plain-YAML Apps
echo "=== Drift-Check: Pilot-Apps ==="
for ns in keycloak n8n it-info-versand openproject odoo idoit; do
  echo -n "  $ns: "
  kubectl --context $CTX get deployment -n $ns --no-headers 2>/dev/null | head -3 | awk '{printf "%s=%s ", $1, $2}'
  echo ""
done

# CNPG/MariaDB CRs
echo "=== Drift-Check: Stateful CRs ==="
echo "  cnpg-erp hibernation: $(kubectl --context $CTX get cluster cnpg-erp -n databases -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}')"
echo "  cnpg-shared hibernation: $(kubectl --context $CTX get cluster cnpg-shared -n databases -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}')"
echo "  mariadb-galera replicas: $(kubectl --context $CTX get mariadb mariadb-galera -n databases -o jsonpath='{.spec.replicas}')"
```

⚠️ Bei Drift mit "Apps laufen schon obwohl Git=0/false": Phase B+C koennen sich
zu blossen Drift-Bereinigungen verkleinern. Phase A bleibt unveraendert kritisch.

### 4.5 Bestandsaufnahme + Sicherheit

```bash
# Apps in Git noch auf 0?
cd ~/git/eneg-k8s-infrastructure-v2
grep -rln "replicas: 0\|replicaCount: 0\|enabled: false\|disabled: true" \
  kubernetes/environments/$ENV/ | grep -v "TEMP 2026" | head -20

# Wo hat TEMP-Kommentare?
grep -rln "TEMP 2026-05-14" kubernetes/environments/$ENV/

# Longhorn-Backup-Snapshot existiert? (Sicherheit!)
kubectl --context $CTX get volumesnapshots -A | head -10
```

**Fuer PROD zusaetzlich:**
- Wartungsfenster mit Stakeholdern abgestimmt
- Vorab-Velero-Backup oder Longhorn-Snapshot manuell ausloesen
- Mehrere Stunden ungestoerte Arbeitszeit

---

## 5. Helper: wait_argocd_sync()

Vor Recovery diese Bash-Funktion definieren:

```bash
wait_argocd_sync() {
  local APP=$1 TARGET=$2 TIMEOUT=${3:-180}
  local START=$(date +%s)
  echo "Waiting for '$APP' to sync to '$TARGET'..."
  while [ $(($(date +%s)-START)) -lt $TIMEOUT ]; do
    local CUR=$(kubectl --context $CTX get app $APP -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null)
    if [ "$CUR" = "$TARGET" ]; then
      local SYNC=$(kubectl --context $CTX get app $APP -n argocd -o jsonpath='{.status.sync.status}')
      local HEALTH=$(kubectl --context $CTX get app $APP -n argocd -o jsonpath='{.status.health.status}')
      echo "  Synced after $(($(date +%s)-START))s: sync=$SYNC health=$HEALTH"
      return 0
    fi
    kubectl --context $CTX annotate app $APP -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1
    sleep 10
  done
  echo "  TIMEOUT after ${TIMEOUT}s - manual check required"
  return 1
}
```

---

## 6. PHASE A — Stateful Backend (CNPG + MariaDB)

**Dauer DEV: ~3-4 Stunden inkl. Pre-Flight + Diagnose.**

### A.0 selfHeal AUS

```bash
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'
done
```

### A.1 Hibernation aus Cluster-CRs

Files: `kubernetes/environments/$ENV/cnpg-cluster/cnpg-erp.yaml` + `cnpg-shared.yaml`

`metadata.annotations.cnpg.io/hibernation: "on"` Block entfernen.

Commit + Push, dann `wait_argocd_sync cnpg-cluster <new-rev>`.

### A.2 NAS10 boto3-Fix in ObjectStore-CRs

Files: `kubernetes/environments/$ENV/cnpg-cluster/objectstore-erp.yaml` + `objectstore-shared.yaml`

Nach `retentionPolicy:` ergaenzen:

```yaml
  instanceSidecarConfiguration:
    env:
      - name: AWS_REQUEST_CHECKSUM_CALCULATION
        value: when_required
      - name: AWS_RESPONSE_CHECKSUM_VALIDATION
        value: when_required
```

Commit + Push + wait_argocd_sync.

### A.3 Plugin-Operator-Pod restart

```bash
kubectl --context $CTX delete pod -n cnpg-system -l app.kubernetes.io/name=plugin-barman-cloud
sleep 30
kubectl --context $CTX get pods -n cnpg-system
```

### A.4 Pro CNPG-Cluster: Switchover

Sequenz fuer cnpg-erp UND cnpg-shared:

```bash
CLUSTER=cnpg-erp
OLD_PRIMARY=$(kubectl --context $CTX get cluster $CLUSTER -n databases -o jsonpath='{.status.currentPrimary}')
STANDBY=$(kubectl --context $CTX get pods -n databases -l cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')

# Standby loeschen → neuer Pod mit env-vars
kubectl --context $CTX delete pod $STANDBY -n databases --force --grace-period=0
sleep 60
kubectl --context $CTX get pod $STANDBY -n databases -o json | grep -c AWS_REQUEST_CHECKSUM  # soll 2

# Switchover
kubectl --context $CTX patch cluster $CLUSTER -n databases --type=merge --subresource=status \
  -p "{\"status\":{\"targetPrimary\":\"$STANDBY\"}}"
sleep 60

# WAL-Archive verifizieren
kubectl --context $CTX logs $STANDBY -n databases -c plugin-barman-cloud --since=60s \
  | grep -E "Archived WAL file|InvalidDigest"
```

### A.5 Force-Delete restlicher alter Standbys

```bash
NEW_PRIMARY=$STANDBY
for pod in $(kubectl --context $CTX get pods -n databases -l cnpg.io/cluster=$CLUSTER \
             -o jsonpath='{.items[?(@.metadata.name!="'$NEW_PRIMARY'")].metadata.name}'); do
  kubectl --context $CTX delete pod $pod -n databases --force --grace-period=0
  sleep 75
done

kubectl --context $CTX get cluster $CLUSTER -n databases
```

### A.6 pg_rewind-Failure → komplett-Reset

Falls Pod nach Force-Delete in 1/2 mit `pg_rewind exit 1`:

```bash
POD=cnpg-shared-4
kubectl --context $CTX delete pod $POD -n databases --force --grace-period=0
kubectl --context $CTX delete pvc $POD ${POD}-wal -n databases --wait=false
# Operator erstellt neuen Pod mit naechstem freien Index (z.B. cnpg-shared-5)
sleep 60
```

### A.7 MariaDB-Operator reaktivieren

Pre-Check: Galera-CR in Git auf `replicas: 0`? Falls 3 im Cluster: dort auch auf 0
patchen.

File: `kubernetes/base/mariadb-galera/operator/values.yaml`

```yaml
replicas: 1
```

Commit + Push + wait_argocd_sync.

Falls App "frozen" (kein Sync): imperativer Fallback
`kubectl scale deployment mariadb-operator -n mariadb-operator --replicas=1`.

### A.8 MariaDB-Galera CR reaktivieren

JETZT — Operator stabil.

File: `kubernetes/environments/$ENV/mariadb-cluster/mariadb-galera.yaml`

```yaml
spec:
  replicas: 3
```
`replicasAllowEvenNumber: true` entfernen.

Commit + Push + wait_argocd_sync.

### A.9 selfHeal wieder AN

```bash
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'
done
```

### A.10 Phase A Verifikation

```bash
kubectl --context $CTX get cluster -n databases
# Beide READY=3, STATUS=Cluster in healthy state

for cluster in cnpg-erp cnpg-shared; do
  PRIMARY=$(kubectl --context $CTX get cluster $cluster -n databases -o jsonpath='{.status.currentPrimary}')
  echo -n "$cluster pending WALs: "
  kubectl --context $CTX exec $PRIMARY -n databases -c postgres -- \
    bash -c "ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status/*.ready 2>/dev/null | wc -l"
done
# Beide 0

kubectl --context $CTX get mariadb mariadb-galera -n databases
# READY=True, STATUS=Running
```

---

## 7. PHASE B — Plumbing (Monitoring + Velero)

**Dauer DEV: ~30 Min.**

### B.1 Monitoring — kube-prometheus-stack

File: `kubernetes/environments/$ENV/monitoring/values-override.yaml`

Diese 4 Blocks entfernen/anpassen:
1. `prometheus.prometheusSpec.replicas: 0` → Zeile entfernen
2. `alertmanager.alertmanagerSpec` Block entfernen (oder `replicas: 1`)
3. `grafana:` Block (war nur replicas: 0) komplett entfernen
4. `kube-state-metrics:` Block komplett entfernen

Auch alle "TEMP 2026-MM-DD"-Kommentare entfernen.

Commit + Push.

Erwartete Zeit: ~3 Min bis alle 4 hochgefahren (Prometheus WAL-Replay).

### B.2 Monitoring — Thanos

File: `kubernetes/environments/$ENV/monitoring-thanos/values-override.yaml`

- `compactor.replicaCount: 0` entfernen (PVC-Size 30Gi bleibt!)
- `query:` Block entfernen
- `storegateway:` Block entfernen

Commit + Push. ~1 Min bis alle hochgefahren.

### B.3 Loki Drift-Cleanup

File: `kubernetes/environments/$ENV/monitoring-loki/values-override.yaml`

- `singleBinary.replicas: 0` entfernen
- `gateway: enabled: false` Block entfernen
- `chunksCache: enabled: false` Block entfernen
- `resultsCache: enabled: false` Block entfernen
- `lokiCanary: enabled: false` Block entfernen

(Komponenten laufen meist schon — Drift wird bereinigt)

Commit + Push.

### B.4 Velero reaktivieren

File: `kubernetes/environments/$ENV/velero/values-override.yaml`

- `replicaCount: 0` entfernen (Velero Server laeuft meist schon — Drift)
- `nodeAgent.enable: false` entfernen (laeuft meist schon — Drift)
- In `schedules.daily-backup:`: `disabled: true` entfernen

Alle TEMP-Kommentare entfernen.

Commit + Push.

⚠️ **Bei PROD:** Schedule wird sofort aktiv. Prüfen wann der naechste Run laeuft
(cron) — ist das mitten in der Recovery? Ggf. cron-Time anpassen vor Push.

### B.5 Phase B Verifikation

```bash
kubectl --context $CTX get deployment,sts -n monitoring | grep -v "0/0"
# Alle Komponenten >= 1/1

kubectl --context $CTX get schedules -n velero
# velero-daily-backup STATUS=Enabled, PAUSED leer
```

---

## 8. PHASE C — Pilot-Apps (6 Apps in Reihenfolge)

**Dauer DEV: ~30-45 Min sequentiell.**

### C.0 Reihenfolge & Begruendung

| # | App | Begruendung | Hochfahr-Zeit (DEV) |
|---|---|---|---|
| 1 | **keycloak** | OIDC-Provider — andere brauchen es | ~70s |
| 2 | **it-info-versand** | OIDC-Konsument, klein, Alembic-Migration | ~35s |
| 3 | **n8n** | Standalone, klein | ~27s |
| 4 | **openproject** | 4 Deployments + Seeder, LDAP | ~5 Min |
| 5 | **odoo** | Standalone, nutzt cnpg-erp | ~88s |
| 6 | **idoit** | Letzte; braucht MariaDB Galera | ~88s |

### C.1 Pro App: Pattern

```bash
# 1. Aktuelle Datei pruefen
grep -n "replicas:" kubernetes/environments/$ENV/apps/<APP>/deployment.yaml

# 2. replicas 0 → 1 via edit_block (mit TEMP-Kommentaren entfernen)

# 3. Selbst-Verifikation (kein git diff)
grep -n "replicas:" kubernetes/environments/$ENV/apps/<APP>/deployment.yaml

# 4. EINZEILIGER Commit (keine Heredocs!)
cd ~/git/eneg-k8s-infrastructure-v2
git add kubernetes/environments/$ENV/apps/<APP>/deployment.yaml
git commit -m "feat($ENV/<APP>): Reaktivierung replicas 0 -> 1"
git push

# 5. HEAD-Check (Daniel sagt 'gepushed' — vertrauen aber verifizieren)
git log --oneline -1

# 6. ArgoCD Sync abwarten + Pods beobachten
sleep 60
kubectl --context $CTX get pods -n <APP>
```

### C.2 Spezialfaelle

**openproject** hat 4 Deployments — alle 4 mit unique `metadata.name`
als Anker patchen (gleichzeitiger Commit):

- openproject-memcached (Cache)
- openproject-hocuspocus (Collaborative Editing)
- openproject-web (Rails Frontend, `strategy: Recreate`)
- openproject-worker (Background-Jobs)

PostSync-Job `openproject-seeder` laeuft automatisch.

**Voraussetzungen Pro App:**

| App | Postgres | MariaDB | Keycloak | S3 (Garage) | Longhorn-PVC |
|---|---|---|---|---|---|
| keycloak | cnpg-shared | – | – | – | – |
| it-info-versand | cnpg-shared | – | ja | – | – |
| n8n | cnpg-shared | – | – | – | n8n-data (5Gi) |
| openproject | cnpg-shared | – | ja (OIDC) | ja (Attachments) | openproject-tmp |
| odoo | cnpg-erp | – | – | – | odoo-filestore (10Gi) |
| idoit | – | ja | – | – | idoit-data |

### C.3 Phase C Verifikation

```bash
kubectl --context $CTX get pods -A | grep -E "keycloak|it-info-versand|n8n|openproject|odoo|idoit"
# Alle 1/1 (oder 2/2 falls Sidecars), 0 Restarts, AGE < 1h
```

---

## 9. Rollback

```bash
# 1. selfHeal aus
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

# 2. Git revert + push
cd ~/git/eneg-k8s-infrastructure-v2
git revert <commit-sha>...HEAD
git push

# 3. Manuelle Syncs
TARGET_REV=$(git rev-parse HEAD)
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"operation":{"sync":{"revision":"'$TARGET_REV'"}}}'
  wait_argocd_sync $app $TARGET_REV
done

# 4. Hibernation re-enable falls noetig
kubectl --context $CTX annotate cluster cnpg-erp -n databases cnpg.io/hibernation=on --overwrite
kubectl --context $CTX annotate cluster cnpg-shared -n databases cnpg.io/hibernation=on --overwrite
```

---

## 10. Persistente Learnings

1. **NAS10/QuObjects boto3 ≥ 1.36 InvalidDigest.** Workaround
   `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`.

2. **CNPG plugin-barman-cloud Architektur** — env-vars propagieren nur bei
   Pod-Recreate.

3. **CNPG Switchover ohne kubectl-cnpg-plugin** via subresource-Patch.

4. **CNPG pg_rewind Fallback** — komplett-Reset, pg_basebackup mit neuem Index.

5. **ArgoCD selfHeal patcht Hibernation aus Git zurueck** — daher Git-Patch.

6. **Helm-Chart-Defaults unsichtbar fuer ArgoCD ServerSideApply** — explizit setzen.

7. **ArgoCD "frozen"/Unknown Apps** — Application-Controller-Restart.

8. **selfHeal AUS waehrend Recovery** — verhindert ungewollte Rollbacks.

9. **Reihenfolge:** Hibernation → env-vars → Plugin-Restart → Standby-Restart →
   Switchover → restliche Standbys.

10. **Galera-Operator-Reihenfolge:** CR replicas=0 BEVOR Operator hoch.

11. **Helm-Charts haben oft Drift** seit Storm — Drift-Inventory in Pre-Flight machen.

12. **`git diff --stat` ist unnoetig** — vor Commit selbst die Datei pruefen
    (grep -n "replicas:" file).

13. **Einzeilige Commit-Messages** — Heredocs/Unicode brechen in manchen Shells.

14. **HEAD-Check vor Beobachtungs-Loop** — "gepushed" Bestaetigung blind vertrauen
    kann irrefuehren (Datei evtl. nicht committet, nur in Working-Dir).

15. **App-Reihenfolge** = Abhaengigkeitsreihenfolge:
    OIDC-Provider → OIDC-Konsumenten, DB-abhaengige nach DB-Recovery.

---

## 11. ENV-spezifische Vorbereitung

### TEST

- [ ] Pre-Flight Phase 4 komplett
- [ ] NAS10 16 MB Write < 5s
- [ ] ArgoCD Apps NICHT frozen
- [ ] Drift-Inventory durchgegangen (Vergleich DEV-Drift-Muster)
- [ ] Mehrere Stunden ungestoerte Arbeitszeit
- [ ] Stakeholder informiert (TEST-Down ist niedrig-impactful)

### PROD

- [ ] Wartungsfenster mit Stakeholdern abgestimmt
- [ ] Vorab-Velero-Backup oder Longhorn-Snapshot manuell ausgeloest
- [ ] Wartungsfenster-Banner in betroffenen Apps (idoit, openproject, odoo)
- [ ] Notfall-Kontakte erreichbar (Daniel + ggf. Vertretung)
- [ ] Pre-Flight Phase 4 STRIKT (kein "wir schauen mal")
- [ ] DEV + TEST muessen vorher erfolgreich recovered + verifiziert sein
- [ ] Mind. 4-6 Stunden ungestoerte Arbeitszeit

---

## 12. Aenderungshistorie

| Datum       | Aenderung                                                | Quelle |
|-------------|----------------------------------------------------------|--------|
| 2026-05-15  | v1: Initial nach DEV-Recovery erstellt                   | DEV verifiziert |
| 2026-05-15  | v2: Retro-Optimierungen (selfHeal-Storm, ArgoCD-frozen)  | DEV-Retro |
| 2026-05-15  | v3: App-Reaktivierungs-Phasen B+C ergaenzt, Drift-Inventory, | DEV komplett |
|             | Workflow-Lerning (HEAD-check, einzeilige Commits)        |        |
