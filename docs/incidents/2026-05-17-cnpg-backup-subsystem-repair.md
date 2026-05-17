# Incident-Folge: CNPG Backup-Subsystem-Reparatur (2026-05-17)

**Status:** abgeschlossen am 2026-05-17 ca. 12:25 MESZ
**Umgebung:** k8s-dev (k8s-dev-21/22/23)
**Dauer:** ca. 2 Stunden inkl. Diagnose
**Betroffene Workloads:** cnpg-erp + cnpg-shared (Backup-Subsystem; PostgreSQL-Services selbst durchgehend verfügbar)

**Vorgeschichte:** Dies ist die Aufarbeitung von "Problem B" aus dem Incident-Bericht
`docs/incidents/2026-05-16-cnpg-erp-frozen-replica.md`. Beim Frozen-Replica-Recovery
am 16.05. war als Begleitbefund aufgefallen, dass alle Backup-CRs beider DB-Cluster
seit Stunden in den Phase-Status `failed` mit `exit status 4` liefen — als temporäres
Symptom paralleler NAS-Backupjobs. Bei der detaillierten Analyse am 17.05. stellte
sich heraus, dass das Problem nicht temporär war, sondern strukturelle Ursachen hatte.

## Bestandsaufnahme zu Beginn

**Backup-CRs in K8s:**

| Cluster | completed | failed | started | total | ältester | jüngster |
| --- | --- | --- | --- | --- | --- | --- |
| cnpg-erp    | 52 | 88  | 1 | 141 | 2026-04-13 | 2026-05-17 09:04 |
| cnpg-shared | 48 | 117 | 1 | 166 | 2026-04-18 | 2026-05-17 09:04 |
| **gesamt** | **100** | **205** | **2** | **307** | | |

Soll-Zustand bei korrektem täglichem Schedule und 7d Retention: max. 14 CRs total.
Tatsächlich: **22x zu viel**.

**Cluster-Conditions:**
- `ContinuousArchiving = True` (WAL-Push funktionierte einwandfrei)
- `LastBackupSucceeded = False` seit ca. 24h
- Letzte erfolgreiche Backup-CRs: 2026-05-15 21:04

**ScheduledBackups (Live im Cluster):**
- `cnpg-erp-full`: schedule `50 4 * * *` (5-Feld-Cron)
- `cnpg-shared-full`: schedule `45 4 * * *` (5-Feld-Cron)

## Root Cause 1: Cron-Format-Bug (5-Feld vs. 6-Feld)

**Auffälligkeit bei der Auswertung der Backup-CRs:**

Die Namen der Backup-CRs hatten Stunden-Zeitstempel auf jedem vollen Stundenslot
(`...05161604`, `...05161704`, `...05161804`, ...), nicht den erwarteten täglichen
Rhythmus. Dabei sah der konfigurierte Schedule auf den ersten Blick korrekt aus:

```yaml
spec:
  schedule: "50 4 * * *"  # gemeint: täglich 04:50
```

**Ursache:** CNPG `ScheduledBackup` verwendet **6-Feld-Cron**
(`Sekunde Minute Stunde Tag Monat Wochentag`), nicht das übliche 5-Feld-Format
von Kubernetes-CronJobs (`Minute Stunde Tag Monat Wochentag`).

Die fünf vorhandenen Felder werden dann als die ersten fünf eines 6-Feld-Strings
interpretiert:

| Feld | Wert | gemeint als | tatsächlich interpretiert als |
| --- | --- | --- | --- |
| 1 | `50` | Minute | **Sekunde** |
| 2 | `4`  | Stunde | Minute |
| 3 | `*`  | Tag    | Stunde |
| 4 | `*`  | Monat  | Tag |
| 5 | `*`  | Wochentag | Monat |
| 6 | (fehlt → default `*`) | — | Wochentag |

Resultat: Schedule feuert **jede Stunde zu Minute 04, Sekunde 50** statt einmal
täglich um 04:50. Pro Tag entstanden so 24 Backup-Versuche statt 1 — das
24-fache der eingeplanten Last auf der NAS-Object-Storage.

