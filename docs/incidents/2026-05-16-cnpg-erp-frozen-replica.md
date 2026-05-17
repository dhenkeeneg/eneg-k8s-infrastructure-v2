# Incident: cnpg-erp Frozen Replica + WAL-Volume-Alerts (2026-05-16)

**Status:** abgeschlossen am 2026-05-16 ca. 10:30 MESZ
**Umgebung:** k8s-dev (k8s-dev-21/22/23)
**Dauer Recovery:** ca. 90 Minuten
**Betroffene Workloads:**
- cnpg-erp (3-Knoten PostgreSQL-Cluster) — eine Replica eingefroren auf alter Timeline, WAL-Stau auf Primary
- cnpg-shared — nicht betroffen

**Auslöser-Alerts:** `CnpgWalVolumeWarning` (Severity: warning) auf
- `cnpg-erp-3-wal` bei 70-75% (Primary)
- `cnpg-erp-4-wal` bei 70-75% (Replica)
- `cnpg-erp-6-wal` blieb bei ~15% (auffällig)

**Hinweis zur Ursachenkette:** Die heute eingetretenen Symptome haben ihre Wurzel im
Storage-Storm-Incident vom 10.-12.05.2026 (siehe `docs/incidents/2026-05-11-mariadb-galera-recovery.md`).
Während dieses Incidents wurde `cnpg-erp-6` neu provisioniert (als Ersatz für `cnpg-erp-5`).
Eine Timeline-17-History-Datei im Object Storage entstand bei einem späteren Promote-Cycle
und lag seit dem als latent vorhandene Stolperfalle im Bucket — bis sie heute durch eine
weitere Promote-Aktion zur akuten Blockade wurde.

## Ausgangslage (morgens am 16.05.2026)

Alertmanager feuerte mehrere `CnpgWalVolumeWarning`-Alerts gegen DEV. Cluster-Status laut
`kubectl get cluster cnpg-erp` war ironischerweise weiterhin `Cluster in healthy state`
mit 3/3 Instances "healthy" — CNPG bewertet die Replica-Health rein über die
Pod-Readiness-Probe und nicht über Replication-Lag.

**Beobachteter Cluster-Zustand zu Beginn:**

| Pod | WAL-Belegung | Rolle | Auffälligkeit |
| --- | --- | --- | --- |
| cnpg-erp-3 | 75% (3,6/4,9 GiB) | Primary | WAL-Stau |
| cnpg-erp-4 | 75% (3,6/4,9 GiB) | Replica (streaming) | WAL-Stau, mit-Stau durch Primary |
| cnpg-erp-6 | 15% (705 MiB/4,9 GiB) | Replica (nominell) | als einzige Replica streamt NICHT |
| cnpg-shared-* | 12-14% | OK | nicht betroffen |

**Erste Auffälligkeit:** `pg_stat_replication` auf dem Primary zeigte nur 1 aktive
Verbindung (cnpg-erp-4). `pg_stat_wal_receiver` auf cnpg-erp-6 war leer.

**Replication Slots auf Primary (cnpg-erp-3):**

```
    slot_name     | slot_type | active | restart_lsn | wal_status | safe_wal_size
------------------+-----------+--------+-------------+------------+---------------
 _cnpg_cnpg_erp_4 | physical  | t      | 46/31002B98 | reserved   |
 _cnpg_cnpg_erp_6 | physical  | f      | 45/4F0000A0 | extended   |
```

Aktuelle Primary-WAL-Position: `46/31002B98`. Der inaktive Slot für `cnpg-erp-6`
hielt die WALs ab Position `45/4F0000A0` fest — Differenz ca. 1,2 GiB, exakt der
Stau-Umfang auf den WAL-Volumes von erp-3 und erp-4.

## Root Cause

**cnpg-erp-6 Postgres-Logs zeigten dauerhaft im 5-Sekunden-Takt:**

```
LOG:   started streaming WAL from primary at 45/4F000000 on timeline 15
FATAL: could not receive data from WAL stream:
       ERROR:  requested WAL segment 0000000F000000450000004F has already been removed
[wal-restore] Refusing to restore future timeline history file
  walName=00000011.history fileTimeline=17 clusterTimeline=16
LOG:   waiting for WAL to become available at 45/4F0000B8
```

Drei verknüpfte Probleme:

1. **Streaming-Pfad blockiert:** Das benötigte WAL-Segment `0000000F000000450000004F` ist
   auf Timeline 15 (`0F` hex). Der Primary war zu diesem Zeitpunkt auf Timeline 16; das
   Segment war im Primary-WAL-Buffer nicht mehr vorhanden.

2. **Archive-Restore-Pfad blockiert:** Beim Versuch, die WAL aus dem Object Storage
   wiederherzustellen, fand das Plugin die History-Datei `00000011.history`
   (= Timeline 17 dezimal). Da der Cluster zu diesem Zeitpunkt offiziell auf Timeline 16
   lief, weigerte sich PostgreSQL, eine "zukünftige" Timeline-History anzunehmen.
   Folge: kein WAL-Restore möglich.

3. **Stale Replication Slot:** Da cnpg-erp-6 als Replica im Cluster registriert war,
   bestand der zugehörige Slot `_cnpg_cnpg_erp_6` weiter. Da der Slot inaktiv
   (`active=f`) seit Tagen auf `restart_lsn = 45/4F0000A0` festhing, durfte PostgreSQL
   alle WALs ab dieser Position nicht recyclen → WAL-Volume füllt sich kontinuierlich.

**Wo kommt die Timeline-17-History her?**

Die `00000011.history` wurde nicht heute erzeugt. Sie existiert im Object Storage seit
dem Storage-Storm-Incident vom 10.-12.05.2026, als der cnpg-erp-Cluster mehrere
Failover-/Promote-Versuche durchlief, bei denen mindestens ein Promote eine
Timeline-Bump bis TL17 in den Backup-Catalog schrieb, der Cluster aber operativ auf
TL16 stehen blieb. Diese verwaiste History lag seitdem als latente Stolperfalle im
Bucket. Solange cnpg-erp-6 normal weiterstreamte (was bis gestern der Fall war),
fiel sie nicht auf. Erst nach dem Cluster-Restart gestern (im Zuge der Reparatur)
versuchte cnpg-erp-6 zu re-streamen und stieß auf den Timeline-Mismatch.

## Begleitbefund (Problem B): Backup-Subsystem hängt seit Stunden

Parallel zum Hauptproblem zeigten **alle** Backup-CRs (cnpg-erp UND cnpg-shared)
seit gestern Nachmittag den Status `failed` mit `exit status 4`. Die
Plugin-Sidecar-Logs auf erp-4 und erp-3 zeigten dabei:

- `barman-cloud-backup` selbst lief **erfolgreich** durch (ca. 15 s).
- Das nachgelagerte `barman-cloud-backup-show` lief jedoch in einen 5-Minuten-
  Read-Timeout gegen `http://nas10.eneg.de:8010` bei der LIST-Operation auf
  Präfix `cnpg-erp/cnpg-erp/base/`.
- Ebenso `barman-cloud-backup-delete` (Retention) — Read-Timeout auf gleicher LIST.
- WAL-Archiving funktionierte parallel weiterhin ohne Probleme (PUT-Operationen sind
  von der Latenz nicht betroffen).

Das ist das bereits aus dem Memory bekannte QNAP-QuObjects-Listing-Performance-
Problem, das diesmal in akute Backup-Failures eskalierte. Daniel bestätigte, dass
zum Zeitpunkt der Untersuchung große parallele Backup-Jobs auf der NAS liefen, die
die Listing-Performance der QuObjects-S3-API temporär stark degradieren.

Konsequenzen:
- Backup-CRs zeigen `failed`, obwohl die Backup-Daten tatsächlich im S3 liegen
  (nur die Validierung scheitert).
- Retention räumt nicht auf → Bucket wächst → LIST wird über Zeit noch langsamer
  (Teufelskreis).

**Wichtig:** Dieses Backup-Problem ist NICHT die Ursache des Frozen-Replica-Problems.
Die beiden Probleme sind unabhängig. Backup-Recovery wird als Phase 2 separat
behandelt (siehe Abschnitt "Offene Folgepunkte" unten).

## Recovery-Strategie

Nach Diskussion der Optionen (Frozen-Replica neu provisionieren vs. WAL-Volume
vergrößern vs. TL17-History löschen vs. Slot manuell droppen) wurde Option A
gewählt: **cnpg-erp-6 sauber neu provisionieren über PVC-Recreation**, sodass
CNPG eine frische Replica via `pg_basebackup` vom Primary aufbaut. Vorteil
gegenüber dem Restore-Pfad: umgeht das Backup-Subsystem-Problem komplett
(reines Streaming-Bootstrap aus laufendem Primary).

