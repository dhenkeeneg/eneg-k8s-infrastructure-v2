# Wartung: NAS-Reboot-Verifikation + CNPG-Backup-Bereinigung PROD (2026-07-14)

**Status:** abgeschlossen am 2026-07-14 ca. 16:00 MESZ
**Umgebung:** k8s-dev, k8s-test, k8s-prod (K3s v1.35.1)
**Schweregrad:** niedrig - reine Verifikation + GitOps-Cleanup, kein Ausfall,
kein Datenverlust, keine Downtime, keine Pod-Neustarts

## Anlass

NAS10 und NAS20 wurden am 14.07. mittags aktualisiert (neue Zertifikate) und
rebootet. Ziel: verifizieren, dass WAL-Archivierung und Base-Backups aus allen
drei Clustern weiterhin funktionieren. Aus der Verifikation ergaben sich mehrere
Folge-Bereinigungen (Backup-Konfiguration, Drift-Angleichung).

## NAS-Zuordnung (bestaetigt)

- **DEV** CNPG-Backups: NAS20 (`https://nas20.eneg.de:8010`), verifiziertes TLS
  ueber CA-Bundle (`endpointCA: cnpg-s3-ca`). Einziger Cluster, den der
  Zertifikatstausch direkt betrifft.
- **TEST + PROD** CNPG-Backups: NAS10 (`http://nas10.eneg.de:8010`), HTTP, kein
  TLS. Zertifikatstausch dort irrelevant; Reboot-Erreichbarkeit relevant.
- NAS20-Migration fuer TEST/PROD weiterhin offen (Drift-Plan P4).

## Teil 1 - NAS-Schreibtest (aktive Verifikation)

Pro Cluster ein manuelles `Backup`-Objekt (method: plugin, target:
prefer-standby) angelegt und auf `completed` geprueft. Alle sechs erfolgreich:

| Umgebung | Cluster | NAS / Protokoll | Ergebnis |
|----------|---------|-----------------|----------|
| DEV | cnpg-erp | NAS20 / HTTPS (neue Zerts) | completed |
| DEV | cnpg-shared | NAS20 / HTTPS (neue Zerts) | completed |
| TEST | cnpg-erp | NAS10 / HTTP | completed |
| TEST | cnpg-shared | NAS10 / HTTP | completed |
| PROD | cnpg-erp | NAS10 / HTTP | completed |
| PROD | cnpg-shared | NAS10 / HTTP | completed |

Fazit: Beide NAS nach Reboot voll funktionsfaehig. Der Zertifikatstausch auf
NAS20 hat den verifizierten TLS-Zugriff aus DEV nicht beschaedigt. Temporaere
Backup-Objekte nach dem Test wieder entfernt (Base-Backups auf NAS bleiben).

## Teil 2 - cnpg-erp TEST ScheduledBackup reaktiviert

**Befund:** `cnpg-erp-full` (TEST) stand live auf `suspend: true` (seit
10.05.2026, Offline-Phase), lief seither nicht mehr. WAL-Archivierung war
durchgehend aktiv, nur der Base-Backup fehlte -> kein PITR moeglich. Der Wert
stand NICHT im Git (manueller Live-Eingriff, von ArgoCD nicht zurueckgesetzt,
da zusaetzliches Feld).

**Fix (GitOps):** `suspend: false` explizit in
`environments/test/cnpg-cluster/scheduled-backup.yaml` gesetzt. Nach Sync loeste
der Controller sofort einen nachgeholten Base-Backup aus (completed 12:15Z),
Cluster-Condition `LastBackupSucceeded=True`.

## Teil 3 - suspend: false in DEV/PROD vereinheitlicht

Zur Konsistenz mit TEST (Drift-Vermeidung) `suspend: false` explizit auch in
DEV und PROD gesetzt (`environments/{dev,prod}/cnpg-cluster/scheduled-backup.yaml`,
je beide ScheduledBackups). Live war dort `suspend` ohnehin ungesetzt (Default
false) -> semantisch identisch, kein Effekt auf laufende Backups, kein
Nachhol-Backup. Alle drei Umgebungen jetzt deckungsgleich.

