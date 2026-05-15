# Runbook: CNPG + MariaDB Recovery nach Storage-Storm

**Letzte Aktualisierung:** 2026-05-15
**Erstmals verifiziert:** DEV-Cluster (k8s-dev), 2026-05-14/15
**Status TEST/PROD:** ausstehend
**Verwandte Docs:**
- `docs/incidents/2026-05-11-mariadb-galera-recovery.md` (Ursprung)
- `docs/runbooks/longhorn-volume-expansion-deadlock.md`

---

## 1. Zweck dieses Runbooks

Wiederherstellung der Stateful-Komponenten (CNPG-Cluster + MariaDB Galera)
nach einem Storage-Storm oder vergleichbaren mehrtaegigen Ausfall. Dabei
besonders adressiert:

- **NAS10/QuObjects-Inkompatibilitaet** mit boto3 ≥ 1.36 (InvalidDigest-Bug)
- **CNPG-Cluster** in stuck-State "Waiting for instances to become active"
- **MariaDB-Operator** auf replicas=0 ohne ArgoCD-Recovery
- **Pod-Sidecar-Cache** von alten Pods ohne neue ObjectStore-env-vars
- **Divergierende WAL-Historie** nach mehreren Primary-Wechseln

Das Runbook geht davon aus, dass DEV bereits erfolgreich recoverd ist und
TEST/PROD analog behandelt werden sollen.

---

## 2. Root Causes (verifiziert auf DEV)

### 2.1 NAS10 boto3 InvalidDigest

**Fehler:**
```
ERROR: Barman cloud WAL archiver exception:
An error occurred (InvalidDigest) when calling the PutObject operation:
The Content-MD5 or checksum value that you specified is not valid.
```

**Ursache:** Seit boto3 ≥ 1.36 (Januar 2025) sendet das AWS SDK
standardmaessig CRC32 Trailing-Checksums bei jedem PutObject
(`request_checksum_calculation=when_supported`). QNAP QuObjects (NAS10)
validiert diese Header inkorrekt und lehnt mit InvalidDigest ab.

**Fix:**

```yaml
# In jedem ObjectStore-CR (cnpg-erp-objectstore, cnpg-shared-objectstore):
spec:
  configuration: { ... }
  retentionPolicy: "7d"
  instanceSidecarConfiguration:
    env:
      - name: AWS_REQUEST_CHECKSUM_CALCULATION
        value: when_required
      - name: AWS_RESPONSE_CHECKSUM_VALIDATION
        value: when_required
```

**Quelle:** https://aws.amazon.com/blogs/developer/new-default-checksum-behavior-in-aws-sdks/

### 2.2 Plugin-Sidecar-Cache

env-Variablen aus `instanceSidecarConfiguration` werden NUR beim
**Pod-Recreate** in den Sidecar injiziert, NICHT bei einem
in-place Container-Restart (kubelet). Konsequenz: Bestehende Postgres-Pods
muessen explizit force-deleted werden, damit der Operator den
plugin-barman-cloud Sidecar mit aktuellen env-vars neu erstellt.

Reihenfolge:
1. ObjectStore-CR patchen
2. Plugin-Operator-Pod (`cnpg-system/cnpg-barman-plugin-*`) restarten
3. **Standby** Postgres-Pod als ersten loeschen (kein Service-Impact, env-vars verifizieren)
4. Switchover -> Standby wird Primary, archiviert mit env-vars
5. Alter Primary nun als Standby ebenfalls force-deleten

### 2.3 cnpg.io/hibernation blockiert Operator

Wenn die `cnpg.io/hibernation: on` Annotation auf dem Cluster-CR steht,
ignoriert der Operator Switchover-Patches. Hibernation MUSS aus Git
entfernt werden bevor man Switchover/Reaktivierung versucht.

ArgoCD selfHeal patcht die Annotation aus Git zurueck wenn man sie
imperativ entfernt -> daher Git-Commit erforderlich.

### 2.4 MariaDB-Operator-Default 0 unsichtbar fuer ArgoCD