## Recovery-Schritte (chronologisch)

### Schritt 1 — Stale Replication Slot droppen

```bash
kubectl --context k8s-dev -n databases exec cnpg-erp-3 -c postgres -- \
  psql -U postgres -c "SELECT pg_drop_replication_slot('_cnpg_cnpg_erp_6');"
```

Ergebnis: `pg_drop_replication_slot` (1 row). Dies hebt die WAL-Halterechte des
inaktiven Slots auf — beim nächsten Checkpoint werden die festgehaltenen WALs
freigegeben.

### Schritt 2 — Pod cnpg-erp-6 löschen

```bash
kubectl --context k8s-dev -n databases delete pod cnpg-erp-6 --grace-period=10
```

Hinweis: CNPG-Reconciler erstellt den Pod sofort wieder (er sieht weiterhin 3
gewünschte Instanzen) — das ist erwartet und wird in Schritt 3 durch das
Entfernen der PVCs aufgelöst.

### Schritt 3 — PVCs sofort danach löschen

```bash
kubectl --context k8s-dev -n databases delete pvc cnpg-erp-6 cnpg-erp-6-wal
```

Mit gelöschten PVCs hat der recreated Pod keinen Storage mehr → CNPG erkennt
"defekte Instance #6" und legt eine neue Instance an. Die Logik bumpt dabei
die instance-serial: **es entstand cnpg-erp-7** (analog zur Phase-C-Migration
im 10.-12.05.-Incident, wo aus erp-5 → erp-6 wurde).

### Schritt 4 — Beobachtung und unerwartetes Zwischenereignis (Failover)

Während CNPG den Reconcile durchführte (cnpg-erp-7 wurde provisioniert, alte
PVCs gingen in Terminating), wurde der bisherige Primary cnpg-erp-3 **mehrfach
durch Liveness-Probe-Failures restartet** (HTTP 500 auf `/healthz`). CNPG
reagierte mit einem **automatischen Failover auf cnpg-erp-4** (vorher Replica,
jetzt neuer Primary). In dessen Folge entstand eine **neue Timeline 17** —
diesmal als reguläre, valide Timeline, im Gegensatz zur verwaisten TL17-History
im Backup-Catalog.

Beobachtungs-Snapshot kurz danach (Pods):

| Pod | Status | Age | Rolle |
| --- | --- | --- | --- |
| cnpg-erp-3 | 1/2 Running (1 Restart) | 21h | Replica (recovers) |
| cnpg-erp-4 | 2/2 Running | 5h | **Primary (neu)** |
| cnpg-erp-6 | 2/2 Running ("Zombie") | 6 min | — |
| cnpg-erp-7 | 2/2 Running | 5 min | Replica (frisch) |
| cnpg-erp-7-join-65rm8 | 0/1 Completed | 5 min | Bootstrap-Job (pg_basebackup) |

cnpg-erp-3 holte sich anschließend via `restored log file "00000010.history"`
und `"000000110000004600000037"` die jetzt valide Timeline-Historie aus dem
Object Storage und kam als Replica auf TL17 zurück (`started streaming WAL
from primary at 46/38000000 on timeline 17`).

### Schritt 5 — cnpg-erp-6 als Zombie-Pod aufräumen

Der ursprüngliche cnpg-erp-6 Pod war noch da (2/2 Running), obwohl seine PVCs
in Terminating waren. Diagnose:

```bash
kubectl --context k8s-dev -n databases get pod cnpg-erp-6 \
  -o jsonpath='{"DeletionTimestamp: "}{.metadata.deletionTimestamp}
Finalizers: {.metadata.finalizers}'
# DeletionTimestamp: (leer)  → Pod wurde nie zum Löschen markiert
# Finalizers: (leer)         → kein Schutz
```

Cluster-Status zeigte einen Widerspruch:
- `instanceNames`: `["cnpg-erp-3","cnpg-erp-4","cnpg-erp-7"]` — CNPG kennt erp-6 nicht mehr
- `instancesStatus.healthy`: enthielt aber noch `cnpg-erp-6` — veralteter Statusrest
- `READY: 4` statt 3

Da CNPG erp-6 in `instanceNames` nicht mehr führte, konnte der Pod ohne
Risiko gelöscht werden:

```bash
kubectl --context k8s-dev -n databases delete pod cnpg-erp-6 --grace-period=10
```

