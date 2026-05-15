# Runbook: K8s-Cluster Recovery nach Storage-Storm

**Letzte Aktualisierung:** 2026-05-15 (v6 — ksops-Defekt im Repo-Server dokumentiert, Section 3.10 korrigiert: Unknown *-secrets ist KEIN Normalzustand)
**Erstmals verifiziert:** DEV-Cluster (k8s-dev), 2026-05-14/15
**Status TEST/PROD:** ausstehend
**Verwandte Docs:**
- `docs/incidents/2026-05-11-mariadb-galera-recovery.md` (Ursprung)
- `docs/runbooks/longhorn-volume-expansion-deadlock.md`

---

## 1. Zweck dieses Runbooks

Komplette Recovery aller Cluster-Komponenten (Stateful Backend + Monitoring +
Backup + Pilot-Apps + Backup-Schedules) nach einem Storage-Storm oder
vergleichbaren mehrtaegigen Ausfall.

Das Runbook deckt vier Phasen ab:
- **Phase A (Stateful):** CNPG-Cluster + MariaDB Galera wiederherstellen
- **Phase B (Plumbing):** Monitoring + Velero reaktivieren
- **Phase C (Apps):** 6 Pilot-Apps in Abhaengigkeitsreihenfolge reaktivieren
- **Phase D (Backups + Cleanup):** Backup-Schedules unsuspenden, alte
  failed Jobs/orphaned Volumes aufraeumen

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
    brechen in manchen Shells.
12. **boto3-Fix an ALLEN Stellen anwenden** — der NAS10-InvalidDigest-Bug
    betrifft mehrere Komponenten (s. Abschnitt 3.1).

---

## 3. Root Causes (verifiziert auf DEV)

### 3.1 NAS10 boto3 InvalidDigest — TAUCHT AN MEHREREN STELLEN AUF

**Fehler:** `An error occurred (InvalidDigest) when calling the PutObject operation`

**Ursache:** boto3/awscli ≥ Versionen mit CRC32-Trailing-Checksums senden
diese standardmaessig (seit Jan 2025). QNAP QuObjects validiert das inkorrekt.

**Betroffene Komponenten (Stand DEV-Recovery 2026-05-15):**

| # | Komponente | Wo env-vars setzen | File |
|---|---|---|---|
| 1 | CNPG Plugin-Sidecar (WAL-Archive, Backup) | `spec.instanceSidecarConfiguration.env` der **ObjectStore-CRs** | `environments/$ENV/cnpg-cluster/objectstore-*.yaml` |
| 2 | CNPG logical-backup CronJobs (pg_dumpall + aws s3 cp) | `spec.jobTemplate.spec.template.spec.containers[0].env` der **CronJob-CRs** | `environments/$ENV/cnpg-backup/cronjob-*.yaml` |

**NICHT betroffen:** Backups mit `rclone` (eigener Go-S3-Client, keine
boto3-Checksums). Bei DEV: garage-backup, idoit-backup, odoo-backup.

**Fix (identisch fuer beide Stellen):**

```yaml
env:
  # ... bestehende env-vars ...
  - name: AWS_REQUEST_CHECKSUM_CALCULATION
    value: "when_required"
  - name: AWS_RESPONSE_CHECKSUM_VALIDATION
    value: "when_required"
```

**Bei Recovery: BEIDE Stellen fixen** — eine ohne die andere fuehrt zu
fehlgeschlagenen Backups (s. Phase A.2 fuer CNPG-Plugin, Phase D.2 fuer CronJobs).

**Diagnose: woran erkenne ich den Bug?**

- **Plugin-Sidecar (Stelle 1):** Im `plugin-barman-cloud`-Container-Log:
  ```
  ERROR: failed to upload WAL to S3 ... InvalidDigest
  ```
  Plus: WAL-pending steigt (`archive_status/*.ready > 0`).

- **CronJob-Backup (Stelle 2):** Im Backup-Pod-Log:
  ```
  upload failed: tmp/cnpg-XYZ.sql.gz to s3://... An error occurred (InvalidDigest)
  when calling the PutObject operation: The Content-MD5 or checksum value that you
  specified is not valid.
  ```
  Plus: Job ist `Failed`, BackoffLimitExceeded.

**Erfolgreicher Run nach Fix (DEV-Referenz):**
```
=== PostgreSQL Logical Backup ===
Running pg_dumpall against cnpg-erp-r.databases.svc.cluster.local...
Dump created: /tmp/cnpg-erp_2026-05-15_141533.sql.gz (1.4M)
Installing awscli...
awscli installed
Uploading to s3://k8s-dev-postgres-backup/cnpg-erp/cnpg-erp_2026-05-15_141533.sql.gz...
upload: tmp/cnpg-erp_... to s3://...
Upload complete
Cleaning backups older than 32 days...
=== Backup completed ===
```

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