Wenn die Helm-Values fuer mariadb-operator KEINEN `replicas`-Eintrag
haben (Default 1), erkennt ArgoCD bei ServerSideApply einen imperativen
`kubectl scale --replicas=0` nicht als Drift. Operator bleibt auf 0/0.

**Fix:** `replicas: 1` explizit in `base/mariadb-galera/operator/values.yaml`.

### 2.5 pg_rewind-Failure auf alten Primaries

Wenn eine Postgres-Replica frueher selbst Primary war (vor dem Storm),
divergiert ihre WAL-Historie vom neuen Primary nach dem Switchover.
`pg_rewind` exit 1, Pod bleibt 1/2 Ready.

**Fix:** Pod + PVC (Data + WAL) komplett loeschen, Operator macht
`pg_basebackup` fuer neue Replica (mit naechstem freien Index, z.B.
`cnpg-shared-4` -> `cnpg-shared-5`).

---

## 3. Voraussetzungen pruefen (vor Recovery-Start)

```bash
# 3.1 Welcher Kontext?
kubectl config get-contexts | grep '*'   # k8s-dev / k8s-test / k8s-prod

# 3.2 Alle Nodes Ready?
kubectl get nodes

# 3.3 Longhorn gesund? (alle Volumes detached oder healthy, keine "Error")
kubectl get volume.longhorn.io -n longhorn-system | grep -cE "attached|detached"
kubectl get volume.longhorn.io -n longhorn-system | grep -cE "error|faulted"
# Sollte ergeben: viele attached/detached, 0 error/faulted

# 3.4 NAS10 erreichbar + S3-funktional?
S3_KEY=$(kubectl get secret cnpg-s3-credentials -n databases -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
S3_SECRET=$(kubectl get secret cnpg-s3-credentials -n databases -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)
time s3cmd --host=nas10.eneg.de:8010 --host-bucket="" --no-ssl \
  --access_key=$S3_KEY --secret_key=$S3_SECRET \
  ls s3://k8s-<env>-postgres-wal/
# 16 MB Write-Test:
dd if=/dev/urandom of=/tmp/test.bin bs=1M count=16
time s3cmd ... put /tmp/test.bin s3://k8s-<env>-postgres-wal/test-precheck-$(date +%H%M).bin
# Real Time < 5s erforderlich. Bei 30s+: NAS10 neu starten!
```

⚠️ **Wenn NAS10 sehr langsam (> 30s fuer 16MB Write):** Vor Recovery
NAS10 neu starten. Storage-Storm-Symptom war u.a. 46s Settle-Time.

---

## 4. Recovery-Sequenz

Reihenfolge ist wichtig — niemals Phasen parallel oder vorziehen.

### Phase 0: Bestandsaufnahme

```bash
ENV=test   # oder prod

# Cluster-Status
kubectl get cluster -n databases
kubectl get pods -n databases -l 'cnpg.io/cluster' -o wide
kubectl get mariadb -n databases
kubectl get pods -n mariadb-operator
kubectl get pods -n databases -l app.kubernetes.io/instance=mariadb-galera

# Was steht in Git?
grep -A 1 hibernation kubernetes/environments/$ENV/cnpg-cluster/*.yaml
grep replicas kubernetes/environments/$ENV/mariadb-cluster/mariadb-galera.yaml
grep instanceSidecarConfiguration kubernetes/environments/$ENV/cnpg-cluster/objectstore-*.yaml
```

### Phase 1: NAS10 boto3-Fix in beide ObjectStore-CRs

**Files:**
- `kubernetes/environments/<env>/cnpg-cluster/objectstore-erp.yaml`
- `kubernetes/environments/<env>/cnpg-cluster/objectstore-shared.yaml`

Beide Files: nach `retentionPolicy: "7d"` ergaenzen (siehe Abschnitt 2.1).

**Commit:**
```
fix(<env>/cnpg): NAS10 boto3 InvalidDigest Workaround in ObjectStore CRs
```

**Verifikation:**
```bash
kubectl get objectstore cnpg-erp-objectstore -n databases \
  -o jsonpath='env={.spec.instanceSidecarConfiguration.env}{"\n"}'
```

### Phase 2: Plugin-Operator-Pod restarten