Direkt danach:
- PVCs cnpg-erp-6 und cnpg-erp-6-wal vollständig terminiert (Finalizer löste sich
  durch den entfallenen Pod-Mount-Halter)
- Longhorn detached und löschte die zugehörigen Volumes
- Cluster-Status: `READY: 3`, `STATUS: Cluster in healthy state`

## Endzustand (Verifikation)

**Cluster cnpg-erp:**
```
NAME       AGE   INSTANCES   READY   STATUS                     PRIMARY
cnpg-erp   80d   3           3       Cluster in healthy state   cnpg-erp-4
```

**Pods:**

| Pod | Status | Rolle | WAL-Belegung |
| --- | --- | --- | --- |
| cnpg-erp-3 | 2/2 Running | Replica (TL17) | 15% (721 MiB / 4,9 GiB) |
| cnpg-erp-4 | 2/2 Running | **Primary** | 15% (705 MiB / 4,9 GiB) |
| cnpg-erp-7 | 2/2 Running | Replica (TL17, frisch) | 2% (65 MiB / 4,9 GiB) |

**Replication Slots auf Primary cnpg-erp-4:**
```
    slot_name     | active | restart_lsn | wal_status | lag_size
------------------+--------+-------------+------------+----------
 _cnpg_cnpg_erp_3 | t      | 46/3A001118 | reserved   | 0 bytes
 _cnpg_cnpg_erp_7 | t      | 46/3A001118 | reserved   | 0 bytes
```

Beide Replicas streamen aktiv, kein Lag.

**Cluster-Conditions:**
- ConsistentSystemID: True
- Ready: True
- ContinuousArchiving: True
- LastBackupSucceeded: False ← **Problem B noch offen**

**Alertmanager:**
- Vor Recovery: 4 aktive Alerts (`CnpgWalVolumeWarning` x4 + `Watchdog`)
- Nach Recovery: 1 aktiver Alert (`Watchdog` only — Heartbeat, erwünscht)

Recovery-Dauer Ende-zu-Ende: ca. 90 Minuten inkl. Diagnose-Phase.

## Lessons Learned

### LL-1 — CNPG "healthy" sagt nichts über Replication-Lag

CNPG meldet im Cluster-Status `READY: 3/3` und `Cluster in healthy state`, solange
die Pod-Readiness-Probes grün sind. Eine eingefrorene Replica, die seit Stunden
keine WAL mehr empfängt, fällt in diesem Status **nicht** auf. Die einzigen
Frühwarnsignale waren:
- `CnpgWalVolumeWarning` (Symptom, nicht Ursache)
- `pg_stat_replication` zeigt weniger Verbindungen als erwartete Replicas
- `pg_replication_slots` mit `active=false` + zurückbleibendem `restart_lsn`

**Konsequenz:** Wir sollten eine zusätzliche PrometheusRule überlegen für
Replication-Lag auf Slot-Basis (siehe "Offene Folgepunkte" unten).

### LL-2 — TL-History-Dateien im Object Storage haben langes Gedächtnis

Eine verwaiste History-Datei aus einem abgebrochenen Promote-Cycle bleibt im
Object Store stehen, bis sie aktiv aufgeräumt wird. Ein neu provisionierter
Pod, der versucht via Archive-Restore aufzuholen, kann an einer "zukünftigen"
Timeline-History (höhere TL als der Cluster zur Zeit kennt) hängen bleiben —
WAL-Restore wird mit `Refusing to restore future timeline history file`
abgelehnt. Solange Streaming-Replication funktioniert, fällt das nicht auf.

**Konsequenz:** Nach jedem disruptiven Cluster-Recovery (Failover/Promote/Restart)
sollte im Anschluss ein gezielter Blick in den Object Store auf
`*.history`-Dateien geworfen werden, um latente Stolperfallen zu erkennen.

### LL-3 — `pvc-delete + pod-recreate`-Race erzeugt Zombie-Pods

Die ursprüngliche Reihenfolge "erst Pod löschen, dann PVCs löschen" ist
korrekt, hat aber einen Mikro-Race: CNPG-Reconciler kann den Pod neu anlegen,
bevor die PVC-Delete-Requests durchgelaufen sind. Resultat: alte PVCs in
Terminating + alter Pod (frisch recreated) hält die Volumes weiter.

**Saubererer Workaround:** Pod-Delete im Hintergrund starten und PVC-Delete
sofort nachschieben, ODER `kubectl cnpg destroy <cluster> <instance>` aus dem
CNPG-CLI-Plugin verwenden, falls verfügbar (macht beides atomar).