Vor der Reaktivierung Drift-Inventory machen, Git mit faktischem Cluster-Stand
abgleichen, sonst Recovery-Schritte ueberfluessig oder gefaehrlich.

### 3.9 ArgoCD CronJob Health-Check (Degraded trotz keiner failed jobs)

Wenn ein CronJob nach Recovery weiter als **Degraded** in ArgoCD steht obwohl
alle Failed Jobs entfernt sind:

**Ursache:** ArgoCD's CronJob-Health-Check vergleicht `status.lastScheduleTime`
mit `status.lastSuccessfulTime`. Wenn lastSchedule neuer ist als lastSuccessful
(weil z.B. ein Test-Job beim Unsuspend gestartet und gefailt ist), bleibt die
App Degraded — auch wenn man die failed Jobs nachher loescht.

**Loesung:** Manuell einen Test-Job triggern (`kubectl create job --from=cronjob/...`).
Wenn der erfolgreich durchlaeuft, aktualisiert sich `lastSuccessfulTime` →
ArgoCD-Health wird automatisch Healthy.

### 3.10 ArgoCD "Unknown" Sync bei SOPS-encrypted Secret-Apps

Wenn alle (oder die meisten) `*-secrets` Apps `sync=Unknown` zeigen,
liegt das **NICHT** an einer SOPS-Eigenheit (haeufiger Irrglaube), sondern
am defekten **ksops-Binary im argocd-repo-server**. Siehe 3.11.

**Korrekte Erwartung:** `*-secrets` Apps sollen `Synced/Healthy` zeigen,
genau wie alle anderen Apps. KSOPS+SOPS rendern die encrypted Manifests
zur Diff-Vergleichszeit und liefern ArgoCD vollwertige Plain-Resources.

Wenn nur Einzelne `*-secrets` Apps Unknown sind: anderes Problem (z.B.
fehlender Secret-Key im Age-Keyring, falscher Pfad in kustomization.yaml).

### 3.11 ksops-Binary im Repo-Server defekt (silent install-failure)

**Symptom:** Viele/alle `*-secrets` Apps zeigen `sync=Unknown` mit
ComparisonError:
```
ComparisonError: Failed to load target state: failed to generate manifest
for source 1 of 1: rpc error: code = Unknown desc =
`kustomize build ... --enable-alpha-plugins --enable-exec` failed:
Error: couldn't execute function: exec: "ksops": executable file not found in $PATH
```

**Ursache:** Der Init-Container `install-ksops` im
`argocd-repo-server` Pod laedt ksops, kustomize und SOPS bei jedem
Pod-Start von GitHub-Releases. Bei transientem 404 / Redirect-Issue mit
BusyBox `wget` (alpine) schlaegt der Download fehl, der Init-Container
laeuft aber **silent weiter** (kein `set -e`), endet "successfully" und
der main-Container startet ohne ksops.

**Diagnose:**

```bash
POD=$(kubectl --context $CTX get pods -n argocd \
  -l app.kubernetes.io/name=argocd-repo-server --no-headers \
  | head -1 | awk '{print $1}')

# Init-Container-Log auf wget-Fehler pruefen
kubectl --context $CTX logs -n argocd $POD -c install-ksops | \
  grep -E "404|Not Found|No such file|tar:"

# ksops im main-Container vorhanden?
kubectl --context $CTX exec -n argocd $POD -c argocd-repo-server -- \
  ls -la /usr/local/bin/ksops 2>&1
```

**Quick-Fix:** Pod loeschen + neuer Pod-Start, oft funktioniert der
Download beim Retry (GitHub-CDN-Glitch).

```bash
kubectl --context $CTX delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
sleep 30
# Init-Container-Log pruefen, ksops-Existenz verifizieren
```

**Permanent-Fix (ab Patch-v2, 2026-05-15):** Der Patch
`kubernetes/base/argocd/argocd-repo-server-ksops-patch.yaml` nutzt jetzt
`set -euo pipefail` + `curl -fSL --retry 5` + `test -x` nach jeder
Install-Phase. Bei Download-Fehler schlaegt der Pod nun in
`CrashLoopBackoff` fehl (sichtbar) statt silent ohne ksops zu laufen.

