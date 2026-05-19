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

Nach Rollout:
- Velero-Pod wurde neu erstellt mit neuer Backup-Storage-Location-Config
- `kubectl describe backupstoragelocation default -n velero` zeigt
  `checksumAlgorithm: ""` in spec.config
- Test-Backup `test-checksum-fix-001` erfolgt mit Phase `Completed`
- Naechster Daily-Run am 20.05.2026 05:45 ist `Completed`
- 10 alte Failed/PartiallyFailed/FailedValidation-Backups sind geloescht

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

| Datum      | Aenderung                                              |
|------------|--------------------------------------------------------|
| 19.05.2026 | Initiale Anlage, DEV-Fix per `checksumAlgorithm: ""`  |
