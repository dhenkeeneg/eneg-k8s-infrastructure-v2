# P4b: Backup-Dienste S3-Migration NAS10 -> NAS20 (PROD)

**Status:** VOLLSTAENDIG ABGESCHLOSSEN & VERIFIZIERT (17.07.2026).
NIEDRIG-Block + HOCH-Block (CNPG erp/shared) beide fertig. Schliesst OF-8 + P4.
**Kontext:** Drift-Angleich DEV -> TEST/PROD, Prioritaet P4b. Schliesst OF-8
gemeinsam mit P4a ab (nach HOCH-Block).
**Bearbeiter:** Daniel Henke (Ausfuehrung) + Claude (Dateien/kubectl).
**Vorlage:** TEST P4b (phase-14-p4b-nas10-nas20-test.md), 1:1 uebertragen
(nur k8s-test-* -> k8s-prod-*).
**Scope:** MariaDB PhysicalBackup, garage-backup, odoo-backup, idoit-backup
(NIEDRIG, fertig) + CNPG erp/shared ObjectStore + pg_dumpall (HOCH, fertig).

---

## 1. Ausgangslage PROD (verifiziert 17.07.2026)

Beide CNPG-Cluster gesund 3/3, serverName leer (Standard = Clustername),
destinationPath s3://k8s-prod-postgres-wal/cnpg-{erp,shared}/, Retention 7d.
PROD war am 14.07. bewusst von serverName vN auf Standard zurueckgebaut -> NICHT
wieder auf vN gehen.

## 2. Kern-Entscheidungen (aus TEST uebernommen)

1. Clean Cutover (Weg b) - Dienste starten frisch auf NAS20, NAS10 Fallback bis Retention.
2. CNPG Weg B: gemeinsames cnpg-s3-credentials, gemeinsamer Cutover beider Cluster,
   danach je Cluster einzeln Base-Backup + Verifikation.
3. serverName Standard (Clustername), kein vN. destinationPath unveraendert.
4. Retention env-gewollt UNVERAENDERT (7d WAL, 32 Tage logisch, 168h MariaDB).
5. S3-Account: s3-k8s-prod (kombiniertes QuObjects-Format <user>:<token> in ACCESS_KEY,
   SECRET separat - NICHT am : trennen).
6. CA-Bundle (Sectigo R36+R46, oeffentlich, kein SOPS): pro Namespace ein *-s3-ca
   Secret, byte-identisch ueber alle Namespaces/Umgebungen.

## 3. NIEDRIG-Risiko-Block (DURCHGEFUEHRT, VERIFIZIERT 17.07.2026)

| Dienst | Live-Verifikation |
|--------|-------------------|
| MariaDB PhysicalBackup | Objekt neu angelegt (immutable-Loeschung), Auto-Job Complete/Success |
| garage-backup | Test-Job: Upload "Copied (new)" 267 KiB nach k8s-prod-garage-backup |
| odoo-backup | Test-Job: Filestore-Upload 7.7 MiB nach k8s-prod-odoo-backup |
| idoit-backup | Test-Job: NAS20 List/Delete (upload+src) fehlerfrei, kein x509/403 |

Alle vier: https://nas20.eneg.de:8010, CA-verifiziert, keine NAS10_*-Karteileichen mehr.

Geaenderte/neue Dateien (kubernetes/environments/prod/):
- mariadb-cluster/physical-backup.yaml; mariadb-secrets/{mariadb-s3-ca.yaml (NEU),
  kustomization.yaml, mariadb-credentials.yaml.template, .enc.yaml}
- garage-backup/cronjob.yaml; garage-backup-secrets/{garage-s3-ca.yaml (NEU),
  kustomization.yaml, garage-backup-credentials.yaml.template, .enc.yaml}
- apps/odoo/backup/{cronjob.yaml, secrets/odoo-s3-ca.yaml (NEU), secrets/kustomization.yaml,
  secrets/odoo-backup-credentials.yaml.template, .enc.yaml}
- apps/idoit/backup/{cronjob.yaml, secrets/idoit-s3-ca.yaml (NEU), secrets/kustomization.yaml,
  secrets/idoit-backup-credentials.yaml.template, .enc.yaml}

NAS20-Buckets angelegt: k8s-prod-mariadb-backup, k8s-prod-garage-backup,
k8s-prod-odoo-backup, k8s-prod-idoit.