Bei Recovery: Diese Patch-Version muss im Cluster aktiv sein. Pruefen mit
`kubectl get deploy argocd-repo-server -n argocd -o yaml | grep "set -euo"`.
Wenn nicht: `kubectl apply -f kubernetes/base/argocd/argocd-repo-server-ksops-patch.yaml`

---

## 4. Pre-Flight Checks (BEVOR Recovery startet)

### 4.1 Cluster + Storage

```bash
ENV=test          # oder prod
CTX=k8s-$ENV

kubectl --context $CTX get nodes
kubectl --context $CTX get volume.longhorn.io -n longhorn-system | grep -cE "error|faulted"   # Soll 0
kubectl --context $CTX get pvc -A | grep -v Bound                                              # Soll leer
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
for app in cnpg-cluster cnpg-logical-backup mariadb-cluster mariadb-operator \
           mariadb-operator-crds monitoring thanos loki velero \
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
- `sync=Unknown` bei einer Einzel-App: anderes Problem

**KSOPS-DEFEKT (Fix s. 3.11):**
- Mehrere/alle `*-secrets` Apps zeigen `sync=Unknown` → KEIN Normalzustand!
- Pruefen mit:
  ```bash
  POD=$(kubectl --context $CTX get pods -n argocd \
    -l app.kubernetes.io/name=argocd-repo-server --no-headers | head -1 | awk '{print $1}')
  kubectl --context $CTX exec -n argocd $POD -c argocd-repo-server -- \
    ls /usr/local/bin/ksops 2>&1
  ```
  Wenn "No such file" → Quick-Fix (Pod loeschen) oder Patch-v2 anwenden.

**Fix wenn ≥ 1 echte App frozen:**

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
# Welche Komponenten haben Cluster-State != Git?
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

# CronJob-Suspend Status (NEU in v4)
echo "=== Drift-Check: CronJob suspend ==="
for cj in "databases cnpg-erp-logical-backup" "databases cnpg-shared-logical-backup" \
          "garage garage-backup" "idoit idoit-backup" "odoo odoo-backup"; do
  NS=$(echo $cj | cut -d' ' -f1)
  NAME=$(echo $cj | cut -d' ' -f2)
  echo -n "  $NS/$NAME: suspend="
  kubectl --context $CTX get cronjob $NAME -n $NS -o jsonpath='{.spec.suspend}' 2>/dev/null
  echo ""
done

# boto3-Fix in CronJobs schon vorhanden? (NEU in v4)
echo "=== Drift-Check: boto3-env-vars im CronJob ==="
for cj in cnpg-erp-logical-backup cnpg-shared-logical-backup; do
  HAS_FIX=$(kubectl --context $CTX get cronjob $cj -n databases \
    -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="AWS_REQUEST_CHECKSUM_CALCULATION")].value}' 2>/dev/null)
  if [ "$HAS_FIX" = "when_required" ]; then
    echo "  $cj: boto3-fix vorhanden ✓"
  else
    echo "  $cj: boto3-fix FEHLT — Phase D.2 noetig!"
  fi
done

# Failed Jobs / Pods
echo "=== Drift-Check: Failed Jobs/Pods ==="
kubectl --context $CTX get jobs -A --no-headers 2>/dev/null | awk '$4=="0/1"{print "  FAILED: "$1"/"$2}'
kubectl --context $CTX get pods -A --field-selector=status.phase=Failed --no-headers 2>/dev/null | head -10

# Orphaned Longhorn Volumes
echo "=== Drift-Check: Detached Longhorn Volumes ==="
kubectl --context $CTX get volume.longhorn.io -n longhorn-system --no-headers 2>/dev/null | awk '$2=="v1" && $3=="detached"{print "  "$1}'
```

⚠️ Bei Drift "Apps laufen schon obwohl Git=0/false": Phase B+C koennen sich
zu blossen Drift-Bereinigungen verkleinern. Phase A bleibt unveraendert kritisch.

### 4.5 Bestandsaufnahme + Sicherheit

```bash
cd ~/git/eneg-k8s-infrastructure-v2

# Wo hat TEMP-Kommentare? (Stand DEV-Recovery 14.05.2026)
grep -rln "TEMP 2026-05-14" kubernetes/environments/$ENV/

# Was steht suspended in Git? (Schedule-Drift)
grep -rln "suspend: true" kubernetes/environments/$ENV/

# Longhorn-Backup-Snapshot existiert? (Sicherheit fuer PROD!)
kubectl --context $CTX get volumesnapshots -A | head -10
```

**Fuer PROD zusaetzlich:**
- Wartungsfenster mit Stakeholdern abgestimmt
- Vorab-Velero-Backup oder Longhorn-Snapshot manuell ausgeloest
- Mehrere Stunden ungestoerte Arbeitszeit