## Teil 4 - doppelter monitoring-Block bereinigt

**Befund:** Vier Cluster-Manifeste hatten zwei `monitoring:`-Bloecke
(enablePodMonitor true oben, false unten). In YAML gewinnt der letzte Key ->
effektiv war ueberall `false` aktiv (am Live-Cluster bestaetigt). Betroffen:
test/cnpg-erp, test/cnpg-shared, prod/cnpg-erp, prod/cnpg-shared. DEV war sauber.

**Fix:** Jeweils den ersten Block (true) entfernt, `false` beibehalten
(Standalone-PodMonitors aus `monitoring-alerts/cnpg-podmonitors.yaml` uebernehmen
das Monitoring in TEST/PROD; `enablePodMonitor` wird dort ohnehin per Operator-SSA
ueberschrieben). Kein Effekt auf Live-Zustand.

## Teil 5 - PROD cnpg-erp Recovery-Konfig entfernt (OutOfSync-Fix)

**Befund:** App `cnpg-cluster` PROD war dauerhaft `OutOfSync` (Health: Healthy).
Ursache: `Cluster/cnpg-erp` trug im Git noch `bootstrap.recovery` +
`externalClusters` (serverName cnpg-erp) vom S3-Restore am 08.07. `bootstrap` ist
immutable -> Operator normalisiert das Live-Objekt -> dauerhafter Diff.

**Fix (GitOps, Weg 1 - vollstaendig entfernt):** `bootstrap`-Block und
`externalClusters`-Block aus `environments/prod/cnpg-cluster/cnpg-erp.yaml`
entfernt (Cluster ist laengst gebootet, Recovery-Quelle nicht mehr noetig).
Aktiver Archivpfad (plugins-Block) blieb unveraendert. Nach Sync:
App `Synced/Healthy`, keine Pod-Neustarts (Pods vom 08.07./13.07. unveraendert),
immutable-Feld wird vom Operator folgenlos ignoriert.

**Bewusste DR-Konsequenz:** Ein reines ArgoCD-Redeploy wuerde cnpg-erp PROD ohne
Recovery-Anweisung neu (leer/initdb) booten. Restore aus S3 erfolgt im DR-Fall
ueber die separate Restore-Prozedur (siehe guides/cnpg-barman-cloud-plugin-*),
nicht ueber ArgoCD. Bewusst akzeptiert.

## Teil 6 - serverName vN entfernt, PROD an DEV/TEST angeglichen

Beide PROD-Cluster nutzten nach den 08.07.-Recoverys einen versionierten
serverName (`cnpg-erp-v2`, `cnpg-shared-v2`), um Kollisionen mit den Alt-Archiven
zu vermeiden. Da die Alt-Historie nicht mehr gebraucht wird, auf den Standard-Pfad
(serverName = Clustername, wie DEV/TEST) zurueckgestellt.

**Ablauf pro Cluster (bewusste Reihenfolge, DR-sicher):**
1. Sicherheits-Backup unter altem vN-Pfad (completed).
2. Alten/stale S3-Ordner auf NAS10 umbenennen (Ziel-Pfad muss leer sein, sonst
   WAL-Kollision wie am 08.07.):
   - cnpg-erp: `cnpg-erp/cnpg-erp/` (alte Recovery-Quelle) -> umbenannt/geloescht
   - cnpg-shared: `cnpg-shared/cnpg-shared/` (stale Alt-Archiv, Ausloeser 08.07.)
     -> umbenannt/geloescht
3. `serverName`-Zeile aus `environments/prod/cnpg-cluster/cnpg-{erp,shared}.yaml`
   entfernt (GitOps), Sync.
4. Frischer Base-Backup unter neuem Standard-Pfad (beide completed).
5. Alte vN-Ordner auf NAS10 geloescht.

**Pfad-Ergebnis (beide PROD-Cluster):**
- vorher: `s3://k8s-prod-postgres-wal/cnpg-{erp,shared}/cnpg-{erp,shared}-v2/`
- nachher: `s3://k8s-prod-postgres-wal/cnpg-{erp,shared}/cnpg-{erp,shared}/`