```bash
kubectl delete pod -n cnpg-system -l app.kubernetes.io/name=plugin-barman-cloud
# 30s warten bis neuer Pod up
kubectl get pods -n cnpg-system
```

### Phase 3: Pro Cluster — Switchover-Verfahren

Sequenz fuer **cnpg-erp** UND **cnpg-shared** identisch:

```bash
CLUSTER=cnpg-erp        # oder cnpg-shared
OLD_PRIMARY=cnpg-erp-X  # aktueller Primary (kubectl get cluster $CLUSTER -o jsonpath='{.status.currentPrimary}')
STANDBY=cnpg-erp-Y      # einer der Standbys

# 3a) Standby loeschen -> Operator macht neuen Pod MIT env-vars
kubectl delete pod $STANDBY -n databases --force --grace-period=0

# 60s warten
sleep 60
kubectl get pod $STANDBY -n databases -o json | grep -c AWS_REQUEST_CHECKSUM
# Soll 2 sein

# 3b) Switchover triggern (sub-resource patch)
kubectl patch cluster $CLUSTER -n databases \
  --type=merge --subresource=status \
  -p "{\"status\":{\"targetPrimary\":\"$STANDBY\"}}"

# 60s warten - $STANDBY wird neuer Primary
sleep 60
kubectl get cluster $CLUSTER -n databases \
  -o jsonpath='current={.status.currentPrimary} target={.status.targetPrimary}{"\n"}'

# 3c) WAL-Archive Logs vom neuen Primary - sollte "Archived WAL file" zeigen
kubectl logs $STANDBY -n databases -c plugin-barman-cloud --since=30s \
  | grep -E "Executing|Archived|InvalidDigest"
```

⚠️ Falls Switchover nicht durchgeht (target stays = old primary): siehe
Phase 4 — Hibernation muss aus Git raus.

### Phase 4: Hibernation aus den Cluster-CRs entfernen

**Files:**
- `kubernetes/environments/<env>/cnpg-cluster/cnpg-erp.yaml`
- `kubernetes/environments/<env>/cnpg-cluster/cnpg-shared.yaml`

Den kompletten `annotations:`-Block mit `cnpg.io/hibernation: "on"` entfernen
(oder durch sinnvollen Reaktivierungs-Kommentar ersetzen).

**Commit:**
```
feat(<env>/cnpg): Reaktivierung - Hibernation aus beiden Clustern entfernt
```

### Phase 5: Force-Delete der alten Standbys (env-vars nachziehen)

Nach Switchover sind 2 von 3 Pods pro Cluster noch alte Replicas ohne
env-vars. Diese werden in-place restarted vom Kubelet aber nicht
neuerstellt. Daher manuell loeschen — sequentiell mit ~75s Pause:

```bash
# cnpg-erp: alle Pods die NICHT der neue Primary sind
kubectl delete pod cnpg-erp-X -n databases --force --grace-period=0
sleep 75
kubectl get pods -n databases -l cnpg.io/cluster=cnpg-erp
# Wiederholen fuer cnpg-erp-Y

# Gleiches fuer cnpg-shared
```

### Phase 6: pg_rewind-Failure Behandlung

Wenn ein Pod nach Force-Delete trotzdem in 1/2 hangs und Logs zeigen:
```
"Failed to execute pg_rewind"  exit status 1
```

Dann komplett-Reset:

```bash
POD=cnpg-shared-4    # der hängende Pod

# Pod + beide PVCs loeschen
kubectl delete pod $POD -n databases --force --grace-period=0
kubectl delete pvc $POD ${POD}-wal -n databases --wait=false
# Falls Finalizer-stuck:
kubectl patch pvc $POD -n databases --type=merge -p '{"metadata":{"finalizers":null}}'

# Operator erstellt neuen Pod mit naechstem freien Index (z.B. -5)
# + pg_basebackup vom Primary
sleep 60
kubectl get pods -n databases -l cnpg.io/cluster=cnpg-shared
```

### Phase 7: MariaDB-Operator reaktivieren

**File:** `kubernetes/base/mariadb-galera/operator/values.yaml`

Vor `metrics:` ergaenzen:

```yaml
# Operator als Singleton (Default des Charts, explizit gesetzt damit
# ArgoCD selfHeal den State sauber erkennen kann)
replicas: 1
```

**Commit:**
```
fix(mariadb-operator): replicas=1 explizit setzen
```

⚠️ Wenn ArgoCD die App im "frozen" State hat (revision leer, kein
selbsttaetiger Sync): **imperativ scalen** als Workaround:

```bash
kubectl scale deployment mariadb-operator -n mariadb-operator --replicas=1
# Spaeter ArgoCD-App reparieren (siehe Abschnitt 5.3)
```

### Phase 8: MariaDB-Galera CR reaktivieren

**File:** `kubernetes/environments/<env>/mariadb-cluster/mariadb-galera.yaml`

```yaml
spec:
  image: mariadb:11.8.6
  # Reaktiviert YYYY-MM-DD: nach Cluster-Recovery wieder voller 3-Node-Betrieb.
  replicas: 3
```

Das `replicasAllowEvenNumber: true` Flag entfernen (war nur fuer
replicas=0 Validierungs-Bypass).

**Commit:**
```
feat(<env>/mariadb): Galera replicas 0 -> 3 (Reaktivierung Phase B)
```

Operator startet automatisch Galera-Recovery aus den existierenden PVCs.
Bootstrap auf `mariadb-galera-0` (Primary), SST-Sync der anderen.
Dauer ca. 3-5 Min.

---

## 5. Edge Cases & Troubleshooting

### 5.1 NAS10 sehr langsam (Settle-Time 30s+)

Symptom: 16 MB s3cmd Write Real Time > 30s. Reboot NAS10 vor Recovery-Start.
Verifiziert auf DEV 2026-05-15: nach Reboot Real Time 0.5s statt 46s.

### 5.2 Beide CNPG-Primaries enden auf gleichem Node

Nach Recovery hatten cnpg-erp-4 und cnpg-shared-3 BEIDE den Primary auf
node 23 (Anti-Affinity fuer Workload, nicht zwischen Cluster-Primaries).
Akzeptabel, aber bei Bedarf einen Switchover machen.

### 5.3 ArgoCD App "frozen" (revision leer, last sync uralt)

Erkannt bei mariadb-operator + mariadb-cluster nach Storage-Storm.
Sync-Status `Synced/Healthy` aber nicht aktuell.

Workaround (DEV):
```bash
# Imperative Aktion (kein Git) - State im Cluster bringen
kubectl scale ...
# Spaeter Application-Controller restarten:
kubectl rollout restart deployment argocd-application-controller -n argocd
# Oder App neu erstellen
```

### 5.4 pg_rewind divergierende WAL-Historie

Siehe Phase 6.

### 5.5 Galera-Recovery: safe-to-bootstrap=false auf allen Pods

Operator findet Galera state `00000000-0000-0000-0000-000000000000` (none
of pods had clean shutdown). `recovery.enabled: true` + `clusterBootstrapTimeout`
sollte das abhandeln — Operator waehlt Primary mit hoechster sequence
oder bootstrappt podIndex 0 (laut `primary.podIndex` in CR).

Wenn nach > 15 Min noch nicht recovered: pod-events anschauen, ggf.
Operator-Pod manuell restarten.

---

## 6. Verifikation (Post-Recovery Checks)

```bash
ENV=test   # oder prod

# CNPG: beide Cluster healthy
kubectl get cluster -n databases
# Erwartung: STATUS=Cluster in healthy state, READY=3 fuer beide

# Pending WALs: 0
for cluster in cnpg-erp cnpg-shared; do
  PRIMARY=$(kubectl get cluster $cluster -n databases -o jsonpath='{.status.currentPrimary}')
  echo "$cluster (Primary: $PRIMARY):"
  kubectl exec $PRIMARY -n databases -c postgres -- bash -c \
    "ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status/*.ready 2>/dev/null | wc -l"
done

# MariaDB: 3/3 Ready
kubectl get mariadb mariadb-galera -n databases
# Erwartung: READY=True, STATUS=Running

# Alle DB-Pods 2/2 Ready, 0 Restarts
kubectl get pods -n databases

# Anti-Affinity verifizieren: jede Replica auf anderem Node
kubectl get pods -n databases -o wide

# WAL-Archive aktiv?
PRIMARY=$(kubectl get cluster cnpg-erp -n databases -o jsonpath='{.status.currentPrimary}')
kubectl logs $PRIMARY -n databases -c plugin-barman-cloud --tail=20 \
  | grep -E "Archived WAL file" | tail -5
# Erwartung: regelmäßige "Archived WAL file" Eintrage mit elapsedWalTime < 1s
```