**Was im konkreten Fall geholfen hat:** Nach Provisionierung von cnpg-erp-7
entfernte CNPG den Zombie cnpg-erp-6 aus `instanceNames` (Status zeigte den
Widerspruch zwischen `instanceNames` und `instancesStatus.healthy`). Ab diesem
Punkt war ein erneutes `kubectl delete pod cnpg-erp-6` sicher und führte
direkt zum vollständigen Cleanup.

### LL-4 — Backup-CRs "failed" sind nicht zwingend Datenverlust

Plugin-Backup-CRs zeigen `failed` mit `exit status 4`, wenn ein nachgelagerter
`barman-cloud-backup-show` in einen Read-Timeout läuft. Die eigentlichen
Backup-Daten (`barman-cloud-backup`) sind dann bereits erfolgreich nach S3
geschrieben — nur die Validierung scheitert. Bevor man bei "alle Backups failed"
in Panik verfällt, lohnt der Blick in die Plugin-Logs: dort findet sich der
Eintrag `Completed barman-cloud-backup` mit Timestamp.

### LL-5 — TL-Mismatch zwischen Archive und Cluster ist diagnoseschwer

Der Hinweis `Refusing to restore future timeline history file` mit
`fileTimeline=17, clusterTimeline=16` ist relativ versteckt — er erscheint im
`wal-restore`-Logger, nicht im normalen Postgres-Logger. Bei einem hängenden
Replica-Bootstrap ist das die wichtigste Spur. Die `pg_stat_wal_receiver`
gibt ergänzend Auskunft, ob überhaupt Streaming versucht wird (leer = nein).

## Offene Folgepunkte

### A) Backup-Subsystem reparieren (Problem B) — ✅ behoben am 17.05.2026

Siehe Folge-Incident `docs/incidents/2026-05-17-cnpg-backup-subsystem-repair.md`.
Kernursache war kein temporäres NAS-Last-Problem, sondern strukturell:
ein **Cron-Format-Bug** in den ScheduledBackup-Schedules (5-Feld statt CNPG's
erwartetes 6-Feld) hatte seit Mitte April täglich 24 Backup-Runs statt 1
ausgelöst — entsprechend war der Bucket so überfüllt, dass QuObjects' LIST-API
ins Rate-Limit lief. Reparatur: Schedule-Korrektur per GitOps in allen 3 Environments
+ kompletter Bucket-Reset für DEV. TEST/PROD-Buckets noch zu prüfen sobald die
Cluster wieder up sind (siehe Folge-Doc).

### B) Object Storage Cleanup: TL17-History prüfen — ✅ erledigt am 17.05.2026

Durch den kompletten Bucket-Reset von `cnpg-erp/cnpg-erp/` im Zuge der
Backup-Subsystem-Reparatur am 17.05. wurde die verwaiste `00000011.history`
mitentfernt. Neue WAL-Archivierung läuft seither auf Timeline 18 (`00000012.history`),
nachdem inzwischen ein weiterer Auto-Failback Promote stattgefunden hat
(Primary wieder cnpg-erp-3). Siehe `docs/incidents/2026-05-17-cnpg-backup-subsystem-repair.md`.

### C) PrometheusRule für Replication-Lag erwägen

Aktuell warnt das System nur, wenn das WAL-Volume voll wird. Eine zusätzliche
Regel auf Basis von `cnpg_pg_replication_slots_safe_wal_size` oder
`pg_replication_slots_active == 0` (für CNPG-internen Slot-Namen) würde Frozen-
Replicas früher erkennen, bevor der WAL-Stau eskaliert.

### D) Runbook erstellen

Ein generisches Runbook für dieses Szenario wurde erstellt:
`docs/runbooks/cnpg-frozen-replica-stale-slot.md`.

## Verweise

- Vorausgehender Incident: `docs/incidents/2026-05-11-mariadb-galera-recovery.md`
- Generisches Runbook (heute neu): `docs/runbooks/cnpg-frozen-replica-stale-slot.md`
- CNPG Barman-Plugin Migrations-Guide: `docs/guides/cnpg-barman-cloud-plugin-migration-v2.md`
- Memory-Notiz QNAP-Listing-Performance: bereits aus früheren Sessions bekannt;
  heute erstmals als Backup-Show-Timeout in Erscheinung getreten.
