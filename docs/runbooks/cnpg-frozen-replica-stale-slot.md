# Runbook: CNPG Frozen Replica + Stale Replication Slot

**Kategorie:** Datenbank / CloudNativePG
**Erstellt:** 16.05.2026 (Erstmals aufgetreten in DEV am 16.05.2026 — Incident `2026-05-16-cnpg-erp-frozen-replica.md`)
**Stichworte:** WAL-Volume voll, Replica frozen, Timeline mismatch, stale replication slot, future timeline history

---

## Symptom

`CnpgWalVolumeWarning` (oder `Critical`) feuert für ein WAL-Volume eines
CNPG-Clusters — meist auf dem Primary, häufig auch auf einer aktiv streamenden
Replica. Cluster-Status laut `kubectl get cluster` ist trotzdem
`Cluster in healthy state` mit allen Instances als "healthy".

Typisches Muster:
- Eine Replica zeigt im Vergleich zu Primary/anderen-Replicas **deutlich
  niedrigere** WAL-Belegung (z. B. 15 % statt 75 %)
- Diese Replica streamt nicht, hängt aber im Cluster mit (Pod ist 2/2 Running)

## Diagnose

### 1. WAL-Belegung pro Pod ermitteln

```bash
for pod in $(kubectl --context k8s-<env> -n <ns> get pods \
    -l cnpg.io/cluster=<cluster-name> -o name); do
  pod=${pod#pod/}
  echo -n "$pod: "
  kubectl --context k8s-<env> -n <ns> exec "$pod" -c postgres -- \
    df -h /var/lib/postgresql/wal 2>/dev/null | tail -1 | awk '{print $5, "("$3"/"$2")"}'
done
```

Auffällig: ein Pod ist deutlich niedriger als die anderen → potenzielle frozen Replica.

### 2. Replication Slots auf dem Primary prüfen

```bash
PRIMARY=$(kubectl --context k8s-<env> -n <ns> get cluster <cluster-name> \
  -o jsonpath='{.status.currentPrimary}')
kubectl --context k8s-<env> -n <ns> exec "$PRIMARY" -c postgres -- \
  psql -U postgres -c "SELECT slot_name, active, restart_lsn, wal_status,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size
  FROM pg_replication_slots;"
```

**Frozen-Slot-Indikatoren:**
- `active = f` (kein Streaming aktiv)
- `wal_status = extended` oder `unreserved`
- `lag_size` deutlich > 0 (z. B. mehrere hundert MiB bis GiB)

### 3. Streaming-Status auf der verdächtigen Replica prüfen

```bash
kubectl --context k8s-<env> -n <ns> exec <replica-pod> -c postgres -- \
  psql -U postgres -c "SELECT pid, status, receive_start_lsn, written_lsn,
    flushed_lsn, slot_name FROM pg_stat_wal_receiver;"
```

- Leeres Ergebnis (`(0 rows)`) → Replica streamt nicht
- `status = streaming` → Streaming OK, anderes Problem
- `status = stopping` o.ä. → Verbindung wird gerade abgebaut

### 4. Recovery-Status der Replica

```bash
kubectl --context k8s-<env> -n <ns> exec <replica-pod> -c postgres -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(),
    pg_last_wal_replay_lsn();"
```

Falls `pg_last_wal_receive_lsn()` seit längerer Zeit unverändert ist → Replica hängt.

### 5. Postgres-Logs der hängenden Replica auswerten

```bash
kubectl --context k8s-<env> -n <ns> logs <replica-pod> -c postgres --tail=80 --since=10m \
  | grep -iE "error|fatal|stream|recover|wal-restore"
```

**Häufige Muster:**

- `requested WAL segment 0000000F000000450000004F has already been removed`
  → Replica versucht WALs zu streamen, die der Primary bereits recycled hat
  (Streaming-Pfad blockiert, Archive-Pfad ist die Alternative)

- `Refusing to restore future timeline history file walName=000000XX.history
  fileTimeline=Y clusterTimeline=Z` (Y > Z)
  → Im Object Storage liegt eine Timeline-History-Datei für eine **höhere**
  Timeline als der Cluster gerade verwendet. WAL-Restore wird abgelehnt, weil
  PostgreSQL keine zukünftige Timeline akzeptiert. Das ist meist ein Überbleibsel
  aus einem abgebrochenen Promote-Cycle (siehe Incident vom 16.05.2026).