---

## 5. Helper: wait_argocd_sync()

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

Commit + Push + `wait_argocd_sync cnpg-cluster <rev>`.

### A.2 NAS10 boto3-Fix in ObjectStore-CRs (CNPG Plugin-Sidecar)

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

⚠️ Das ist nur Stelle 1 von 2 fuer den boto3-Fix. Stelle 2 (Backup-CronJobs)
folgt in Phase D.2.

Commit + Push + wait_argocd_sync.

### A.3 Plugin-Operator-Pod restart

```bash
kubectl --context $CTX delete pod -n cnpg-system -l app.kubernetes.io/name=plugin-barman-cloud
sleep 30
```

### A.4 Pro CNPG-Cluster: Switchover (cnpg-erp + cnpg-shared)

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
```

### A.6 pg_rewind-Failure → komplett-Reset

```bash
POD=cnpg-shared-4    # der hängende Pod
kubectl --context $CTX delete pod $POD -n databases --force --grace-period=0
kubectl --context $CTX delete pvc $POD ${POD}-wal -n databases --wait=false
sleep 60
```

⚠️ Nach komplett-Reset bleiben die alten PVCs als "orphaned detached Volumes"
in Longhorn zurueck. Phase D.4 raeumt das auf.

### A.7 MariaDB-Operator reaktivieren

Pre-Check: Galera-CR in Git auf `replicas: 0`?

File: `kubernetes/base/mariadb-galera/operator/values.yaml`

```yaml
replicas: 1
```

Commit + Push + wait_argocd_sync.

### A.8 MariaDB-Galera CR reaktivieren

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
kubectl --context $CTX get cluster -n databases                                                  # READY=3 fuer beide
for cluster in cnpg-erp cnpg-shared; do
  PRIMARY=$(kubectl --context $CTX get cluster $cluster -n databases -o jsonpath='{.status.currentPrimary}')
  echo -n "$cluster pending WALs: "
  kubectl --context $CTX exec $PRIMARY -n databases -c postgres -- bash -c \
    "ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status/*.ready 2>/dev/null | wc -l"     # 0
done
kubectl --context $CTX get mariadb mariadb-galera -n databases                                  # READY=True
```

---

## 7. PHASE B — Plumbing (Monitoring + Velero)

**Dauer DEV: ~30 Min.**

### B.1 Monitoring — kube-prometheus-stack

File: `kubernetes/environments/$ENV/monitoring/values-override.yaml`

Diese 4 Blocks entfernen/anpassen:
1. `prometheus.prometheusSpec.replicas: 0` → Zeile entfernen
2. `alertmanager.alertmanagerSpec.replicas: 0` Block entfernen (oder `replicas: 1`)
3. `grafana:` Block (war nur replicas: 0) komplett entfernen
4. `kube-state-metrics:` Block komplett entfernen

Alle "TEMP 2026-MM-DD" Kommentare entfernen.

Commit + Push. ~3 Min bis alle hoch.

### B.2 Monitoring — Thanos

File: `kubernetes/environments/$ENV/monitoring-thanos/values-override.yaml`

- `compactor.replicaCount: 0` entfernen (PVC-Size 30Gi bleibt!)
- `query:` Block entfernen
- `storegateway:` Block entfernen

Commit + Push. ~1 Min bis alle hoch.

### B.3 Loki Drift-Cleanup

File: `kubernetes/environments/$ENV/monitoring-loki/values-override.yaml`

- `singleBinary.replicas: 0` entfernen
- `gateway: enabled: false` Block entfernen
- `chunksCache: enabled: false` Block entfernen
- `resultsCache: enabled: false` Block entfernen
- `lokiCanary: enabled: false` Block entfernen

(Komponenten laufen meist schon — Drift wird bereinigt)

### B.4 Velero reaktivieren

File: `kubernetes/environments/$ENV/velero/values-override.yaml`

- `replicaCount: 0` entfernen
- `nodeAgent.enable: false` entfernen
- In `schedules.daily-backup:`: `disabled: true` entfernen

Commit + Push. Velero-Daily-Schedule wird aktiv.

### B.5 Phase B Verifikation

```bash
kubectl --context $CTX get deployment,sts -n monitoring | grep -v "0/0"   # alle >= 1/1
kubectl --context $CTX get schedules -n velero                            # PAUSED leer
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
git add kubernetes/environments/$ENV/apps/<APP>/deployment.yaml
git commit -m "feat($ENV/<APP>): Reaktivierung replicas 0 -> 1"
git push

# 5. HEAD-Check (Daniel sagt 'gepushed' — vertrauen aber verifizieren)
git log --oneline -1

# 6. ArgoCD Sync abwarten + Pods beobachten
sleep 60
kubectl --context $CTX get pods -n <APP>
```

