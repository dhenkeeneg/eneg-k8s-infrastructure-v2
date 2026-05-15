# Runbook: CNPG + MariaDB Recovery nach Storage-Storm

**Letzte Aktualisierung:** 2026-05-15 (v2 nach Retro)
**Erstmals verifiziert:** DEV-Cluster (k8s-dev), 2026-05-14/15
**Status TEST/PROD:** ausstehend
**Verwandte Docs:**
- `docs/incidents/2026-05-11-mariadb-galera-recovery.md` (Ursprung)
- `docs/runbooks/longhorn-volume-expansion-deadlock.md`

---

## 1. Zweck dieses Runbooks

Wiederherstellung der Stateful-Komponenten (CNPG-Cluster + MariaDB Galera)
nach einem Storage-Storm oder vergleichbaren mehrtaegigen Ausfall.

Adressierte Probleme:
- NAS10/QuObjects-Inkompatibilitaet mit boto3 ≥ 1.36 (InvalidDigest)
- CNPG stuck "Waiting for instances to become active"
- MariaDB-Operator replicas=0 ohne ArgoCD-Recovery
- Pod-Sidecar-Cache von alten Pods ohne neue ObjectStore-env-vars
- Divergierende WAL-Historie nach Primary-Wechseln
- **ArgoCD "frozen" Apps** (revision leer, kein selbsttaetiger Sync)
- **ArgoCD selfHeal-Storms** waehrend Recovery

Das Runbook geht davon aus, dass DEV bereits erfolgreich recoverd ist
und TEST/PROD analog behandelt werden sollen.

---

## 2. Goldene Regeln dieses Runbooks

1. **Sequentiell:** Phasen NIE parallel oder vorziehen. Erst Verifikation, dann naechster Schritt.
2. **Reihenfolge:** Hibernation IMMER raus VOR env-vars und Switchover.
3. **ArgoCD-Sync-Wait:** Nach JEDEM Git-Push warten bis App-Status `revision=<neuer-commit>` zeigt. Niemals davon ausgehen dass Auto-Sync gleich passiert.
4. **selfHeal AUS waehrend Recovery:** Verhindert ungewollte Rollbacks unserer manuellen Aktionen.
5. **Drift-Check zwischen Phasen:** Vor jeder neuen Aktion verifizieren dass Cluster-State dem letzten Git-Push entspricht.
6. **Standbys zuerst:** Bei Force-Deletes immer Standby vor Primary (kein Service-Impact).
7. **Galera-Operator-Reihenfolge:** Galera-CR MUSS `replicas=0` haben wenn Operator hochgefahren wird (sonst startet Recovery direkt).
8. **Daniel committet/pusht selbst.** Claude bereitet Files vor.

---

## 3. Root Causes (verifiziert auf DEV)

### 3.1 NAS10 boto3 InvalidDigest

**Fehler:**
```
ERROR: Barman cloud WAL archiver exception:
An error occurred (InvalidDigest) when calling the PutObject operation:
The Content-MD5 or checksum value that you specified is not valid.
```

**Ursache:** boto3 ≥ 1.36 (Jan 2025) sendet standardmaessig CRC32
Trailing-Checksums bei jedem PutObject. QNAP QuObjects validiert das
inkorrekt und antwortet mit InvalidDigest.

**Fix:** `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` in
`spec.instanceSidecarConfiguration.env` der ObjectStore-CRs.
Quelle: https://aws.amazon.com/blogs/developer/new-default-checksum-behavior-in-aws-sdks/

### 3.2 Plugin-Sidecar-Cache

env-Variablen aus `instanceSidecarConfiguration` werden NUR beim
Pod-Recreate in den Sidecar injiziert. In-place Container-Restarts
(kubelet) zaehlen NICHT.

Konsequenz: Nach env-var-Patch muessen Postgres-Pods explizit
force-deleted werden. Reihenfolge: Standby zuerst (env-vars
verifizieren), dann Switchover, dann alter Primary.

