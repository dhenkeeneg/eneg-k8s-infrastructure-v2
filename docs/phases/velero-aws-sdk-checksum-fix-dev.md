# Velero Backup-Fix: AWS-SDK-go-v2 Checksum-Inkompatibilitaet mit QNAP QuObjects (DEV)

**Datum:** 19.05.2026
**Umgebung:** DEV (k8s-dev-21/22/23)
**Status:** In Umsetzung
**Komponenten:** Velero v1.17.1, velero-plugin-for-aws v1.13.0, Helm-Chart velero-11.3.2

---

## 1. Problem

Seit dem 14.05.2026 schlaegt der taegliche Velero-Backup-Schedule
`velero/velero-daily-backup` systematisch fehl. Items werden vollstaendig
erfasst (z.B. 4752/4752), aber der finale Upload der `velero-backup.json`
nach NAS10 QuObjects scheitert mit:

```
api error InvalidDigest: The Content-MD5 or checksum value that you
specified is not valid.
```

### Backup-Phase-Verlauf (Daily Schedule)

| Datum     | Phase            | Bemerkung                |
|-----------|------------------|--------------------------|
| 06.05.    | Completed        |                          |
| 07.05.    | PartiallyFailed  | 4 errors                 |
| 08.05.    | Completed        |                          |
| 09.05.    | PartiallyFailed  | 37 errors                |
| 10./11.05.| FailedValidation | NAS10 nicht erreichbar   |
| 12.05.    | PartiallyFailed  | 18 errors                |
| 13.05.    | Completed        | **letzter Erfolg**       |
| 14.-19.05.| Failed (5x)      | InvalidDigest            |

---

## 2. Root Cause

`aws-sdk-go-v2` (seit ~v1.30, Dez 2024) hat seinen Default fuer
Request-Checksums auf `WHEN_SUPPORTED` umgestellt. Der SDK sendet
seitdem standardmaessig `x-amz-sdk-checksum-algorithm`-Header und
Trailer-Checksums (CRC32/CRC32C). NAS10 QuObjects (QNAP, aelteres
S3-Protokoll) interpretiert diese Header nicht korrekt und antwortet
mit `400 InvalidDigest`.

Identisches Symptom-Cluster (`itemsBackedUp == totalItems`, dann
PutObject-Fail auf `velero-backup.json`) ist im Velero-Tracker dokumentiert:

- velero-io/velero#8742 (Scality)
- velero-io/velero#8265 (S3-Compat Sammel-Issue, von Maintainern gefuehrt)

Betroffene Provider mit gleichem Symptom-Profil und identischer Loesung:
Scality, IBM COS, Oracle, Linode, Dell EMC OneFS — alle gefixt durch
`checksumAlgorithm: ""` in der BackupStorageLocation-Konfiguration.

---

## 3. Loesung

**Workaround per Velero-Backup-Storage-Location-Konfiguration:**

```yaml
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      config:
        checksumAlgorithm: ""    # <-- deaktiviert SDK-side Checksum-Header
```

Setzt der Velero-Plugin-for-aws Code in einen Modus, in dem er
`x-amz-sdk-checksum-algorithm` weglaesst. Trailing-Checksums werden
nicht mehr generiert, QuObjects akzeptiert das Upload.

