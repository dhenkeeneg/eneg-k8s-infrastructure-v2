# ADR-004: S3-Backend-Migration NAS10 -> NAS20 per Clean Cutover

**Status:** Akzeptiert
**Datum:** 11.06.2026
**Kontext-Phase:** Phase 14

## Kontext

Das gesamte S3-Backend (Backups, Logs, Metriken, OCI-Registry) liegt auf
NAS10 (QNAP QuObjects, nas10.eneg.de:8010). Es soll auf NAS20 (ebenfalls
QNAP QuObjects, Version 2.5.629) umziehen. NAS20 hat weniger Speicherplatz,
daher wird die Retention gesenkt (DEV/TEST 5 Tage, PROD 10 Tage).

Mehrere Dienste schreiben kontinuierlich nach S3 (CNPG/Barman WAL, Loki,
Thanos), was einen Datei-Sync waehrend des Betriebs riskant macht
(inkonsistente Zustaende, gebrochene WAL-Ketten).

## Entscheidung

**Clean Cutover statt Daten-Sync.** Die Dienste werden per GitOps auf den
NAS20-Endpoint umgestellt und starten dort mit leeren Buckets frisch. Kein
Sync der Bestandsdaten. Begruendung: Alt-PITR und lueckenlose Log-/Metrik-
Historie ueber den Umzug hinweg werden nicht benoetigt.

**Ausnahme Registry (Zot):** Der OCI-Registry-Bucket enthaelt Live-Daten
(keine Backups). Hier wird per rclone NAS10->NAS20 synchronisiert, da ein
frischer Start die Images verlieren wuerde.

**Retention direkt beim Cutover:** Die neuen Retention-Werte werden in einem
Arbeitsgang mit dem Endpoint-Wechsel gesetzt (kein separater Vorab-Durchlauf
auf NAS10).

**Workarounds bleiben erhalten:** Die bekannten QuObjects-Workarounds
(checksumAlgorithm, boto3-Checksum-Env, rclone --fast-list) werden 1:1
uebernommen. QuObjects 2.5.629 enthaelt laut Release Notes moeglicherweise
einen Fix fuer den Checksum-Bug; dies wird NACH der Migration isoliert in DEV
getestet (Phase 14e), nicht waehrend der Migration.

**Credentials Stufe 1:** Ein S3-User pro Umgebung. Bei der Migration werden
nur die Werte (Access/Secret Key, Endpoint) in den bestehenden Secret-Objekten
getauscht, die Secret-Struktur bleibt unveraendert. Eine echte Konsolidierung
auf ein gemeinsames Secret (Stufe 2) ist ein separates Folge-Refactoring.

## Konsequenzen

**Positiv:**
- Kein Race-Condition-Risiko bei kontinuierlich schreibenden Diensten
- Minimales Wartungsfenster (nur Endpoint-Switch + Pod-Restart)
- Migration und Workaround-Optimierung sind risikomaessig getrennt
- Sequenzielle Deployment-Regel bleibt gewahrt (DEV->TEST->PROD)

**Negativ / Risiken:**
- Backup-Historie auf NAS20 startet bei Null (waehrend Karenzzeit NAS10 als
  Fallback behalten)
- PITR-Fenster verkuerzt sich (5 bzw. 10 Tage)
- Loki-S3-Config muss aus base/ in env-Override gezogen werden (sonst wuerde
  eine base-Aenderung alle Umgebungen gleichzeitig treffen)

## Alternativen

- **Full rclone-Sync aller Daten:** verworfen wegen Inkonsistenz-Risiko bei
  WAL/Loki/Thanos und unnoetigem Aufwand (Historie nicht benoetigt).
- **Sofortige Workaround-Entfernung (QuObjects-Fix vertrauen):** verworfen -
  Stabilitaet vor Optimierung; Fix wird erst verifiziert.
- **Sofortige Secret-Konsolidierung (Stufe 2):** verworfen - vermischt
  Migrations- und Refactoring-Risiko.