### 3.3 cnpg.io/hibernation blockiert Operator

Wenn `cnpg.io/hibernation: on` annotiert ist, ignoriert der Operator
Switchover-Patches und Reconciliation. Hibernation MUSS aus Git
entfernt werden — imperativer `kubectl annotate ... hibernation-`
greift nicht weil ArgoCD selfHeal sie aus Git wieder reinpatcht.

### 3.4 MariaDB-Operator-Default unsichtbar fuer ArgoCD

Helm-Values fuer mariadb-operator hatten KEINEN `replicas`-Eintrag
(Default 1). Imperative `kubectl scale --replicas=0` war fuer ArgoCD
unter ServerSideApply kein Drift -> Operator blieb dauerhaft auf 0/0.
Fix: `replicas: 1` explizit in `base/mariadb-galera/operator/values.yaml`.

### 3.5 pg_rewind-Failure nach Primary-Wechsel

Replicas die frueher selbst Primary waren haben divergierende
WAL-Historie nach Switchover. `pg_rewind` exit 1.

Fix: Pod + Daten-PVC + WAL-PVC loeschen. Operator macht `pg_basebackup`
fuer neue Replica mit naechstem freien Index (z.B. `cnpg-shared-4`
-> `cnpg-shared-5`).

### 3.6 ArgoCD "frozen" Apps (NEU)

Nach Storage-Storm waren mariadb-operator und mariadb-cluster Apps
in einem State wo `status.sync.revision` leer war, `lastTransitionTime`
vom Storm-Tag, `operationState.startedAt` Wochen alt. Sync-Status zeigte
"Synced/Healthy" obwohl der Controller die App nicht mehr aktiv
reconcilete.

Symptome:
- `revision=` leer trotz neuem HEAD-Commit
- `kubectl annotate app ... refresh=hard` zeigt keine Wirkung
- Manual `kubectl patch app ... operation:{sync:{}}` "succeeded" aber nichts passiert

Fix: Application-Controller restarten (Abschnitt 6).

### 3.7 ArgoCD selfHeal-Storms waehrend Recovery (NEU)

Wenn man Hibernation-Annotation imperativ entfernt um Switchover zu
testen, ArgoCD selfHeal aber `automated.selfHeal=true` aktiv ist,
patcht ArgoCD die Annotation sofort aus Git zurueck. Mit Hibernation=on
ignoriert der Operator dann den Switchover-Patch und alles haengt.

Fix: selfHeal temporaer auf null setzen fuer die betroffenen Apps
WAHREND der Recovery-Phase. Am Ende wieder einschalten.

---

## 4. Pre-Flight Checks (BEVOR Recovery startet)

### 4.1 Cluster + Storage gesund

```bash
ENV=test          # oder prod
CTX=k8s-$ENV

# Nodes alle Ready?
kubectl --context $CTX get nodes
# Alle "Ready" - falls nicht: VM-Issues zuerst loesen

# Longhorn gesund?
kubectl --context $CTX get volume.longhorn.io -n longhorn-system | grep -cE "error|faulted"
# Soll 0 sein

# Pending PVCs?
kubectl --context $CTX get pvc -A | grep -v Bound
# Soll leer sein
```

### 4.2 NAS10 Performance

```bash
S3_KEY=$(kubectl --context $CTX get secret cnpg-s3-credentials -n databases -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
S3_SECRET=$(kubectl --context $CTX get secret cnpg-s3-credentials -n databases -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)

# Listing-Test
time s3cmd --host=nas10.eneg.de:8010 --host-bucket="" --no-ssl \
  --access_key=$S3_KEY --secret_key=$S3_SECRET ls s3://k8s-$ENV-postgres-wal/

# 16 MB Write-Test (DER entscheidende!)
dd if=/dev/urandom of=/tmp/nas10-precheck.bin bs=1M count=16 2>/dev/null
time s3cmd --host=nas10.eneg.de:8010 --host-bucket="" --no-ssl \
  --access_key=$S3_KEY --secret_key=$S3_SECRET \
  put /tmp/nas10-precheck.bin s3://k8s-$ENV-postgres-wal/test-precheck-$(date +%H%M).bin
rm /tmp/nas10-precheck.bin
```