- `waiting for WAL to become available at ...` (in Schleife alle wenige Sekunden)
  → Recovery-Loop, klassisches Zeichen eines frozen Bootstrap

## Reparatur

### Ansatz: Replica via PVC-Recreation neu provisionieren

Der saubere Weg ist, die Replica über das Löschen ihrer PVCs vollständig neu
aufzubauen. CNPG provisioniert dann eine frische Replica über `pg_basebackup`
direkt vom Primary — das umgeht sowohl das Streaming-Problem als auch evtl.
defekte Object-Storage-Pfade.

**Wichtig:** Vorher Datenbank-Größe prüfen — bei großen Clustern (>>100 GB)
dauert `pg_basebackup` entsprechend lange und Netzwerk-/Storage-Last steigt.

### Schritt 1 — Stale Replication Slot auf Primary droppen

Erst den stale Slot entfernen, damit die WALs auf dem Primary freigegeben werden.

```bash
PRIMARY=$(kubectl --context k8s-<env> -n <ns> get cluster <cluster-name> \
  -o jsonpath='{.status.currentPrimary}')

kubectl --context k8s-<env> -n <ns> exec "$PRIMARY" -c postgres -- \
  psql -U postgres -c "SELECT pg_drop_replication_slot('_cnpg_<replica-pod-name>');"
```

Beispiel: `pg_drop_replication_slot('_cnpg_cnpg_erp_6')` für Replica `cnpg-erp-6`.

Beim nächsten Checkpoint gibt PostgreSQL die zuvor festgehaltenen WALs frei →
WAL-Volume-Belegung auf Primary und gesunden Replicas sinkt.

### Schritt 2 — Frozen Replica Pod löschen

```bash
kubectl --context k8s-<env> -n <ns> delete pod <replica-pod-name> --grace-period=10
```

Hinweis: CNPG-Reconciler erstellt den Pod sofort neu, weil er weiterhin
`instances: N` als Sollzustand sieht. Das ist erwartet — Schritt 3 löst die
PVCs auf, die der recreated Pod dann nicht mehr hat.

### Schritt 3 — PVCs sofort danach löschen

```bash
kubectl --context k8s-<env> -n <ns> delete pvc \
  <replica-pod-name> <replica-pod-name>-wal
```

Mit gelöschten PVCs erkennt CNPG die Instance als defekt und bumpt die
instance-serial: aus `cnpg-erp-6` wird `cnpg-erp-7` (analog `cnpg-erp-5` →
`cnpg-erp-6` im 10.-12.05.-Incident).

### Schritt 4 — Beobachtung des Bootstrap

```bash
kubectl --context k8s-<env> -n <ns> get pods -l cnpg.io/cluster=<cluster-name> -w
```

Erwartete Sequenz:
1. Bootstrap-Job `<cluster-name>-<n>-join-XXXXX` läuft (pg_basebackup)
2. Neuer Replica-Pod `<cluster-name>-<n>` wird 2/2 Running
3. Auf dem Primary erscheint ein neuer aktiver Slot `_cnpg_<cluster-name>-<n>`

Dauer abhängig von DB-Größe und Netzwerk; bei kleinen DEV-Datenbanken meist
1-3 Minuten, bei größeren entsprechend länger.

### Schritt 5 — Möglichen Zombie-Pod aufräumen

Wenn nach dem Reconcile zwei Pods für die "kaputte" Instance existieren (alter
hängt mit Terminating-PVCs, neuer Pod hat höhere Serial-Nummer), entsteht ein
**Zombie-Pod**: 2/2 Running, aber CNPG kennt ihn in `instanceNames` nicht mehr.

Prüfen:
```bash
kubectl --context k8s-<env> -n <ns> get cluster <cluster-name> \
  -o jsonpath='instanceNames: {.status.instanceNames}{"\n"}healthy: {.status.instancesStatus.healthy}{"\n"}'
```

Wenn `instanceNames` den alten Pod nicht mehr enthält, aber `instancesStatus.healthy`
ihn noch listet → Zombie. Lösung:
```bash
kubectl --context k8s-<env> -n <ns> delete pod <alter-replica-pod> --grace-period=10
```

Direkt danach:
- Alte PVCs aus Terminating raus (Finalizer löst sich)
- Cluster-Status korrigiert sich auf gewünschte `READY: N`

### Schritt 6 — Endverifikation