## 4. Learnings aus PROD-Durchlauf (zusaetzlich zu TEST)

1. **git-Push-Divergenz (MariaDB-Start):** Windows-Push wurde rejected (fetch first),
   waehrend mgmt-10 zwischenzeitlich pushte. Folge: mariadb-s3-ca.yaml fehlte im Remote,
   ArgoCD konnte CA nicht rendern. Loesung: `git pull --rebase origin main` (Doku vorher
   `git stash push <datei>`), dann push. -> KONSEQUENZ: VOR jedem Sync `git status` +
   `git show origin/main:<pfad>` pruefen, dass ALLE Dateien (v.a. kustomization) im Remote.

2. **kustomization nicht committet (Garage):** resources-Zeile lag lokal "modified",
   war aber nie committet -> im Remote fehlte sie -> ArgoCD-Tree zeigte CA-Secret gar
   nicht (weder Synced noch OutOfSync). Mehrfacher Hard-Refresh half NICHT (nichts zu
   rendern). Erst nach commit+push der kustomization + Hard-Refresh erschien das Secret.

3. **Hard-Refresh per MCP zuverlaessiger als UI:**
   `kubectl patch application <app> -n argocd --type merge -p
   '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`
   Danach ~25s warten, dann Sync ausloesen (Refresh allein legt nichts an).

4. **NAS10_* -> NAS_* Key-Umbenennung = Karteileiche:** Nach Sync trug jedes Live-Secret
   BEIDE Key-Saetze. Loesung wie in Learnings: Live-Secret per kubectl loeschen,
   selfHeal legt sauber neu an (nur NAS_*). Verifiziert fuer garage/odoo/idoit.

5. **CronJob-Sync-Timing (Odoo):** Erster Test-Job aus CronJob-Stand VOR dem
   idoit-backup/odoo-backup-App-Sync -> CreateContainerConfigError (suchte NAS10_*).
   -> KONSEQUENZ: VOR Test-Backup pruefen, dass Live-CronJob bereits NAS_* + s3-ca-Volume
   traegt (`kubectl get cronjob <name> -o jsonpath=...env[*].name`).

6. **MariaDB serverName/Immutable:** PhysicalBackup.spec.storage immutable -> altes Objekt
   loeschen, ArgoCD legt neu an, Operator startet Auto-Job = Verifikation. Folgenlos
   (nur Backup-Definition). ROOT_PASSWORD in mariadb-credentials UNVERAENDERT gelassen.

## 5. HOCH-Risiko-Block CNPG (DURCHGEFUEHRT, VERIFIZIERT 17.07.2026)

CNPG erp + shared, Weg B (gemeinsames cnpg-s3-credentials, gemeinsamer Cutover,
danach je Cluster Base-Backup). serverName Standard (kein vN). Retention 7d/32d
unveraendert.

Geaenderte/neue Dateien (kubernetes/environments/prod/):
- cnpg-secrets/cnpg-s3-ca.yaml (NEU, CA aus Live mariadb-s3-ca byte-identisch)
  + kustomization.yaml (resources: cnpg-s3-ca.yaml ergaenzt)
- cnpg-cluster/objectstore-{erp,shared}.yaml: endpointURL https/nas20 + endpointCA
  (cnpg-s3-ca) + instanceSidecarConfiguration Checksum-Env. Retention 7d unveraendert.
- cnpg-backup/cronjob-{erp,shared}.yaml: S3_ENDPOINT https/nas20, AWS_CA_BUNDLE
  /etc/ca/ca.crt, Checksum-Env, ca-Volume (Secret cnpg-s3-ca) Mount /etc/ca.
  RETENTION_DAYS 32 unveraendert.
- cnpg-secrets/s3-credentials.yaml.template auf NAS20 dokumentiert.

Ablauf:
1. Phase 1 Probe-Pod (postgres:17 + apt awscli 2.23.6): NAS20-Zugriff auf
   k8s-prod-postgres-wal verifiziert (List/Put/Get/Delete OK, TLS + CA + Checksum +
   kombinierter Key s3-k8s-prod:...). Internet-Egress in PROD aktuell vorhanden.