⚠️ **Hartes Kriterium: 16 MB Write Real Time < 5s.**

Falls > 30s: NAS10 neu starten lassen, dann Test wiederholen.
Im Sturm-Fall waren es 46s — NACH Reboot 0.55s.

### 4.3 ArgoCD-Health-Check (Pre-Flight!)

**Dies ist der WICHTIGSTE Pre-Flight-Schritt.** Identifiziert "frozen"
Apps bevor sie zum Problem werden.

```bash
# Alle relevanten Apps inspizieren
for app in cnpg-cluster mariadb-cluster mariadb-operator mariadb-operator-crds; do
  echo "=== $app ==="
  kubectl --context $CTX get app $app -n argocd -o jsonpath='
sync={.status.sync.status}
health={.status.health.status}
revision={.status.sync.revision}
opPhase={.status.operationState.phase}
opStartedAt={.status.operationState.startedAt}
{"\n"}'
done
```

**Was ist OK:**
- `sync=Synced health=Healthy revision=<sha-40-char>`
- `opStartedAt` neuer als 7 Tage

**Was ist FROZEN (Reparatur noetig):**
- `revision=` leer
- `opStartedAt` Wochen alt
- Trotzdem `sync=Synced health=Healthy`

**Fix wenn frozen:**

```bash
# Application-Controller restarten (das ist sicher, alle anderen Apps laufen weiter)
kubectl --context $CTX rollout restart statefulset argocd-application-controller -n argocd
# 30s warten bis neue Pods ready
sleep 30
kubectl --context $CTX get pods -n argocd | grep application-controller

# Dann jede frozen App refreshen
for app in <frozen-apps>; do
  kubectl --context $CTX annotate app $app -n argocd argocd.argoproj.io/refresh=hard --overwrite
done

# 60s warten und nochmal pruefen ob revision jetzt gesetzt ist
sleep 60
# (oben den Check wiederholen)
```

### 4.4 Bestandsaufnahme (Recovery-Start-Punkt)

```bash
# Was steht aktuell in Git?
cd ~/git/eneg-k8s-infrastructure-v2
grep -A 1 hibernation kubernetes/environments/$ENV/cnpg-cluster/*.yaml | head -20
grep replicas kubernetes/environments/$ENV/mariadb-cluster/mariadb-galera.yaml
grep -c instanceSidecarConfiguration kubernetes/environments/$ENV/cnpg-cluster/objectstore-*.yaml
# Soll 2 sein wenn env-vars schon drin

# Cluster-State
kubectl --context $CTX get cluster -n databases
kubectl --context $CTX get pods -n databases -l 'cnpg.io/cluster' -o wide
kubectl --context $CTX get mariadb -n databases
kubectl --context $CTX get pods -n mariadb-operator
kubectl --context $CTX get pods -n databases -l app.kubernetes.io/instance=mariadb-galera

# Drift: Cluster vs Git
kubectl --context $CTX get cluster cnpg-erp -n databases \
  -o jsonpath='hibernation={.metadata.annotations.cnpg\.io/hibernation}{"\n"}'
kubectl --context $CTX get mariadb mariadb-galera -n databases \
  -o jsonpath='git=<see-above> cluster={.spec.replicas}{"\n"}'
```

⚠️ **Bei Drift Cluster vs Git STOP und untersuchen** — vermutlich
"frozen" App-State. Erst reparieren, dann Recovery starten.

---

## 5. Helper: wait_argocd_sync()

Vor der Recovery diese Bash-Funktion in der Shell definieren:

```bash
# Wartet bis ArgoCD eine App auf einen Ziel-Commit gesynced hat
# Triggert dabei alle 10s einen Hard-Refresh
# Usage: wait_argocd_sync <app-name> <target-revision-sha> [timeout-seconds=180]
wait_argocd_sync() {
  local APP=$1
  local TARGET=$2
  local TIMEOUT=${3:-180}
  local START=$(date +%s)
  echo "Waiting for app '$APP' to sync to '$TARGET'..."
  while [ $(($(date +%s)-START)) -lt $TIMEOUT ]; do
    local CUR=$(kubectl --context $CTX get app $APP -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null)
    if [ "$CUR" = "$TARGET" ]; then
      local SYNC=$(kubectl --context $CTX get app $APP -n argocd -o jsonpath='{.status.sync.status}')
      local HEALTH=$(kubectl --context $CTX get app $APP -n argocd -o jsonpath='{.status.health.status}')
      echo "  Synced after $(($(date +%s)-START))s: sync=$SYNC health=$HEALTH"
      return 0
    fi
    echo "  ...current=$CUR (waiting ${TIMEOUT}s max)"
    kubectl --context $CTX annotate app $APP -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1
    sleep 10
  done
  echo "  TIMEOUT after ${TIMEOUT}s waiting for $APP - manual check required"
  return 1
}
```

Anwendung nach jedem Push:
```bash
TARGET_REV=$(git rev-parse HEAD)
wait_argocd_sync cnpg-cluster $TARGET_REV
```

---

## 6. Recovery-Sequenz (Optimierte Reihenfolge)

### Phase 0: selfHeal AUS fuer kritische Apps

Verhindert dass ArgoCD waehrend der Recovery unsere imperativen
Aktionen rueckgaengig macht.

```bash
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'
  # Setzt automated auf null (selfHeal+prune aus), behaelt syncOptions
done

# Verifizieren
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  echo -n "$app automated: "
  kubectl --context $CTX get app $app -n argocd -o jsonpath='{.spec.syncPolicy.automated}'
  echo ""
done
# Soll fuer alle drei leer sein
```

⚠️ Diese Apps werden in Phase 9 wieder auf selfHeal=true gesetzt.
Bis dahin muss man Syncs manuell triggern oder per `wait_argocd_sync`.

### Phase 1: Hibernation aus den Cluster-CRs entfernen

**Reihenfolge optimiert:** Hibernation IMMER zuerst raus, BEVOR andere
Aenderungen. Sonst blockiert sie alles weitere.

**Files:**
- `kubernetes/environments/$ENV/cnpg-cluster/cnpg-erp.yaml`
- `kubernetes/environments/$ENV/cnpg-cluster/cnpg-shared.yaml`

Den `annotations:`-Block mit `cnpg.io/hibernation: "on"` aus
`metadata:` entfernen.

**Commit + Push:**
```
feat($ENV/cnpg): Reaktivierung Phase 1 - Hibernation aus Cluster-CRs
```

**Verifikation:**
```bash
TARGET_REV=$(git rev-parse HEAD)
# Sync triggern + warten
kubectl --context $CTX annotate app cnpg-cluster -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
# Hint: selfHeal ist aus, also manueller Sync noetig
kubectl --context $CTX patch app cnpg-cluster -n argocd --type=merge \
  -p '{"operation":{"sync":{"revision":"'$TARGET_REV'"}}}'

wait_argocd_sync cnpg-cluster $TARGET_REV

# Hibernation wirklich weg?
kubectl --context $CTX get cluster cnpg-erp -n databases \
  -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}{"\n"}'
# Soll leer sein

kubectl --context $CTX get cluster cnpg-shared -n databases \
  -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}{"\n"}'
# Soll auch leer sein
```

### Phase 2: NAS10 boto3-Fix in beide ObjectStore-CRs

**Files:**
- `kubernetes/environments/$ENV/cnpg-cluster/objectstore-erp.yaml`
- `kubernetes/environments/$ENV/cnpg-cluster/objectstore-shared.yaml`

Nach `retentionPolicy: "7d"` ergaenzen:

```yaml
  # WORKAROUND 2026-05-15: NAS10/QuObjects boto3 InvalidDigest
  # Siehe docs/runbooks/cnpg-mariadb-recovery-from-storage-storm.md Abschnitt 3.1
  instanceSidecarConfiguration:
    env:
      - name: AWS_REQUEST_CHECKSUM_CALCULATION
        value: when_required
      - name: AWS_RESPONSE_CHECKSUM_VALIDATION
        value: when_required
```

**Commit + Push:**
```
fix($ENV/cnpg): NAS10 boto3 InvalidDigest Workaround in ObjectStore CRs
```

**Verifikation:**
```bash
TARGET_REV=$(git rev-parse HEAD)
kubectl --context $CTX patch app cnpg-cluster -n argocd --type=merge \
  -p '{"operation":{"sync":{"revision":"'$TARGET_REV'"}}}'
wait_argocd_sync cnpg-cluster $TARGET_REV

# env-vars wirklich im ObjectStore CR?
for store in cnpg-erp-objectstore cnpg-shared-objectstore; do
  echo "=== $store ==="
  kubectl --context $CTX get objectstore $store -n databases \
    -o jsonpath='{.spec.instanceSidecarConfiguration.env}{"\n"}'
done
```

### Phase 3: Plugin-Operator-Pod restarten

Plugin-Operator muss neue env-Variablen ueber gRPC weiterreichen.

```bash
kubectl --context $CTX delete pod -n cnpg-system -l app.kubernetes.io/name=plugin-barman-cloud
# 30s warten
sleep 30
kubectl --context $CTX get pods -n cnpg-system | grep plugin-barman
# Soll 1/1 Running mit AGE < 1m sein
```

### Phase 4: Pro Cluster — Switchover-Verfahren

**Sequenz fuer cnpg-erp UND cnpg-shared identisch.** Erst cnpg-erp
komplett durch, dann cnpg-shared.

```bash
CLUSTER=cnpg-erp                    # oder cnpg-shared
OLD_PRIMARY=$(kubectl --context $CTX get cluster $CLUSTER -n databases -o jsonpath='{.status.currentPrimary}')
STANDBY=$(kubectl --context $CTX get pods -n databases -l cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
echo "Cluster: $CLUSTER, Primary: $OLD_PRIMARY, Will switchover to: $STANDBY"
```

**4a) Standby loeschen → neuer Pod mit env-vars**

```bash
kubectl --context $CTX delete pod $STANDBY -n databases --force --grace-period=0
sleep 60

# env-vars im neuen Pod verifizieren
kubectl --context $CTX get pod $STANDBY -n databases -o json | grep -c AWS_REQUEST_CHECKSUM
# Soll 2 sein

# Pod 2/2 Ready?
kubectl --context $CTX get pod $STANDBY -n databases
```

**4b) Switchover triggern**

```bash
kubectl --context $CTX patch cluster $CLUSTER -n databases \
  --type=merge --subresource=status \
  -p "{\"status\":{\"targetPrimary\":\"$STANDBY\"}}"

# 60s warten
sleep 60
kubectl --context $CTX get cluster $CLUSTER -n databases \
  -o jsonpath='current={.status.currentPrimary} target={.status.targetPrimary}{"\n"}'
# current und target sollen jetzt $STANDBY sein
```

**4c) WAL-Archive verifizieren**

```bash
NEW_PRIMARY=$STANDBY
kubectl --context $CTX logs $NEW_PRIMARY -n databases -c plugin-barman-cloud --since=2m \
  | grep -E "Executing|Archived|InvalidDigest" | tail -10
# Soll "Archived WAL file" mit elapsedWalTime ~0.3-0.7s zeigen
# Falls noch InvalidDigest: env-vars nicht propagiert -> Plugin-Pod nochmal restarten

# Pending WALs
kubectl --context $CTX exec $NEW_PRIMARY -n databases -c postgres -- \
  bash -c "ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status/*.ready 2>/dev/null | wc -l"
# Soll innerhalb von 30s auf 0 sinken
```

### Phase 5: Force-Delete restlicher alter Standbys