**Verifikation WAL-Archivierung (cnpg-shared, live):** `pg_stat_archiver`
archived_count stieg unter Last (333 -> 337), last_archived aktuell, 0 haengende
`.ready`, keine neuen failed. Plugin-Log bestaetigt Wechsel des serverName im
`barman-cloud-wal-archive`-Aufruf (cnpg-shared-v2 -> cnpg-shared) ab 13:50Z.

## Wichtige Erkenntnisse (Lessons Learned)

- **LL-1:** ScheduledBackup-`suspend` live gesetzt wird von ArgoCD NICHT
  zurueckgenommen (zusaetzliches Feld). Gewuenschten Zustand explizit im Git
  deklarieren (`suspend: false`), dann greift SelfHeal.
- **LL-2:** Doppelte Map-Keys in YAML (hier `monitoring:`) sind stille Fehler -
  der letzte gewinnt. Bei Cluster-Manifesten auf Eindeutigkeit achten.
- **LL-3:** serverName-vN-Rueckbau erfordert zwingende Reihenfolge: erst
  Ziel-Pfad auf S3 leeren, dann umstellen. Sonst Kollision neue System-ID vs.
  Alt-Archiv (identischer Mechanismus wie Incident 08.07.).
- **LL-4:** QuObjects (QNAP-GUI) zeigt neue S3-Prefixe erst, wenn real Daten
  reinlaufen. Nach serverName-Wechsel erscheint `wals/` erst nach dem ersten
  echten WAL-Upload -> ggf. aktiv WAL-Last erzeugen (`pg_switch_wal()` mit
  Schreiblast), um die Kette sofort sichtbar zu verifizieren. `base/` entsteht
  sofort mit dem Base-Backup, `wals/` erst mit laufendem Archiving.
- **LL-5:** Aussagekraeftigster Archiv-Nachweis ist `pg_stat_archiver`
  (archived_count/last_archived_time) + `archive_status/*.ready`-Zaehler auf dem
  Primary, nicht die Cluster-Condition allein (die bleibt bei ausbleibender
  WAL-Last unveraendert "True").

## Offene Punkte / Follow-ups

- **Backup-Historie PROD:** Beide neuen Pfade haben aktuell nur den heutigen
  Base-Backup + WAL-Kette ab 14.07. mittags. PITR vor 14.07. fuer PROD nicht mehr
  moeglich (alte Pfade geloescht, bewusst). Regulaere Historie/Retention baut sich
  ueber die naechtlichen ScheduledBackups auf.
- **TEST walStorage nur 5Gi** (DEV/PROD 8Gi) und **fehlende priorityClassName**
  in TEST - beides P2-Themen (DB-Resilienz-Haertung), hier nur notiert, nicht
  angefasst.
- **NAS20-Migration TEST/PROD** weiterhin offen (Drift-Plan P4).
- Der 08.07.-Follow-up "kosmetischer OutOfSync cnpg-erp" ist mit Teil 5 dieses
  Vorgangs erledigt; der Follow-up "alte cnpg-shared/cnpg-erp-Historie im Bucket"
  mit Teil 6.

## Geaenderte Dateien

- `environments/dev/cnpg-cluster/scheduled-backup.yaml` (suspend: false)
- `environments/test/cnpg-cluster/scheduled-backup.yaml` (suspend: false)
- `environments/prod/cnpg-cluster/scheduled-backup.yaml` (suspend: false)
- `environments/test/cnpg-cluster/cnpg-erp.yaml` (monitoring-Dedup)
- `environments/test/cnpg-cluster/cnpg-shared.yaml` (monitoring-Dedup)
- `environments/prod/cnpg-cluster/cnpg-erp.yaml` (recovery entfernt,
  monitoring-Dedup, serverName entfernt)
- `environments/prod/cnpg-cluster/cnpg-shared.yaml` (monitoring-Dedup,
  serverName entfernt)