### C.2 Spezialfall openproject

**openproject** hat 4 Deployments — alle 4 mit unique `metadata.name`
als Anker patchen (gleichzeitiger Commit):

- openproject-memcached
- openproject-hocuspocus
- openproject-web (`strategy: Recreate`)
- openproject-worker

PostSync-Job `openproject-seeder` laeuft automatisch.

### C.3 Voraussetzungen pro App

| App | Postgres | MariaDB | Keycloak | S3 (Garage) | Longhorn-PVC |
|---|---|---|---|---|---|
| keycloak | cnpg-shared | – | – | – | – |
| it-info-versand | cnpg-shared | – | ja | – | – |
| n8n | cnpg-shared | – | – | – | n8n-data (5Gi) |
| openproject | cnpg-shared | – | ja (OIDC) | ja (Attachments) | openproject-tmp |
| odoo | cnpg-erp | – | – | – | odoo-filestore (10Gi) |
| idoit | – | ja | – | – | idoit-data |

---

## 9. PHASE D — Backup-Schedules + Cleanup (NEU in v4)

**Dauer DEV: ~30-60 Min.**

Nach Phase C sind Apps healthy aber die Backup-Schedules (CronJobs +
ScheduledBackups) sind oft noch suspended aus dem Recovery-Beginn. Plus
es bleiben Artefakte (Failed Jobs, orphaned Volumes).

⚠️ **WICHTIG — Reihenfolge in v4 optimiert:**
D.1 (Unsuspend) und D.2 (boto3-Fix in CronJobs) **MUESSEN in einem
gemeinsamen Commit** erfolgen — sonst triggern die CronJobs bei Unsuspend
durch `startingDeadlineSeconds` automatische Nachholversuche, die ohne den
boto3-Fix fehlschlagen → Failed Jobs → ArgoCD Degraded.

**Erlebt bei DEV-Recovery 2026-05-15:** Phase D.1 zuerst gemacht, dann erst
beim Test (D.3) entdeckt dass auch in den CronJobs der boto3-Fix fehlt.
Dadurch entstanden 2 unnoetige Failed Jobs + 1 Stunde extra Diagnose.
Bei TEST/PROD: D.1 + D.2 zusammen!

### D.1 Backup-Schedules unsuspenden — Git-Patches

**8 Files anpassen** (Stand DEV 2026-05-15), suspend-Eintraege entfernen:

| File | Schedule | Was wird unsuspendet |
|---|---|---|
| `environments/$ENV/cnpg-backup/cronjob-erp.yaml` | 05:15 | CNPG-erp logical backup (pg_dumpall) |
| `environments/$ENV/cnpg-backup/cronjob-shared.yaml` | 05:00 | CNPG-shared logical backup |
| `environments/$ENV/garage-backup/cronjob.yaml` | 05:30 | Garage S3 → NAS10 |
| `environments/$ENV/mariadb-cluster/physical-backup.yaml` | 04:30 | MariaDB Physical Backup |
| `environments/$ENV/apps/idoit/backup/cronjob.yaml` | 06:30 | i-doit Backup |
| `environments/$ENV/apps/odoo/backup/cronjob.yaml` | 06:15 | Odoo Filestore Backup |
| `environments/$ENV/cnpg-cluster/scheduled-backup.yaml` | 04:45 + 04:50 | **2 Stellen!** cnpg-shared-full + cnpg-erp-full |

Aus jedem Block den TEMP-Kommentar + `suspend: true` (oder `suspend: true`
im `schedule:`-Block bei MariaDB physical) entfernen.

Commit + Push + wait_argocd_sync.

⚠️ Bei PROD: Schedule-Times pruefen — laufen nicht mitten in Recovery!

### D.2 boto3-Fix in Backup-CronJobs (Stelle 2 von 2!)

Files: `environments/$ENV/cnpg-backup/cronjob-erp.yaml` + `cronjob-shared.yaml`

Im `spec.jobTemplate.spec.template.spec.containers[0].env` Block, NACH den
AWS_*-Secrets, ergaenzen:

```yaml
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: cnpg-s3-credentials, key: ACCESS_KEY_ID } }
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: cnpg-s3-credentials, key: SECRET_ACCESS_KEY } }
                # WORKAROUND: NAS10/QuObjects boto3 InvalidDigest
                - name: AWS_REQUEST_CHECKSUM_CALCULATION
                  value: "when_required"
                - name: AWS_RESPONSE_CHECKSUM_VALIDATION
                  value: "when_required"
```

⚠️ **NUR bei Backup-CronJobs die awscli/boto3 nutzen** (CNPG logical-backup).
Rclone-basierte Backups (garage, idoit, odoo) sind nicht betroffen.

Commit + Push + wait_argocd_sync.

### D.3 Test-Job triggern + verifizieren

Bevor die naechtlichen Schedules laufen, manuell verifizieren:

```bash
TS=$(date +%H%M%S)
kubectl --context $CTX create job --from=cronjob/cnpg-erp-logical-backup -n databases cnpg-erp-test-$TS
sleep 90
kubectl --context $CTX get jobs -n databases -l app.kubernetes.io/part-of=cloudnative-pg --sort-by=.metadata.creationTimestamp | tail -3
# Soll Complete 1/1 zeigen

# Pod-Logs auf "Upload complete" pruefen
POD=$(kubectl --context $CTX get pods -n databases -l batch.kubernetes.io/job-name=cnpg-erp-test-$TS --no-headers | head -1 | awk '{print $1}')
kubectl --context $CTX logs $POD -n databases | grep -E "InvalidDigest|Upload complete"
# Soll "Upload complete" zeigen, KEIN "InvalidDigest"
```

Wenn erfolgreich: ArgoCD-CronJob-Health wird automatisch Healthy (siehe 3.9).

Test analog fuer `cnpg-shared-logical-backup`.

### D.4 Failed Jobs aufraeumen

```bash
# Failed Jobs aus dem Storm-Zeitraum loeschen
kubectl --context $CTX get jobs -A --no-headers | awk '$4=="0/1"{print $1, $2}' | while read NS NAME; do
  kubectl --context $CTX delete job -n $NS $NAME
done
```

### D.5 Orphaned Longhorn Volumes aufraeumen

```bash
# Detached Volumes ohne zugehoerige PVC
kubectl --context $CTX get volume.longhorn.io -n longhorn-system --no-headers | awk '$3=="detached"{print $1}'

# Pro Volume: pruefen ob PVC noch existiert
for vol in <volume-names>; do
  PVC_NAME=$(kubectl --context $CTX get volume.longhorn.io $vol -n longhorn-system -o jsonpath='{.status.kubernetesStatus.pvcName}')
  PVC_NS=$(kubectl --context $CTX get volume.longhorn.io $vol -n longhorn-system -o jsonpath='{.status.kubernetesStatus.namespace}')
  if ! kubectl --context $CTX get pvc $PVC_NAME -n $PVC_NS &>/dev/null; then
    echo "ORPHANED: $vol (was $PVC_NS/$PVC_NAME)"
    # → ueber Longhorn GUI loeschen (sicherer) oder:
    # kubectl --context $CTX delete volume.longhorn.io $vol -n longhorn-system
  fi
done
```

**Empfehlung:** Loeschen ueber Longhorn-GUI (Safe-Delete-Workflow).

### D.6 ArgoCD Drift-Cleanup

Nach allen Phasen pruefen ob noch ArgoCD-Apps OutOfSync oder Degraded:

```bash
kubectl --context $CTX get app -n argocd --no-headers | awk '$2!="Synced" || $3!="Healthy" {print "  "$1": "$2"/"$3}'
```

**Erwartet:** Alle Apps `Synced/Healthy`. Falls mehrere `*-secrets` Apps
`Unknown` zeigen → ksops-Defekt im Repo-Server (siehe 3.11).

Falls eine `cnpg-logical-backup` App noch Degraded ist trotz Phase D.3: ein
Test-Job hat noch keinen Erfolgs-Run produziert. Test-Run wiederholen.

### D.7 Alertmanager-Notifications verifizieren

```bash
# Prufen ob Notifications versendet werden (Logs)
kubectl --context $CTX logs deployment/prometheus-msteams -n monitoring --since=10m | grep "status\":200"

# Email-Verifikation: Mailbox d.henke@eneg.de checken
```

Auf DEV waren Mails ab 15:58 nachweisbar (User-Bestaetigung).

---

## 10. Verifikation (Post-Recovery Komplett-Check)