Nach Switchover sind 2 Pods pro Cluster noch alte Replicas ohne
env-vars. **Sequentiell mit 75s Pause:**

```bash
# Alle Pods die NICHT der neue Primary sind
for pod in $(kubectl --context $CTX get pods -n databases -l cnpg.io/cluster=$CLUSTER \
             -o jsonpath='{.items[?(@.metadata.name!="'$NEW_PRIMARY'")].metadata.name}'); do
  echo "=== Force-Delete $pod ==="
  kubectl --context $CTX delete pod $pod -n databases --force --grace-period=0
  sleep 75
  kubectl --context $CTX get pod $pod -n databases
done

# Finaler Check pro Cluster
kubectl --context $CTX get cluster $CLUSTER -n databases
# Soll READY=3 zeigen, STATUS=Cluster in healthy state
```

⚠️ Falls Pod hangs 1/2 mit `pg_rewind exit 1` Logs → Phase 6.

### Phase 6: pg_rewind-Failure → komplett-Reset

Bei Replicas mit divergierender WAL-Historie:

```bash
POD=cnpg-shared-4    # der hängende Pod

# Pod + beide PVCs loeschen
kubectl --context $CTX delete pod $POD -n databases --force --grace-period=0
kubectl --context $CTX delete pvc $POD ${POD}-wal -n databases --wait=false

# Falls Finalizer-stuck:
kubectl --context $CTX patch pvc $POD -n databases --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null
kubectl --context $CTX patch pvc ${POD}-wal -n databases --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null

# Operator erstellt neuen Pod mit naechstem freien Index + pg_basebackup
sleep 60
kubectl --context $CTX get pods -n databases -l cnpg.io/cluster=$CLUSTER
```

### Phase 7: MariaDB Pre-Check

**WICHTIG:** Sicherstellen dass Galera-CR in Git auf `replicas=0` ist
BEVOR Operator hochgefahren wird. Sonst startet er beim Hochfahren
sofort Recovery — auf einem PVC-State der evtl. nicht ready ist.

```bash
# Was steht in Git?
grep -A 1 "^  replicas:" kubernetes/environments/$ENV/mariadb-cluster/mariadb-galera.yaml
# Soll "replicas: 0" sein

# Was im Cluster?
kubectl --context $CTX get mariadb mariadb-galera -n databases -o jsonpath='{.spec.replicas}{"\n"}'
# Soll auch 0 sein - falls 3: Drift! Erst auf 0 patchen:
kubectl --context $CTX patch mariadb mariadb-galera -n databases --type=merge \
  -p '{"spec":{"replicas":0,"replicasAllowEvenNumber":true}}'
```

### Phase 8: MariaDB-Operator reaktivieren

**File:** `kubernetes/base/mariadb-galera/operator/values.yaml`

Vor `metrics:` ergaenzen:
```yaml
# Operator als Singleton (Default des Charts, explizit gesetzt damit
# ArgoCD selfHeal den State sauber erkennen kann)
replicas: 1
```

**Commit + Push:**
```
fix(mariadb-operator): replicas=1 explizit setzen
```

```bash
TARGET_REV=$(git rev-parse HEAD)

# Manueller Sync (selfHeal ist aus aus Phase 0)
kubectl --context $CTX patch app mariadb-operator -n argocd --type=merge \
  -p '{"operation":{"sync":{"revision":"'$TARGET_REV'"}}}'
wait_argocd_sync mariadb-operator $TARGET_REV 240

# Operator Pod hochgekommen?
kubectl --context $CTX get pods -n mariadb-operator
# Soll mariadb-operator-XXX 1/1 Running zeigen
```

⚠️ **Falls App-Sync nicht durchgeht (war auf DEV der Fall):**
Application-Controller wurde vermutlich nicht restartet in Phase 4.3.
Imperativer Workaround:
```bash
kubectl --context $CTX scale deployment mariadb-operator -n mariadb-operator --replicas=1
```

### Phase 9: MariaDB-Galera CR reaktivieren