```bash
# Cluster healthy
kubectl --context k8s-<env> -n <ns> get cluster <cluster-name>

# Beide Replicas streamen
kubectl --context k8s-<env> -n <ns> exec "$PRIMARY" -c postgres -- \
  psql -U postgres -c "SELECT application_name, state, replay_lag, sync_state
    FROM pg_stat_replication;"

# Slots aktiv mit lag_size = 0
kubectl --context k8s-<env> -n <ns> exec "$PRIMARY" -c postgres -- \
  psql -U postgres -c "SELECT slot_name, active, wal_status,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
  FROM pg_replication_slots;"

# WAL-Belegung sollte auf allen Pods auf normales Niveau gesunken sein
```

## Vorsicht / Bekannte Nebenwirkungen

### Mögliche Begleit-Failover

Während des Reconciles (Pod-Delete + PVC-Delete + Bootstrap) kann der bestehende
Primary unter Stress geraten (zusätzliche Last durch `pg_basebackup`). In
einzelnen Fällen kann das einen **automatischen Failover** auf eine andere Replica
auslösen. Das ist nicht zwangsläufig schlimm — der ehemalige Primary kommt nach
seinem Liveness-Restart als Replica zurück — aber es **bumpt die Timeline** und
kann zu einer neuen `XX.history`-Datei im Object Storage führen.

Bei kritischen Clustern: Vorher ausreichend Pufferzeit einplanen, Backup-Status
prüfen, und ggf. das `pg_basebackup`-Throttling über die Cluster-Spec begrenzen.

### Verwaiste Timeline-History im Object Storage

Falls die Replica beim Re-Bootstrap **erneut** mit "Refusing to restore future
timeline history file" abbricht (z. B. weil die TL18-History bereits im Bucket
liegt, der Cluster aber noch auf TL16/17 ist), muss die verwaiste History
manuell aus dem Object Storage entfernt werden:

```bash
# Bucket-Inhalt prüfen (von k8s-mgmt-10):
s3cmd --host=nas10.eneg.de:8010 --host-bucket="" --no-ssl \
  --access_key=$S3_KEY --secret_key=$S3_SECRET \
  ls s3://k8s-<env>-postgres-wal/<cluster>/<cluster>/wals/ | grep history

# Verwaiste History löschen (Vorsicht — sicherstellen, dass TL nicht aktiv ist):
s3cmd --host=nas10.eneg.de:8010 --host-bucket="" --no-ssl \
  --access_key=$S3_KEY --secret_key=$S3_SECRET \
  rm s3://k8s-<env>-postgres-wal/<cluster>/<cluster>/wals/0000XXXX/000000XX.history
```

**Wichtig:** Nie eine History-Datei löschen, die kleiner-gleich der aktuellen
Cluster-Timeline ist — sie wird beim Restart gelesen.

## Vermeidung / Frühwarnung

### PrometheusRule für Slot-Lag (geplant — offen)

Aktuell warnt das System primär bei vollem WAL-Volume. Eine zusätzliche Regel
auf Basis inactiver Slots oder großem `pg_wal_lsn_diff` würde das Problem früher
erkennen, bevor der Stau das Volume füllt. Vorschlag:

```yaml
- alert: CnpgInactiveReplicationSlot
  expr: |
    cnpg_pg_replication_slots_active{slot_type="physical"} == 0
    AND ON(namespace, slot_name)
    cnpg_pg_replication_slots_lag_size_bytes > 100 * 1024 * 1024
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "CNPG Replication Slot {{ $labels.slot_name }} inactive mit >100 MB Lag"
```

(Genauer Metrik-Name abhängig von der eingesetzten cnpg-exporter-Version.)

### Sanity-Check nach Cluster-Recovery

Nach jedem disruptiven Cluster-Recovery (Failover, Promote, Restart, Node-Reboot)
sollte folgender Schnellcheck durchgeführt werden:

1. Alle Replicas streamen (`pg_stat_wal_receiver` nicht leer)
2. Alle Slots auf Primary aktiv (`active = t`)
3. Keine verwaisten `.history`-Dateien für Timelines höher als
   `pg_current_xact_id()` / aktuelle Cluster-TL im Object Storage

## Verweise

- Erstes Auftreten (DEV): `docs/incidents/2026-05-16-cnpg-erp-frozen-replica.md`
- Verwandter Storage-Incident: `docs/incidents/2026-05-11-mariadb-galera-recovery.md`
- CNPG Plugin Migration Guide: `docs/guides/cnpg-barman-cloud-plugin-migration-v2.md`