**Gefundener Scope (alle drei Environments betroffen):**

| Env | Cluster | falsch | korrigiert | Sollzeit |
| --- | --- | --- | --- | --- |
| DEV  | cnpg-shared | `45 4 * * *`  | `0 45 4 * * *`  | 04:45 UTC |
| DEV  | cnpg-erp    | `50 4 * * *`  | `0 50 4 * * *`  | 04:50 UTC |
| TEST | cnpg-shared | `30 2 * * *`  | `0 30 2 * * *`  | 02:30 UTC |
| TEST | cnpg-erp    | `35 2 * * *`  | `0 35 2 * * *`  | 02:35 UTC |
| PROD | cnpg-shared | `15 0 * * *`  | `0 15 0 * * *`  | 00:15 UTC |
| PROD | cnpg-erp    | `20 0 * * *`  | `0 20 0 * * *`  | 00:20 UTC |
| base-Vorlage | cnpg-shared | `0 2 * * *`   | `0 0 2 * * *`   | (Vorlage) |
| base-Vorlage | cnpg-erp    | `15 2 * * *`  | `0 15 2 * * *`  | (Vorlage) |

Korrektur per GitOps-Commit, ArgoCD-Refresh in DEV verifiziert (live im Cluster
sichtbar). TEST und PROD waren zum Zeitpunkt der Aktion ausgeschaltet — ArgoCD
zieht den korrigierten Schedule beim nächsten Cluster-Start automatisch aus Git.

## Root Cause 2: Bucket-Overflow → QuObjects-LIST-Performance-Kollaps

Durch das stündliche Backup-Triggering seit Mitte April war im S3-Bucket
`k8s-dev-postgres-wal` eine sehr große Objektmenge akkumuliert:
- Hunderte `base/<backup-id>/` Verzeichnisse je Cluster
- Entsprechend hohe WAL-File-Mengen unter `wals/`