**JETZT** (nicht frueher!) — Operator ist stabil hochgefahren.

**File:** `kubernetes/environments/$ENV/mariadb-cluster/mariadb-galera.yaml`

```yaml
spec:
  image: mariadb:11.8.6
  # Reaktiviert YYYY-MM-DD: nach Cluster-Recovery wieder voller 3-Node-Betrieb.
  replicas: 3
```

Das `replicasAllowEvenNumber: true` Flag entfernen (war nur fuer
replicas=0 Validierungs-Bypass).

**Commit + Push:**
```
feat($ENV/mariadb): Galera replicas 0 -> 3 (Reaktivierung)
```

```bash
TARGET_REV=$(git rev-parse HEAD)
kubectl --context $CTX patch app mariadb-cluster -n argocd --type=merge \
  -p '{"operation":{"sync":{"revision":"'$TARGET_REV'"}}}'
wait_argocd_sync mariadb-cluster $TARGET_REV

# Galera-Recovery beobachten (~3-5 Min)
for i in 1 2 3 4 5; do
  sleep 60
  echo "=== Iteration $i ==="
  kubectl --context $CTX get pods -n databases -l app.kubernetes.io/instance=mariadb-galera
  kubectl --context $CTX get mariadb mariadb-galera -n databases
done
```

### Phase 10: selfHeal wieder ANSCHALTEN

```bash
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'
done

# Verifizieren
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  echo -n "$app automated: "
  kubectl --context $CTX get app $app -n argocd -o jsonpath='{.spec.syncPolicy.automated}'
  echo ""
done
# Sollte alle '{"prune":true,"selfHeal":true}' zeigen
```

---

## 7. Verifikation (Post-Recovery Checks)

```bash
# CNPG: beide Cluster healthy
kubectl --context $CTX get cluster -n databases
# Erwartung: READY=3, STATUS=Cluster in healthy state fuer beide

# Pending WALs auf beiden Primaries
for cluster in cnpg-erp cnpg-shared; do
  PRIMARY=$(kubectl --context $CTX get cluster $cluster -n databases -o jsonpath='{.status.currentPrimary}')
  echo -n "$cluster (Primary: $PRIMARY) pending WALs: "
  kubectl --context $CTX exec $PRIMARY -n databases -c postgres -- bash -c \
    "ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status/*.ready 2>/dev/null | wc -l"
done
# Soll 0 / 0 sein

# MariaDB Galera 3/3 Ready
kubectl --context $CTX get mariadb mariadb-galera -n databases
# Erwartung: READY=True, STATUS=Running

# Alle DB-Pods 2/2 Ready, 0 Restarts
kubectl --context $CTX get pods -n databases

# Anti-Affinity verifizieren
kubectl --context $CTX get pods -n databases -o wide | awk 'NR>1 {print $7}' | sort | uniq -c

# WAL-Archive aktiv
PRIMARY=$(kubectl --context $CTX get cluster cnpg-erp -n databases -o jsonpath='{.status.currentPrimary}')
kubectl --context $CTX logs $PRIMARY -n databases -c plugin-barman-cloud --tail=20 \
  | grep "Archived WAL file" | tail -3

# ArgoCD selfHeal wieder an
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  echo -n "$app: "
  kubectl --context $CTX get app $app -n argocd -o jsonpath='sync={.status.sync.status} health={.status.health.status} automated={.spec.syncPolicy.automated}{"\n"}'
done
```

---

## 8. Rollback (Falls Recovery scheitert)

```bash
# 1. selfHeal aus (verhindert ArgoCD-Race waehrend Rollback)
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

# 2. Git-Revert auf letzten bekannten guten Stand
cd ~/git/eneg-k8s-infrastructure-v2
git revert <commit-sha>...HEAD
git push

# 3. Manuelle Syncs ausloesen
TARGET_REV=$(git rev-parse HEAD)
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"operation":{"sync":{"revision":"'$TARGET_REV'"}}}'
  wait_argocd_sync $app $TARGET_REV
done

# 4. Hibernation re-enable falls noetig (CNPG)
kubectl --context $CTX annotate cluster cnpg-erp -n databases cnpg.io/hibernation=on --overwrite
kubectl --context $CTX annotate cluster cnpg-shared -n databases cnpg.io/hibernation=on --overwrite
```