```bash
# CNPG
kubectl --context $CTX get cluster -n databases
for cluster in cnpg-erp cnpg-shared; do
  PRIMARY=$(kubectl --context $CTX get cluster $cluster -n databases -o jsonpath='{.status.currentPrimary}')
  echo -n "$cluster pending WALs: "
  kubectl --context $CTX exec $PRIMARY -n databases -c postgres -- bash -c \
    "ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status/*.ready 2>/dev/null | wc -l"
done

# MariaDB
kubectl --context $CTX get mariadb mariadb-galera -n databases

# Apps
for ns in keycloak it-info-versand n8n openproject odoo idoit; do
  kubectl --context $CTX get deployment -n $ns --no-headers
done

# Backup-Schedules
kubectl --context $CTX get cronjobs --all-namespaces --no-headers | grep -v kube-system | awk '$5=="True"{print "  STILL SUSPENDED: "$1"/"$2}'

# ArgoCD
kubectl --context $CTX get app -n argocd --no-headers | grep -v "Synced.*Healthy" | grep -v "Unknown.*Healthy"

# Aktive Alerts
kubectl --context $CTX exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/alerts'
```

---

## 11. Rollback

```bash
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

cd ~/git/eneg-k8s-infrastructure-v2
git revert <commit-sha>...HEAD
git push

TARGET_REV=$(git rev-parse HEAD)
for app in cnpg-cluster mariadb-cluster mariadb-operator; do
  kubectl --context $CTX patch app $app -n argocd --type=merge \
    -p '{"operation":{"sync":{"revision":"'$TARGET_REV'"}}}'
  wait_argocd_sync $app $TARGET_REV
done

kubectl --context $CTX annotate cluster cnpg-erp -n databases cnpg.io/hibernation=on --overwrite
kubectl --context $CTX annotate cluster cnpg-shared -n databases cnpg.io/hibernation=on --overwrite
```

---

## 12. Persistente Learnings

1. **NAS10/QuObjects boto3 InvalidDigest TAUCHT AN 2 STELLEN AUF.** Beide
   muessen unabhaengig gefixt werden:
   a) CNPG Plugin-Sidecar (Phase A.2)
   b) CNPG Logical-Backup CronJobs (Phase D.2)
   Rclone-basierte Backups sind NICHT betroffen.

2. **CNPG plugin-barman-cloud** — env-vars propagieren nur bei Pod-Recreate.

3. **CNPG Switchover ohne kubectl-cnpg-plugin** via subresource-Patch.

4. **CNPG pg_rewind Fallback** — komplett-Reset, pg_basebackup mit neuem Index.
   Hinterlaesst orphaned Longhorn-Volumes → Phase D.5 aufraeumen.

5. **ArgoCD selfHeal patcht Hibernation aus Git zurueck.**

6. **Helm-Chart-Defaults unsichtbar fuer ArgoCD ServerSideApply.**

7. **ArgoCD "frozen" Apps** — Application-Controller-Restart.

8. **selfHeal AUS waehrend Recovery** — verhindert Rollbacks.

9. **Reihenfolge:** Hibernation → env-vars → Plugin-Restart → Standby-Restart →
   Switchover → restliche Standbys.

10. **Galera-Operator-Reihenfolge:** CR replicas=0 BEVOR Operator hoch.

11. **Helm-Charts haben oft Drift** seit Storm — Drift-Inventory in Pre-Flight.

12. **`git diff --stat` ist unnoetig** — vor Commit selbst die Datei pruefen
    (`grep -n "replicas:" file`).

13. **Einzeilige Commit-Messages** — Heredocs/Unicode brechen in manchen Shells.

14. **HEAD-Check vor Beobachtungs-Loop** — "gepushed" Bestaetigung verifizieren.

15. **App-Reihenfolge** = Abhaengigkeitsreihenfolge: OIDC-Provider → Konsumenten.

16. **ArgoCD CronJob Health-Check** vergleicht lastSchedule vs lastSuccessful.
    Nach Recovery: 1 erfolgreicher Test-Job pro CronJob → ArgoCD wird Healthy.

17. **`*-secrets` Apps `sync=Unknown` ist KEIN Normalzustand**, sondern
    starkes Indiz fuer defektes ksops-Binary im argocd-repo-server (siehe
    3.11). Pre-Flight pruefen: `ls /usr/local/bin/ksops` im Repo-Server-Pod.
    Korrekturen v6 dieses Runbooks fixen die fruehere Fehl-Annahme aus v3-v5.

18. **CronJob startingDeadlineSeconds**: Beim Unsuspend versucht der CronJob
    verpasste Schedule-Runs nachzuholen. Bei NAS10/boto3-Bug failen diese
    sofort → Failed Jobs entstehen → ArgoCD wird Degraded.
    **Konsequenz:** D.1 (Unsuspend) und D.2 (boto3-Fix in CronJobs) IMMER in
    einem gemeinsamen Commit pushen — nicht nacheinander.