QuObjects (QNAP's S3-Layer) ist bei LIST-Operationen offenbar nicht delimiter-nativ
paginiert, sondern enumeriert intern alle Keys unter dem Präfix. Dadurch
skaliert die LIST-Performance linear mit der **Gesamt-Objektanzahl** unter dem
Präfix, nicht mit der Anzahl direkter Children.

**Messungen vor Cleanup:**

| Operation | Dauer | Ergebnis |
| --- | --- | --- |
| `ls s3://bucket/` (Top-Level) | 67 s | 2 DIRs + 3 Reste |
| `ls s3://bucket/cnpg-erp/cnpg-erp/` | 1.7 s | 2 DIRs (base/, wals/) |
| `ls s3://bucket/cnpg-erp/cnpg-erp/base/` | >5 min, dann 503-Rate-Limit | — |
| `ls s3://bucket/cnpg-erp/cnpg-erp/base/<single-id>/` | 2.1 s | 2 Files |
| `du s3://bucket/` (rekursiv) | sofort 503 | — |

Konsequenz für CNPG-Backup-Plugin:
- `barman-cloud-backup` selbst (PUT-basiert): lief erfolgreich durch (ca. 15 s)
- `barman-cloud-backup-show` (LIST-basiert auf `base/`): lief in 5-Minuten-Read-Timeout
- `barman-cloud-backup-delete` (LIST + DELETE): ebenfalls Timeout → Retention räumte nicht auf
- Folge: CRs in K8s zeigten `failed`, obwohl Backup-Daten im S3 lagen → Teufelskreis,
  da Retention nicht griff und Bucket weiter wuchs.

3 zusätzliche Test-Reste an der Bucket-Wurzel (vom Storage-Storm-Recovery 10.-12.05.):
- `test-recovery-0836.txt` (28 Bytes)
- `test-wal-16mb-0839.bin` (16 MB)
- `test-wal-postreboot-0907.bin` (16 MB)

## Reparatur-Schritte

### Schritt 1 — Cron-Schedule-Fix (GitOps)

Alle 4 Schedule-Dateien wurden um die fehlende führende `0 ` (für Sekunde) ergänzt:

- `kubernetes/base/cloudnative-pg/cluster/scheduled-backup.yaml`
- `kubernetes/environments/dev/cnpg-cluster/scheduled-backup.yaml`
- `kubernetes/environments/test/cnpg-cluster/scheduled-backup.yaml`
- `kubernetes/environments/prod/cnpg-cluster/scheduled-backup.yaml`

Zusätzlich Hinweis-Kommentar zur 6-Feld-Cron-Semantik in den Dateien eingefügt,
damit zukünftige Änderungen den Bug nicht wiederholen:

```yaml
# Hinweis: CNPG verwendet 6-Feld-Cron (Sekunde Minute Stunde Tag Monat Wochentag).
# 5-Feld-Cron wird als 6-Feld interpretiert und triggert dann jede Stunde.
```

Commit + Push, ArgoCD-Auto-Sync mit manuellem Refresh-Trigger in DEV.

### Schritt 2 — K8s Backup-CRs Cleanup (zeitbasiert)

ScheduledBackups zuerst suspended, damit während des Cleanups kein neuer Backup
gegen den vollen Bucket startet:

```bash
for sb in cnpg-erp-full cnpg-shared-full; do
  kubectl --context k8s-dev -n databases patch \
    scheduledbackup.postgresql.cnpg.io $sb \
    --type=merge -p '{"spec":{"suspend":true}}'
done
```

Anschließend zeitbasiertes Aufräumen aller Backup-CRs (alle `failed` egal welches
Alter; alle `completed` älter als 7 Tage):

```bash
# Mit python-Filter generiert, dann xargs in 30er-Batches
xargs -n 30 kubectl --context k8s-dev -n databases \
  delete backups.postgresql.cnpg.io < /tmp/cnpg-backups-to-delete.txt
```

Ergebnis: 208 CRs gelöscht, 99 CRs übrig (51 cnpg-erp + 48 cnpg-shared, alle
completed, alle < 7d alt).

### Schritt 3 — Diagnose der S3-LIST-Performance

Nach einem ersten Neustart der QuObjects-Engine auf der NAS waren Single-Path-
LIST-Operationen schnell (~2 s), das LIST auf `base/` lief aber weiterhin
nach kurzer Zeit in `503 (ServiceUnavailable): Please reduce your request rate`.

**Diagnose-Schluss:** Das Problem ist strukturell. Ohne Datenreduktion im Bucket
sind LIST-Operationen auf großen Sub-Pfaden nicht praktikabel. Aufgrund der
zwischen Inventur und Cleanup zirkulären Abhängigkeit (kein LIST → kein
Wissen welche Backups da sind → keine gezielte Löschung) wurde entschieden:

> **Kompletter Reset des Bucket-Inhalts** statt selektiver Cleanup.

Akzeptable Konsequenzen:
- PITR-Capability auf DEV temporär weg → fachlich akzeptabel (DEV)
- Eine neue Backup-Baseline wird sofort erzeugt → PITR ab dann wieder vorhanden
- Continuous Archiving bricht nicht ab — WAL-Push wird lokal gequeued, sobald
  S3-Pfade wieder existieren wird gepusht.

### Schritt 4 — Voll-Cleanup im QNAP Filesystem

Bewusst nicht via S3-API (würde wieder gegen LIST-Limit laufen), sondern direkt
über die QNAP-Web-UI im File-System gelöscht:

- `<bucket-root>/k8s-dev-postgres-wal/cnpg-erp/` — komplette Hierarchie
- `<bucket-root>/k8s-dev-postgres-wal/cnpg-shared/` — komplette Hierarchie
- Plus die 3 Test-Reste an der Bucket-Wurzel

Direktes Filesystem-rm umgeht das S3-API-Rate-Limit komplett. Anschließend
zur Konsistenzsicherheit QuObjects-Service neu gestartet.

### Schritt 5 — ScheduledBackups un-suspenden + Test-Backup

```bash
for sb in cnpg-erp-full cnpg-shared-full; do
  kubectl --context k8s-dev -n databases patch \
    scheduledbackup.postgresql.cnpg.io $sb \
    --type=json -p '[{"op":"remove","path":"/spec/suspend"}]'
done
```

Manuelle Test-Backup-CRs für beide Cluster:
- `cnpg-erp-cleanup-test-001`
- `cnpg-shared-cleanup-test-001`

(jeweils `method: plugin`, `pluginConfiguration: barman-cloud.cloudnative-pg.io`)

## Endzustand (Verifikation)

**Backup-Phase nach Cleanup:**

| Backup-CR | Phase | Dauer (Backup) | Phase-Wechsel total | Backup-ID | Timeline |
| --- | --- | --- | --- | --- | --- |
| cnpg-erp-cleanup-test-001 | completed | 2 s | 51 s | 20260517T101751 | 18 |
| cnpg-shared-cleanup-test-001 | completed | 2 s | 51 s | 20260517T101751 | 17 |

Zum Vergleich: Vor Cleanup hingen Backup-CRs typischerweise > 5 min, landeten dann
in Phase `failed` mit `exit status 4`.

**Cluster-Conditions cnpg-erp + cnpg-shared (beide identisch grün):**
- ConsistentSystemID: True
- Ready: True
- ContinuousArchiving: True
- **LastBackupSucceeded: True** (vorher False seit ~24 h)

**S3-Bucket-Inhalt nach Cleanup:**

```
s3://k8s-dev-postgres-wal/
├── cnpg-erp/cnpg-erp/
│   ├── base/20260517T101751/  (backup.info + data.tar, ca. 93 MB)
│   └── wals/0000001200000047/ (laufende WAL-Archivierung TL18)
└── cnpg-shared/cnpg-shared/
    ├── base/20260517T101751/  (backup.info + data.tar, ca. 95 MB)
    └── wals/0000001100000040/ (laufende WAL-Archivierung TL17)
```

**Performance-Verbesserung:**

| Operation | Vor Cleanup | Direkt nach Cleanup | Nach 1. Test-Backup |
| --- | --- | --- | --- |
| Top-Level `ls`            | 67 s | 1.4 s | 21 s |
| `cnpg-erp/cnpg-erp/` `ls` | 1.7 s | 0.7 s | <1 s |
| `base/` `ls`              | >5 min (Timeout) | 0.7 s | <1 s |
| Backup-CR Phase-Wechsel   | >5 min → failed | — | **51 s → completed** |
| `du` (recursive)          | 503 | gut | 503 |

Erkenntnis zur QuObjects-Performance-Charakteristik:
- LIST skaliert mit **Gesamt-Objektanzahl im Bucket**, nicht mit direkten Children
- Recursive Operationen (`du`) triggern auch bei kleinem Bucket sofort 503
- Delimiter-LIST (was Barman macht) skaliert günstig solange Objektzahl moderat bleibt

Aktuelle Größe des Buckets: rund 200 Objekte (2 base/ + ca. 2 h Wals).
Erwartete Größe nach 7 Tagen Produktivbetrieb: 14 base/ + 7 Tage WALs ≈ überschaubar.

## Lessons Learned

### LL-1 — CNPG verwendet 6-Feld-Cron, nicht 5-Feld

Im Gegensatz zu den meisten Kubernetes-CronJob-Schedulern (5-Feld:
`MM HH DD MM WD`) verwendet CNPG `ScheduledBackup` ein 6-Feld-Format mit
führender Sekunde (`SS MM HH DD MM WD`). Ein 5-Feld-Cron wird klaglos akzeptiert,
aber die Werte rutschen um eine Spalte und das Schedule triggert dann zu völlig
anderen Zeitpunkten (typisch: jede Stunde statt einmal täglich).

**Konsequenz:** Bei der Erstellung neuer `ScheduledBackup`-Ressourcen
immer 6 Felder verwenden, üblicherweise `0 MM HH * * *` für täglich.
Hinweis-Kommentar in den scheduled-backup.yaml-Dateien hinterlegt.

### LL-2 — QuObjects skaliert LIST über Total-Object-Count

QNAP-QuObjects-LIST-Operationen sind **nicht** delimiter-nativ paginiert
(Sicht von außen). Bei großen Sub-Pfaden enumeriert QuObjects intern alle Keys
und gibt erst dann gruppiert das Common-Prefix-Set zurück. Daraus folgt:

- Top-Level- und Tiefe-1-LIST sind so schnell oder langsam wie der **gesamte** Pfad
- 503-Rate-Limit greift bei viel Inhalt — auch wenn die zurückgegebenen Daten klein sind
- Single-Path-Operationen (HEAD / GET / kleines LIST mit exaktem Pfad) sind immer schnell

**Konsequenz für Barman-Cloud-Plugin-Betrieb auf QuObjects:**
- `barman-cloud-backup` (PUT-basiert): unkritisch
- `barman-cloud-backup-show` (LIST `base/`): kritisch ab ~Hunderten Objekten
- `barman-cloud-backup-delete` (LIST + DELETE): ebenfalls kritisch

Mit korrektem täglichem Schedule und 7d Retention bleibt das Objektaufkommen
moderat (max ~14 base/ + ~7 Tage WALs). Das ist QuObjects-kompatibel.

### LL-3 — Bucket-Reset über Filesystem statt S3-API

Sobald ein Bucket so überfüllt ist, dass LIST-Operationen über die S3-API ins
Rate-Limit laufen, ist ein klassischer "rm --recursive" über s3cmd nicht mehr
durchführbar (Henne-Ei: LIST wird intern dafür benötigt). In dem Fall lohnt
der Weg über das **QNAP-Filesystem direkt** (Web-UI oder SSH auf die NAS):
ein File-System-rm umgeht den S3-API-Layer komplett.

Wichtig zur Konsistenz: Anschließend den QuObjects-Service neu starten, damit
der interne Object-Index neu eingelesen wird und nicht auf jetzt nicht mehr
existente Files verweist.

### LL-4 — Backup-CR-Phase "failed" sagt nichts über Datenexistenz aus

Wenn der Backup-Plugin in `barman-cloud-backup-show` (nach erfolgreichem
`barman-cloud-backup`) in Read-Timeouts läuft, wird die CR als `failed` markiert
— die Backup-Daten selbst sind aber bereits erfolgreich im S3. Bei
"alle Backups failed"-Befunden lohnt der Blick in die Plugin-Sidecar-Logs:
`Completed barman-cloud-backup` mit Timestamp ist das verlässliche Signal,
nicht die CR-Phase.

### LL-5 — Defense in Depth: Schedule-Linter im PR-Workflow erwägen

Ein einfacher YAML-Lint-Check für `ScheduledBackup`-Ressourcen könnte
5-Feld-Cron erkennen und den PR blockieren. Konkret: Regex auf
`schedule: "\S+ \S+ \S+ \S+ \S+"$` (genau 5 Felder) → Fail.
Für später erfassen.

## Offene Folgepunkte

### A) Retention-Wirkung am 24.05. überwachen

Ab dem 24.05. (7 Tage nach erstem neuen Backup) sollte CNPG die Retention-Policy
das erste Mal anwenden. Erwartung: `barman-cloud-backup-delete` läuft sauber durch,
weil das LIST nur ~14 base/-Einträge enumerieren muss. Falls trotzdem Probleme
auftreten — separat behandeln.

### B) TEST + PROD Bucket-Status prüfen sobald Cluster wieder up sind

TEST und PROD waren während dieser Reparatur ausgeschaltet. Die Schedule-Korrektur
liegt im Git und wird beim Cluster-Start automatisch via GitOps gezogen.
**Aber:** Die Buckets `k8s-test-postgres-wal` und `k8s-prod-postgres-wal` haben
seit Mitte April genau das gleiche stündliche Backup-Triggering erlebt. Voraussichtlich
ist die Objektmenge dort kleiner als in DEV (PROD-Cluster war wohl regulär in Betrieb,
keine Recovery-bedingten Backups dazwischen), aber dennoch deutlich über Soll.

Nach Cluster-Start:
1. ScheduledBackup-Schedule live im Cluster prüfen (sollte 6-Feld-Format sein)
2. Anzahl Backup-CRs prüfen (Indikator)
3. Aktuellen Backup-Run beobachten — läuft er sauber durch?
4. Falls nicht: Analog zu DEV — Cleanup-CRs + Bucket-Reset

### C) PrometheusRule für Replication-Lag (aus 16.05.-Doc übernommen) — ✅ erledigt am 17.05.2026

Neuer Alert `CnpgReplicationSlotInactive` in `kubernetes/base/monitoring/alert-rules/cnpg-alerts.yaml`
ergänzt. Trigger: Slot inaktiv auf Primary (Filter via `cnpg_pg_replication_in_recovery == 0`,
um lokale Slot-Spiegelungen auf Standby-Pods auszublenden), `for: 10m`,
severity: warning. Annotation verlinkt direkt auf das Runbook
`docs/runbooks/cnpg-frozen-replica-stale-slot.md`. Damit wird das Frozen-Replica-
Pattern ~10 Min nach Eintreten erkannt, lange bevor `CnpgWalVolumeWarning` bei
70% greift.

### D) Schedule-Linter im PR-Workflow (siehe LL-5)

Konzept-Skizze: pre-commit-hook oder GitHub Action mit Regex-Check
`schedule: "\S+ \S+ \S+ \S+ \S+"$` für ScheduledBackup-Manifeste.

### E) Strategische Option: NAS10 → Garage S3 für CNPG-Backups

Längerfristig: Migration von QuObjects auf Garage S3 für die WAL/Backup-Volumina,
zumindest in DEV+TEST. Argumente:
- QuObjects-LIST-Skalierung ist die strukturelle Schwäche
- Garage ist nativ S3-kompatibler und Skalierungs-getestet
- NAS10 könnte als Cold-Copy via rclone weiter dienen (Dual-Backup-Strategie)

Eigene Session, nach Phase 11 (Rolling OS-Update) priorisieren.

## Verweise

- Vorausgehender Incident: `docs/incidents/2026-05-16-cnpg-erp-frozen-replica.md`
  ("Problem B" dort wird durch diesen Eintrag geschlossen)
- Storage-Storm-Incident: `docs/incidents/2026-05-11-mariadb-galera-recovery.md`
- Geänderte Git-Pfade (Commit auf main heute):
  - `kubernetes/base/cloudnative-pg/cluster/scheduled-backup.yaml`
  - `kubernetes/environments/dev/cnpg-cluster/scheduled-backup.yaml`
  - `kubernetes/environments/test/cnpg-cluster/scheduled-backup.yaml`
  - `kubernetes/environments/prod/cnpg-cluster/scheduled-backup.yaml`

## Beobachteter Nebenbefund (außerhalb des Backup-Subsystems)

Während der Cleanup-Aktion zeigte sich bei der Cluster-Bestandsaufnahme, dass
in DEV cnpg-erp inzwischen wieder ein Failover stattgefunden hatte:
- Nach 16.05. Recovery: Primary war `cnpg-erp-4`, Timeline 17
- Am 17.05. nachmittags: Primary ist `cnpg-erp-3`, Timeline 18
- Replicas: `cnpg-erp-4` und `cnpg-erp-7`, beide caught up

Vermutlich automatischer Failback (cnpg-erp-3 ist die nominell präferierte Primary-
Instance). Cluster meldet healthy 3/3, beide Replication-Slots active mit
`lag_size = 0 bytes`. Kein Handlungsbedarf, aber zur Vollständigkeit dokumentiert,
weil eine zusätzliche `00000012.history`-Datei dadurch im Object Storage entstand.