---

## 9. Persistente Learnings

1. **NAS10/QuObjects boto3 ≥ 1.36 InvalidDigest-Bug.** Workaround:
   `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` in
   `instanceSidecarConfiguration.env`.

2. **CNPG plugin-barman-cloud Architektur:** Plugin-Operator-Pod im
   `cnpg-system` NS + Sidecar im Postgres-Pod. env-vars propagieren
   nur bei Pod-Recreate beider.

3. **CNPG Switchover ohne kubectl-cnpg-plugin:**
   `kubectl patch cluster X --type=merge --subresource=status
   -p '{"status":{"targetPrimary":"new"}}'`

4. **CNPG pg_rewind Fallback:** Bei exit 1 dann komplett-Reset
   (Pod + Daten-PVC + WAL-PVC loeschen) → pg_basebackup mit naechster
   freier Index-Nummer.

5. **ArgoCD selfHeal patcht Hibernation aus Git zurueck.** Daher
   Hibernation aus Git nehmen (Phase 1), nicht nur imperativ.

6. **Helm-Chart-Default-Replicas unsichtbar fuer ArgoCD ServerSideApply.**
   Explizit `replicas: N` in values.yaml setzen.

7. **ArgoCD "frozen" Apps** nach Storm: Application-Controller-Restart
   befreit sie aus dem stuck-State.

8. **selfHeal AUS waehrend Recovery** verhindert dass imperative
   Aktionen rueckgaengig gemacht werden. Am Ende wieder einschalten.

9. **Reihenfolge:** Hibernation → env-vars → Plugin-Pod-Restart →
   Standby-Restart → Switchover → Force-Delete restlicher Standbys.
   Niemals env-vars + Switchover ohne Hibernation-Removal vorher.

10. **Galera-Operator vs CR-Reihenfolge:** Operator-Pod hochfahren
    NUR wenn Galera-CR auf replicas=0 ist. Sonst startet er sofort
    Recovery auf altem PVC-State.

---

## 10. TEST/PROD Vorbereitung (Checkliste)

Vor Start einer TEST/PROD-Recovery-Session:

- [ ] Cluster-Snapshot von Longhorn-Volumes existiert (Sicherheit)
- [ ] Wartungsfenster mit Stakeholdern abgestimmt (besonders fuer PROD)
- [ ] Daniel kann ungestoert mehrere Stunden arbeiten
- [ ] Apps in der entsprechenden ENV sind auf 0 oder suspended
- [ ] Phase 4 (Pre-Flight) komplett gruen:
  - [ ] Nodes Ready
  - [ ] Longhorn keine Faulted Volumes
  - [ ] NAS10 16 MB Write < 5s
  - [ ] ArgoCD Apps NICHT "frozen" (revision matched HEAD, oder nach AC-Restart matched)
  - [ ] Drift Cluster vs Git geklaert
- [ ] Working-Rules eingehalten:
  - [ ] Daniel commitet/pushed
  - [ ] Claude bereitet Files vor
  - [ ] Sequentiell ENV-fuer-ENV
  - [ ] Optionen vor Implementierung
  - [ ] Kleine Schritte mit Verifikation

---

## 11. Aenderungshistorie

| Datum       | Aenderung                                                | Quelle |
|-------------|----------------------------------------------------------|--------|
| 2026-05-15  | v1: Initial nach DEV-Recovery erstellt                   | k8s-dev verifiziert |
| 2026-05-15  | v2: Retro-Optimierungen: ArgoCD selfHeal-Storm Schutz,   | DEV-Retro |
|             | Pre-Flight ArgoCD-Health-Check, Reihenfolge Hibernation  |        |
|             | zuerst, wait_argocd_sync Helper                          |        |