---

## 7. Rollback (Falls Recovery scheitert)

Im Notfall waehrend der Recovery:

```bash
# 1. ArgoCD Apps auf manual setzen (kein selfHeal-Storm)
kubectl patch app cnpg-cluster -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl patch app mariadb-cluster -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2. Hibernation re-enable (CNPG)
kubectl annotate cluster cnpg-erp -n databases cnpg.io/hibernation=on --overwrite
kubectl annotate cluster cnpg-shared -n databases cnpg.io/hibernation=on --overwrite

# 3. MariaDB-Galera replicas=0 (Operator wird Pods runterfahren)
kubectl patch mariadb mariadb-galera -n databases --type=merge \
  -p '{"spec":{"replicas":0,"replicasAllowEvenNumber":true}}'

# 4. Operator scale=0
kubectl scale deployment mariadb-operator -n mariadb-operator --replicas=0
```

Danach Logs analysieren, dann neuen Versuch.

---

## 8. Persistente Learnings fuer Memory / Memory-System

**Neue Learnings aus DEV-Recovery 15.05.2026:**

1. **NAS10/QuObjects boto3 ≥ 1.36 InvalidDigest-Bug** (persistent reminder)
   Workaround: `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` in
   `instanceSidecarConfiguration.env` von ObjectStore-CRs.

2. **CNPG plugin-barman-cloud Architektur:** Plugin-Operator-Pod im
   `cnpg-system` NS + Sidecar-Container im Postgres-Pod. env-vars in
   ObjectStore-CR propagieren erst nach Restart von beiden.

3. **CNPG Switchover ohne kubectl-cnpg-plugin:**
   `kubectl patch cluster X --type=merge --subresource=status
   -p '{"status":{"targetPrimary":"new"}}'`

4. **CNPG pg_rewind Fallback:** Wenn pg_rewind exit 1, dann komplett-Reset
   (Pod + Daten-PVC + WAL-PVC loeschen) -> Operator macht pg_basebackup
   mit naechster freier Index-Nummer.

5. **ArgoCD selfHeal:** Bei imperativ entfernten Annotations sofort wieder
   aus Git gesetzt. Fuer Tests entweder auto-sync temporaer aus oder
   direkt Git-Patch.

6. **Helm-Chart-Default-Replicas vs imperatives Scale:** ArgoCD erkennt
   den Drift nicht zwangslaeufig wenn Helm-Default nicht im Manifest
   gerendert ist (ServerSideApply mode). Imperatives Scale-Up bleibt
   bestehen. Explizit `replicas: N` in values.yaml setzen.

---

## 9. TEST/PROD-Vorbereitung (Checkliste)

Vor Start einer TEST/PROD-Recovery-Session:

- [ ] Aktueller State dokumentiert (Pods, Cluster-CRs, ArgoCD-Apps)
- [ ] NAS10 erreichbar + Performance-Check (s3cmd 16 MB Write < 5s)
- [ ] Backup-Snapshot von Longhorn-Volumes existiert (Sicherheit)
- [ ] Alle Apps in der entsprechenden ENV sind auf 0 oder suspended
- [ ] Wartungsfenster mit Stakeholdern abgestimmt (besonders fuer PROD)
- [ ] Working-Rules eingehalten (siehe Projektplanung):
  - Daniel commitet/pushed
  - Claude bereitet Files vor
  - Sequentiell ENV-fuer-ENV
  - Optionen vor Implementierung

---

## 10. Aenderungshistorie

| Datum       | Aenderung                                                | Quelle |
|-------------|----------------------------------------------------------|--------|
| 2026-05-15  | Initial nach DEV-Recovery erstellt                       | k8s-dev verifiziert |