**Warum NICHT Chart/Plugin-Upgrade?**
- Aktuellster Plugin v1.13.0 (Sep 2025) enthaelt diesen Fix nicht
- Latest Chart velero-12.0.1 (Apr 2026) Release Notes ohne Checksum-Bezug
- Workaround ist offiziell empfohlene Loesung im Velero-Tracker (#8265)

**Warum NICHT Env-Vars `AWS_*_CHECKSUM_*=WHEN_REQUIRED`?**
- Wirkt zwar auch, ist aber generischer (alle SDK-Aufrufe inkl. Restore/Sync)
- BSL-Konfig ist punktgenau und im Manifest selbsterklaerend
- Beim Lesen des YAML klar, warum der Eintrag existiert

---

## 4. Wichtig: Helm-Listen-Merge Verhalten

Helm merged YAML-**Listen** nicht element-weise — die Override-Liste
**ersetzt** die Base-Liste komplett. Das bedeutet:

- `base/velero/values.yaml` enthaelt `backupStorageLocation` mit Basis-Defaults
- `environments/dev/velero/values-override.yaml` enthaelt eine **vollstaendige**
  `backupStorageLocation` mit env-spezifischen Werten (bucket, s3Url, ...)
- Helm verwendet **nur die Override-Liste**

Daraus folgt:
- Eintrag in **base** wirkt nur, wenn das jeweilige Override
  `backupStorageLocation` nicht definiert (zu Dokumentationszwecken, als
  Default fuer kuenftige neue Umgebungen)
- Eintrag im **Environment-Override** ist der **wirksame** Fix

Beide Eintraege werden gesetzt: base zur Dokumentation, Override zur Wirkung.

---

## 5. Aenderungen

### kubernetes/base/velero/values.yaml

Hinzu zu `configuration.backupStorageLocation[0].config`:
```yaml
checksumAlgorithm: ""
```
Mit Kommentar zur Erlaeuterung. Wirkt nur als Default, da Environment-
Overrides die gesamte Liste ueberschreiben.

### kubernetes/environments/dev/velero/values-override.yaml

Hinzu zu `configuration.backupStorageLocation[0].config`:
```yaml
checksumAlgorithm: ""
```
Das ist die fuer DEV **wirksame** Aenderung.

---

## 6. Cleanup der gefehlten Backups

10 Backups werden geloescht (Failed + PartiallyFailed + FailedValidation):

| Backup                                  | Phase            |
|-----------------------------------------|------------------|
| velero-daily-backup-20260507054510      | PartiallyFailed  |
| velero-daily-backup-20260509054541      | PartiallyFailed  |
| velero-daily-backup-20260510054543      | FailedValidation |
| velero-daily-backup-20260511054544      | FailedValidation |
| velero-daily-backup-20260512054513      | PartiallyFailed  |
| velero-daily-backup-20260514140003      | Failed           |
| velero-daily-backup-20260516054505      | Failed           |
| velero-daily-backup-20260517054506      | Failed           |
| velero-daily-backup-20260518054507      | Failed           |
| velero-daily-backup-20260519054508      | Failed           |

Velero loescht Failed-Backups standardmaessig **nicht** automatisch.
Nach TTL (336h = 14d) werden sie zwar als expired markiert, aber die
Manifeste im S3-Bucket bleiben liegen.

`velero backup delete <name> --confirm` erstellt eine DeleteBackupRequest,
die sowohl das Backup-CR im Cluster als auch die zugehoerigen S3-Objekte
abraeumt.

---

## 7. Verifikation

### 7.1 Rollout-Sequenz

| Schritt | Aktion | Ergebnis |
|---------|--------|----------|
| 1 | `git push` der Aenderungen (Base + DEV-Override + Phase-Doku) | OK |
| 2 | ArgoCD Auto-Reconcile | `Synced + Healthy`, neue Revision `e2e7bd9...` registriert |
| 3 | BSL-Pruefung im Cluster | **Initial fehlte `checksumAlgorithm: ""`** trotz Synced-Status |
| 4 | `argocd.argoproj.io/refresh=hard` Annotation-Patch | BSL hat `spec.config.checksumAlgorithm: ""`, `phase: Available` |
| 5 | `kubectl rollout restart deployment/velero` | Neuer Pod `velero-57b475fccc-5k6xj` Running, 0 Restarts |

### 7.2 Subtilitaet: ArgoCD-Diff bei Helm-Sub-Map-Aenderungen

Beim ersten Reconcile erkannte ArgoCD die Aenderung an `backupStorageLocation[0].config`
**nicht** als Diff — Status war `Synced` aber die `checksumAlgorithm`-Property fehlte im
Cluster. Erst ein **Hard-Refresh** via `argocd.argoproj.io/refresh=hard` Annotation hat
den Helm-Template neu gerendert und den BSL-Diff materialisiert.

Dieses Verhalten kann bei Helm-Charts mit `range`-Iteration ueber Map-Werte (wie im
Velero-Chart-Template `backupstoragelocation.yaml`) auftreten. **Standardvorgehen
in solchen Faellen:** nach `git push` zusaetzlich Hard-Refresh-Annotation triggern,
nicht nur auf Auto-Sync warten.

### 7.3 Test-Backup 1 (Schnelltest — Resource-Only)

| Parameter | Wert |
|-----------|------|
| Name | `test-checksum-fix-001` |
| Includes | Namespace `velero` only |
| `defaultVolumesToFsBackup` | `false` |
| Start | 2026-05-19T10:50:35Z |
| Ende | 2026-05-19T10:50:42Z |
| Dauer | **7 Sekunden** |
| Items | **1350 / 1350** |
| Phase | `Completed` |
| Errors | none |

**Kritischer Pruefpunkt:** `velero-backup.json`-Upload nach NAS10 (das war die Stelle,
an der alle Daily-Backups seit 14.05. failed sind). Velero-Server-Logs zeigen
`Setting up backup store to persist the backup` → `Initial backup processing
complete, moving to Finalizing` ohne `InvalidDigest`-Fehler. **Fix verifiziert
fuer Resource-/Metadata-Pfad.**

### 7.4 Test-Backup 2 (Vollbackup mit fs-backup)

| Parameter | Wert |
|-----------|------|
| Name | `test-checksum-fix-002-full` |
| Includes | `*` (alle Namespaces) |
| `defaultVolumesToFsBackup` | `true` |
| Start | 2026-05-19T10:57:36Z |
| PVBs gesamt | **65** |
| PVBs `Completed` | **65** (Stand 11:51:00Z) |
| PVBs `Failed` | **0** |
| Daten nach NAS10 hochgeladen | ~5–6 GB (groesste PVB: 771 MB, 704 MB, 671 MB, 620 MB, 603 MB, 587 MB) |

Bei den historischen Failed-Backups vor dem Fix gab es **100 Warnings** und PutObject-
Errors entlang des Kopia-Pfads. **Hier: 0 Errors, 0 Warnings auf PVB-Ebene** — der
Fix wirkt auch fuer fs-backup-Datenuploads (jede der 65 PVBs hat erfolgreich nach
NAS10 geschrieben).

Hinweis: `itemsBackedUp` im Backup-CR-Status steigt bei aktivem fs-backup sehr
langsam, weil Velero auf PVB-Completion pro Pod wartet, bevor Cluster-Resources
weitergetraversiert werden. Das ist kein Hinweis auf einen Fehler — der eigentliche
S3-Pfad (PVB-Datenuploads + ueber Server-Side `velero-backup.json`) ist nachweislich
sauber.

### 7.5 Daily-Schedule

Der Schedule `velero-daily-backup` (05:45 Europe/Berlin) bleibt unveraendert aktiv.
Der naechste regulaere Lauf zeigt die Wirkung live.

### 7.6 Naechste Verifikations-Pruefpunkte

- [ ] Naechster Daily-Run (20.05.2026 05:45 CEST): Phase muss `Completed` sein
- [ ] PVBs des Daily-Runs: alle `Completed`, 0 `Failed`
- [ ] BSL bleibt `Available` (`status.phase`)
- [ ] Keine `InvalidDigest`-Errors mehr in Velero-Server-Logs


---

## 8. TEST/PROD-Rollout-Plan

**Vorbedingungen:**
- TEST/PROD-Schedules sind aktuell **deaktiviert** (laut Briefing)
- Nach DEV-Stabilisierung (mind. 2 erfolgreiche Daily-Runs) Rollout starten

**Schritte pro Umgebung (separate Chat-Session):**
1. `kubernetes/environments/{test,prod}/velero/values-override.yaml`
   um `checksumAlgorithm: ""` ergaenzen
2. Commit + Push → ArgoCD Sync
3. Velero-Pod-Restart pruefen
4. Test-Backup `test-checksum-fix-{test,prod}-001` triggern
5. Daily-Schedule reaktivieren (falls noch deaktiviert)
6. Verifikation des naechsten Daily-Runs
7. Cleanup ggf. vorhandener Failed-Backups

---

## 9. Aenderungshistorie

| Datum      | Aenderung                                                                                                      |
|------------|----------------------------------------------------------------------------------------------------------------|
| 19.05.2026 | Initiale Anlage, DEV-Fix per `checksumAlgorithm: ""`                                                           |
| 19.05.2026 | Verifikation: Test-Backup 1 (Resource-only) Completed in 7s, Test-Backup 2 (full + fs-backup) 65/65 PVBs Completed, 0 Failed. ArgoCD-Hard-Refresh-Subtilitaet dokumentiert (Section 7.2). Cleanup der 10 Failed-Backups via DeleteBackupRequest gestartet. |