19. **Backup-Stack: 8 Schedule-Files** wurden auf DEV suspended (5 CronJobs +
    1 MariaDB-PhysicalBackup + 2 CNPG-ScheduledBackups). Alle 8 muessen bei
    Reaktivierung in Git unsuspendet werden.

20. **boto3-Bug-Eingrenzung nach Backup-Tool:**
    - **boto3/awscli-basiert** (BETROFFEN): CNPG-Plugin Sidecars, CNPG
      logical-backup CronJobs
    - **rclone-basiert** (NICHT betroffen): garage-backup, idoit-backup,
      odoo-backup (rclone hat eigenen Go-S3-Client)
    - **MariaDB-Operator** (vermutlich nicht betroffen, Go-basiert)
    Pre-Flight: `grep -E "image:|aws s3|rclone|awscli" cronjob.yaml`

21. **Alertmanager-Notifications verifizieren nach Recovery:**
    - **Teams:** `prometheus-msteams` Pod-Logs → `"status":200` Eintraege
    - **Email:** Pruefung NUR via Mailbox d.henke@eneg.de (Alertmanager loggt
      SMTP-Sends nicht detailliert; nur Fehler erscheinen im Log)
    Bei DEV-Recovery: Mails ab 15:58 nachweisbar.

---

## 13. ENV-spezifische Vorbereitung

### TEST

- [ ] Pre-Flight Phase 4 komplett
- [ ] NAS10 16 MB Write < 5s
- [ ] ArgoCD Apps NICHT frozen (echte Apps, nicht `*-secrets`)
- [ ] Drift-Inventory durchgegangen (Vergleich DEV-Drift-Muster)
- [ ] Backup-Suspend-Inventar erstellt
- [ ] Mehrere Stunden ungestoerte Arbeitszeit

### PROD

- [ ] Wartungsfenster mit Stakeholdern abgestimmt
- [ ] Vorab-Velero-Backup oder Longhorn-Snapshot manuell ausgeloest
- [ ] Wartungsfenster-Banner in betroffenen Apps
- [ ] Notfall-Kontakte erreichbar
- [ ] Pre-Flight Phase 4 STRIKT
- [ ] DEV + TEST erfolgreich + verifiziert
- [ ] Mind. 4-6 Stunden ungestoerte Arbeitszeit
- [ ] **Backup-Schedule-Times pruefen** — laufen nicht waehrend Recovery

---

## 14. Aenderungshistorie

| Datum       | Aenderung                                                | Quelle |
|-------------|----------------------------------------------------------|--------|
| 2026-05-15  | v1: Initial nach DEV-Recovery erstellt                   | DEV verifiziert |
| 2026-05-15  | v2: Retro-Optimierungen (selfHeal-Storm, ArgoCD-frozen)  | DEV-Retro |
| 2026-05-15  | v3: App-Reaktivierungs-Phasen B+C ergaenzt, Drift-Inventory, | DEV komplett |
|             | Workflow-Lerning (HEAD-check, einzeilige Commits)        |        |
| 2026-05-15  | v4: Phase D (Backup-Schedules + Cleanup) ergaenzt,       | DEV Schedule-Reakt. |
|             | boto3-Bug-Fix an 2 Stellen dokumentiert, ArgoCD-CronJob- |        |
|             | Health-Check, 17 Unknown=SOPS Erklaerung, orphaned       |        |
|             | Volumes aus pg_rewind-Reset                              |        |
| 2026-05-15  | v5: Diagnose-Snippets fuer beide boto3-Bug-Stellen,      | DEV Backup-Test |
|             | Phase D Reihenfolge optimiert (D.1+D.2 in einem Commit), | + Notification- |
|             | Pre-Flight 4.4 Check ob boto3-env-vars schon vorhanden,  | Verifikation |
|             | Backup-Tool-Eingrenzung (boto3 vs rclone),               |        |
|             | Alertmanager-Notification-Verifikations-Workflow         |        |
| 2026-05-15  | v6: KORREKTUR fruehere Annahme "Unknown=normal" fuer     | DEV ksops-Vorfall |
|             | *-secrets Apps. Neue Section 3.11 (ksops silent install- |        |
|             | failure), Pre-Flight 4.3 mit ksops-Existenz-Check,       |        |
|             | Quick-Fix + Permanent-Fix (Patch-v2 mit set -e + curl).  |        |
|             | Learning 17 + Phase D.6 Erwartung korrigiert.            |        |