2. Phase 2 Dateien gebaut + validiert (dry-run + kustomize + CA-byte-Vergleich).
3. Phase 3 Cutover: Windows-Push -> Remote-Check (alle 7 Dateien + CA byte-identisch
   in origin/main) -> mgmt-10 cnpg-s3-credentials auf NAS20 umverschluesselt -> Sync
   cnpg-secrets (Live-Verifikation CA + Endpoint + kombinierter Key, 3 Keys, keine
   NAS10-Reste) -> cnpg-cluster Hard-Refresh (Objectstores live https/nas20 + CA +
   Checksum) -> cnpg-logical-backup (CronJobs live NAS20 + ca-Volume).
4. Rolling-Restart: cnpg-erp startete beim Cutover automatisch neu; cnpg-shared NICHT
   -> manueller `kubectl cnpg restart cnpg-shared` (Longhorn-Reattach Primary ~5 Min).
5. Je Cluster Base-Backup erzwungen (erp zuerst) + verifiziert, dann pg_dumpall-Testjob.

Verifikation:
| Cluster | WAL-Archiving (Sidecar-Log) | Base-Backup NAS20 | pg_dumpall NAS20 |
|---------|-----------------------------|-------------------|-------------------|
| cnpg-erp | True (https/nas20, ~0.6s/WAL) | completed 20260717T134344 (7D->7E) | 1.1 MiB completed |
| cnpg-shared | True (https/nas20, nach Restart) | completed 20260717T134407 (E2->E3) | 188 KiB completed |

Test-Backup-CRs cnpg-{erp,shared}-p4b-nas20-base als Nachweis belassen (analog TEST).
Test-Jobs cnpg-{erp,shared}-p4b-nas20-test nach Verifikation geloescht.

## 6. Learnings HOCH-Block (zusaetzlich zu TEST)

1. **ObjectStore-Cutover triggert NICHT zwingend Pod-Restart:** cnpg-erp startete beim
   Sync automatisch neu (CA-Volume gemountet, WAL-Archiving sofort auf NAS20). cnpg-shared
   startete NICHT neu -> CA-Volume fehlte -> Retention-Delete scheiterte mit
   "SSL validation failed ... [Errno 2] No such file or directory" (= CA-Datei nicht
   gefunden, weil Volume nicht gemountet). WAL-Archiving lief derweil noch mit alter
   NAS10-Env weiter (kein Datenverlust). Fix: manueller `kubectl cnpg restart cnpg-shared`.
   -> KONSEQUENZ: Nach Objectstore-Cutover IMMER pruefen, ob beide Cluster tatsaechlich
   neugestartet sind (Pod-startTime). Wenn nicht: gezielt `kubectl cnpg restart <cluster>`.

2. **Retention-Delete-Fehler != WAL-Archive-Fehler:** Ein "SSL validation failed" im
   CatalogMaintenanceRunnable (backup-delete) ist unkritisch und blockiert das
   WAL-Archiving NICHT. Erst pruefen, ob `barman-cloud-wal-archive` betroffen ist,
   bevor man reagiert. Verschwindet nach Restart + 1. Base-Backup.

3. **CA immer gegen Live verifizieren, nicht aus Vorlage/Zwischenablage kopieren:**
   Beim ersten PROD-Schreibversuch der cnpg-s3-ca.yaml war ein Byte im base64 verfaelscht
   (Index 1737, Root-R46), gleiche Laenge -> nur per Zeichen-Diff gegen Live-mariadb-s3-ca
   gefunden. Neufassung direkt aus `kubectl get secret mariadb-s3-ca` -> byte-identisch.
   TEST-Datei war NICHT betroffen (gegengeprueft: TEST-Datei == TEST-Live == PROD-Live).

4. **instanceSidecarConfiguration liegt unter spec (nicht spec.configuration):** Beim
   Live-Check per jsonpath ist der Pfad `.spec.instanceSidecarConfiguration.env`, nicht
   `.spec.configuration.instanceSidecarConfiguration`. Operator ergaenzt Defaults
   (logLevel, retentionPolicyIntervalSeconds).

5. **Base-Backups liefen sehr schnell** (erp completed sofort, shared nach ~20s im
   Status started). Autoritativ: .status.phase=completed + backupId/beginWal/endWal.

## 7. Offener Rest

- Kein CNPG-Rest mehr offen. OF-8 GESCHLOSSEN (P4 a+b komplett).
- Test-Backup-CRs cnpg-{erp,shared}-p4b-nas20-base optional spaeter aufraeumen.
- Danach nur noch P5 (Longhorn replica-auto-balance) offen.
