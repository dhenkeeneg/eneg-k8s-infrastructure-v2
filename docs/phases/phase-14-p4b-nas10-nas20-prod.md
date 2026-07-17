# P4b: Backup-Dienste S3-Migration NAS10 -> NAS20 (PROD)

**Status:** NIEDRIG-Risiko-Block VOLLSTAENDIG ABGESCHLOSSEN & VERIFIZIERT (17.07.2026).
HOCH-Risiko-Block (CNPG erp/shared) OFFEN.
**Kontext:** Drift-Angleich DEV -> TEST/PROD, Prioritaet P4b. Schliesst OF-8
gemeinsam mit P4a ab (nach HOCH-Block).
**Bearbeiter:** Daniel Henke (Ausfuehrung) + Claude (Dateien/kubectl).
**Vorlage:** TEST P4b (phase-14-p4b-nas10-nas20-test.md), 1:1 uebertragen
(nur k8s-test-* -> k8s-prod-*).
**Scope:** MariaDB PhysicalBackup, garage-backup, odoo-backup, idoit-backup
(NIEDRIG, fertig) + CNPG erp/shared ObjectStore + pg_dumpall (HOCH, offen).

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

## 5. HOCH-Risiko-Block (OFFEN - eigener Chat)

CNPG erp + shared, Weg B. Ablauf siehe separater Handoff-Prompt + TEST-Doku Abschnitt.
Kernpunkte: Probe-Pod-Test VOR Cutover (k8s-prod-postgres-wal), gemeinsamer Cutover beider
Objectstores + pg_dumpall-Cronjobs, cnpg-s3-credentials umverschluesseln, Sync-Reihenfolge
cnpg-secrets -> cnpg-cluster (Hard-Refresh) -> cnpg-logical-backup, dann je Cluster
Base-Backup ERZWINGEN (erp zuerst). Rolling-Restart-Falle: Longhorn strict-local
Reattach 4-5 Min/Cluster, Base-Backup erst bei 3/3 + Archiving=True. serverName NICHT
setzen (Standard). Retention 7d/32d unveraendert.

NAS20-Bucket k8s-prod-postgres-wal muss existieren (postgres-backup legt sich beim 1.
logischen Backup selbst an).

## 6. Offener Rest

- CNPG HOCH-Block (s.o.)
- Nach PROD komplett: OF-8 in dev-to-test-prod-drift-2026-07.md schliessen,
  Projektplanung fortschreiben. Danach nur noch P5 (Longhorn replica-auto-balance).
