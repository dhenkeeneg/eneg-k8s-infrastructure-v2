# Handoff-Prompt: P4b NAS10->NAS20 Migration PROD

> Diesen gesamten Text als ersten Prompt in einen frischen Chat geben.
> Er enthaelt Kontext, Rollen, den erprobten TEST-Ablauf und alle Learnings.

---

## Rollen & Umgebung (unveraendert)

Wir arbeiten am Projekt "eNeG K8s Infrastruktur" (GitOps, 3 Cluster DEV/TEST/PROD,
alle sync aus branch `main`). Arbeitsumgebung: Windows-Laptop.
- Repo Windows: `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2`
- Repo mgmt-10: `~/git/eneg-k8s-infrastructure-v2`
- **Claude** editiert Dateien (Desktop Commander), nutzt Kubernetes-MCP (read + Backup-Trigger
  + Live-Secret-Loeschen bei GitOps-selfHeal-Regeneration), darf Probe-Pods anlegen/loeschen.
- **Daniel** macht: git commit/push, SOPS, ArgoCD-Sync (UI), QNAP-Bucket-Anlage, Server-Zugriffe.
- Immer nur EIN Schritt, erst pruefen dann naechster. Vor jedem CNPG-Entscheidungspunkt
  pausieren + Freigabe. Stabilitaet vor Geschwindigkeit. Klaerende Fragen (ask_user_input)
  vor ausfuehrlichen Antworten. Memory-Eintraege auf Deutsch. YAML ASCII-safe, Doku Deutsch,
  Conventional Commits Deutsch.

## Aufgabe

P4b Migration der PROD-Backup-Dienste von NAS10 auf NAS20 (QuObjects S3).
Reihenfolge wie in TEST erfolgreich durchgefuehrt: **erst NIEDRIG-Risiko-Block,
dann HOCH-Risiko-Block (CNPG)**. TEST ist vollstaendig abgeschlossen & verifiziert;
PROD laeuft nach exakt demselben Muster.

## PROD Ist-Zustand (verifiziert 16.07.2026)

- Beide CNPG-Cluster (cnpg-erp, cnpg-shared) gesund 3/3, Archiving=True, LastBackup=True.
- objectstores: `http://nas10.eneg.de:8010`, **serverName leer (Standard=Clustername)**,
  dest `s3://k8s-prod-postgres-wal/cnpg-{erp,shared}/`, retention 7d.
  WICHTIG: PROD wurde am 14.07. bewusst von serverName `vN` auf Standard zurueckgebaut
  -> NICHT wieder auf vN gehen. Standard-serverName beibehalten (= Clustername).
- NIEDRIG-Dienste existieren alle: databases/mariadb-galera-backup (PhysicalBackup, nas10,
  tls=false), garage/garage-backup, idoit/idoit-backup, odoo/odoo-backup,
  databases/cnpg-{erp,shared}-logical-backup.
- frueherer cnpg-shared PROD Incident (WAL-Verlust/x509) ist ausgeheilt - Cluster sauber.

---

## Entscheidungen (aus TEST uebernehmen)

1. **S3-User:** `s3-prod` bzw. der PROD-NAS20-Account (analog `s3-k8s-test`). Access-Key ist
   das **kombinierte QuObjects-Format** `<user>:<token>`, Secret-Key ist ein SEPARATER Wert.
2. **CNPG: Weg B** (= DEV/TEST-Weg): gemeinsames `cnpg-s3-credentials`, gemeinsamer Cutover
   beider Cluster, danach je Cluster einzeln Base-Backup + Verifikation. NICHT trennen.
3. **serverName Standard** (Clustername), kein vN. destinationPath bleibt gleich.
4. **Retention env-gewollt unveraendert lassen** (PROD: 7d WAL, 32 Tage logisch, 168h MariaDB).
   Das ist die bewusste Abweichung zu DEV (dort wurde gesenkt). NICHT senken.
5. **checksumAlgorithm/Checksum-Env** ist Pflicht (QuObjects/boto3 InvalidDigest-Workaround).
6. NAS20-Buckets muessen existieren: `k8s-prod-mariadb-backup`, `k8s-prod-garage-backup`,
   `k8s-prod-odoo-backup`, `k8s-prod-idoit`, `k8s-prod-postgres-wal`.
   (`k8s-prod-postgres-backup` legt sich beim 1. logischen Backup selbst an.)
   Daniel: vor Start pruefen/anlegen (QNAP GUI).

## Buckets/Endpunkte je Dienst (PROD)

| Dienst | Datei | Bucket PROD | Secret |
|--------|-------|-------------|--------|
| MariaDB PhysicalBackup | test->prod mariadb-cluster/physical-backup.yaml | k8s-prod-mariadb-backup | mariadb-credentials |
| garage-backup | garage-backup/cronjob.yaml | k8s-prod-garage-backup | garage-backup-credentials (NAS_*) |
| odoo-backup | apps/odoo/backup/cronjob.yaml | k8s-prod-odoo-backup | odoo-backup-credentials (NAS_*) |
| idoit-backup | apps/idoit/backup/cronjob.yaml | k8s-prod-idoit | idoit-backup-credentials (NAS_*) |
| CNPG WAL/objectstore erp+shared | cnpg-cluster/objectstore-{erp,shared}.yaml | k8s-prod-postgres-wal | cnpg-s3-credentials |
| CNPG logisch erp+shared | cnpg-backup/cronjob-{erp,shared}.yaml | k8s-prod-postgres-backup | cnpg-s3-credentials |

CA-Bundle (Sectigo R36+R46) ist oeffentlich, byte-identisch ueber alle Namespaces/Umgebungen
(sha256-Bundle wie DEV/TEST). Pro Namespace ein `*-s3-ca` Secret (kein SOPS). Einfach die
DEV- oder TEST-CA-Datei ins jeweilige PROD-secrets-Verzeichnis kopieren (Namespace/Name/Labels
identisch gueltig).

---

## Ablauf NIEDRIG-Risiko-Block PROD (MariaDB, Garage, Odoo, i-doit)

Pro Dienst: (1) CA-Datei ins secrets-Verzeichnis kopieren, (2) kustomization um
`resources: [<dienst>-s3-ca.yaml]` ergaenzen, (3) Credentials-Template auf NAS20/NAS_*
(bzw. S3_* bei MariaDB) aktualisieren, (4) cronjob/physical-backup auf https/nas20 +
CA-Mount + (rclone: RCLONE_CA_CERT / aws: AWS_CA_BUNDLE + Checksum-Env) umstellen.

Vorlage ist der TEST-Stand unter `kubernetes/environments/test/**` - 1:1 uebertragen,
nur `k8s-test-*` -> `k8s-prod-*` in Buckets/Pfaden und Kommentaren.

Danach:
1. Daniel: NAS20-Buckets anlegen.
2. Claude editiert alle Dateien, validiert YAML (python yaml.safe_load_all) + keine echten
   nas10-Referenzen (nur Kommentare erlaubt).
3. Daniel: commit/push (Windows) der Manifest-/Template-/CA-Dateien.
4. Daniel: auf mgmt-10 `git pull`, dann je Secret truncation-sicher neu verschluesseln
   (siehe SOPS-Block unten), dann committen/pushen.
5. Daniel: ArgoCD-Sync (erst *-secrets-Apps, dann Backup-Apps).
6. Claude: je Dienst Test-Backup triggern + Logs verifizieren (kein x509/403/InvalidDigest).

### MariaDB Sonderfaelle
- `mariadb-credentials` wird AUCH von `mariadb-galera.yaml` genutzt (ROOT_PASSWORD).
  Beim Neuverschluesseln bestehende .enc.yaml als Basis, ROOT_PASSWORD UNVERAENDERT lassen!
- `PhysicalBackup.spec.storage` ist IMMUTABLE (Webhook vphysicalbackup). Endpoint-Wechsel
  nur per Loeschen des PhysicalBackup-Objekts -> ArgoCD-Sync legt es neu an. Loeschen ist
  folgenlos (nur Backup-Definition, keine Daten/DB). Operator startet danach automatisch
  einen Backup-Job -> als Verifikation nutzen.

## Ablauf HOCH-Risiko-Block PROD (CNPG erp + shared, Weg B)

Dateien (test->prod uebertragen):
- `cnpg-secrets/cnpg-s3-ca.yaml` NEU (CA kopieren) + kustomization resources ergaenzen
- `cnpg-cluster/objectstore-{erp,shared}.yaml`: endpointURL https/nas20 + endpointCA
  (cnpg-s3-ca) + instanceSidecarConfiguration mit Checksum-Env. Retention 7d unveraendert.
  serverName NICHT setzen (Standard).
- `cnpg-backup/cronjob-{erp,shared}.yaml`: S3_ENDPOINT https/nas20, AWS_CA_BUNDLE=/etc/ca/ca.crt,
  Checksum-Env, ca-Volume (Secret cnpg-s3-ca) + Mount /etc/ca. RETENTION_DAYS 32 unveraendert.
- `cnpg-secrets/s3-credentials.yaml.template`: NAS20 + kombiniertes Key-Format dokumentieren.

Phasen:
- **Phase 1 (Probe-Pod):** VOR Cutover NAS20-Zugriff auf `k8s-prod-postgres-wal` verifizieren.
  Probe-Pod (postgres:17 + awscli) mit den NAS20-Credentials (aus funktionierendem
  mariadb-credentials PROD nach dessen Cutover ODER direkt eingetragen) + AWS_CA_BUNDLE +
  Checksum-Env: ListObjects/Put/Get/Delete testen. Alles gruen -> weiter.
- **Phase 2 (Dateien bauen):** wie oben, YAML validieren.
- **Phase 3 (Cutover):**
  1. Windows: 7 Dateien commit/push (objectstores, cronjobs, kustomization, template, cnpg-s3-ca).
  2. mgmt-10: pull, cnpg-s3-credentials truncation-sicher auf NAS20 umverschluesseln,
     commit/push. (ACCESS_KEY_ID kombiniert, SECRET_ACCESS_KEY separat, S3_ENDPOINT https/nas20)
  3. ArgoCD Sync REIHENFOLGE: erst `cnpg-secrets`. Claude verifiziert Live-Secret per Probe-Pod
     (ListBucket ROOT-OK). Dann `cnpg-cluster` mit **Hard-Refresh** + Sync. Dann `cnpg-logical-backup`.
  4. Claude: je Cluster Base-Backup ERZWINGEN (erp zuerst) + verifizieren, dann logisches
     Backup testen.

### CNPG Base-Backup erzwingen (Kubernetes-MCP)

kubectl_create mit Manifest:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: cnpg-erp-p4b-nas20-001    # bzw. cnpg-shared-...
  namespace: databases
spec:
  cluster:
    name: cnpg-erp                 # bzw. cnpg-shared
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```
Verifikation: `.status.phase=completed`, autoritativ sind `beginWal`/`endWal`/`backupId`
(NICHT die Cluster-Statusfelder firstRecoverabilityPoint/lastSuccessfulBackup - die werden
vom Barman-Plugin nicht zuverlaessig zurueckgeschrieben).

### CNPG Rolling-Restart-Falle (WICHTIG aus TEST gelernt)

Beim objectstore-Cutover startet der Operator BEIDE Cluster rollend neu (uebernimmt die neue
instanceSidecarConfiguration). Der Primary-Restart dauert wegen **Longhorn strict-local
Volume-Reattach ca. 4-5 Min pro Cluster** (Pod haengt scheinbar in "Terminating"/Pending -
das ist KEIN Fehler, nur Geduld). Der Operator macht die Cluster nacheinander.
- Base-Backup ERST anstossen, wenn der Cluster wieder vollstaendig 3/3 + Archiving=True ist.
- Ein Backup-CR, das WAEHREND des Primary-Restarts startet, verwaist im Status `started`
  (kein podName) und erholt sich NICHT -> loeschen und neu anlegen.
- CNPG-Pods zeigen in Kurzanzeige evtl. `Init:1/2`, sind aber 2/2 (Barman-Sidecar ist
  nativer Sidecar). Detailstatus pruefen, nicht die Kurzanzeige.
- `RetentionPolicyFailed`-Events direkt nach Cutover sind erwartbar (Ziel-Bucket leer,
  noch kein Base-Backup) und verschwinden nach dem 1. Base-Backup.

## SOPS truncation-sicher (Pflicht-Prozedur)

NIE `sops --encrypt x > x.enc.yaml` (Shell-Truncation zerstoert Ziel bei Fehler).
creation rules matchen auf INPUT-Pfad -> temp-Datei MUSS im secrets-Verzeichnis liegen
(nicht /tmp). Ablauf:
```bash
cd <secrets-verzeichnis>
sops --decrypt <name>.enc.yaml > <name>.tmp.yaml   # Basis (erhaelt bestehende Werte)
nano <name>.tmp.yaml                                # Werte auf NAS20
sops --encrypt <name>.tmp.yaml > <name>.enc.new     # in NEUE Datei
mv <name>.enc.new <name>.enc.yaml                   # erst dann ersetzen
rm <name>.tmp.yaml
```
Bei Bruch: `git checkout -- <name>.enc.yaml` stellt die intakte committete Version wieder her.

## Weitere Learnings (alle in TEST real aufgetreten)

1. **QuObjects-Access-Key = kombiniert** `<user>:<token>` in ACCESS_KEY_ID/NAS_ACCESS_KEY_ID.
   SECRET-Key ist ein SEPARATER Wert. NICHT am ":" aufteilen. (Fuehrte in TEST zu 403
   SignatureDoesNotMatch bei Odoo, als beide Felder den kombinierten String trugen.)
   Als Wertequelle das funktionierende Loki/Thanos- oder MariaDB-Secret desselben Accounts nutzen.
2. **KSOPS/ArgoCD Secrets = Merge-Apply:** bei Key-UMBENENNUNG (NAS10_*->NAS_*) bleiben alte
   Keys als Karteileichen im Live-Secret. Loesung: Live-Secret per Kubernetes-MCP loeschen,
   selfHeal legt sauber neu an (alle rclone-Secret-Apps haben automated+selfHeal). Bei reiner
   WERT-Aenderung (gleiche Keys) NICHT noetig - normaler Sync ueberschreibt.
3. **Hard-Refresh** bei gemounteten ConfigMap-/Secret-/CRD-Aenderungen in diesem Repo Pflicht
   (ArgoCD meldet sonst "Synced" ohne Apply).
4. **Reihenfolge Secret-first:** erst *-secrets-App syncen + Cluster-Secret pruefen, dann Dienst.
5. Probe-Pods immer nach Nutzung loeschen; temp-yaml im Repo-Root nach Nutzung `del`.
6. Kosmetik: garage-Template TEST hatte veralteten Kommentar "# 3. NAS10 S3 Credentials
   eintragen" - bei PROD gleich sauber schreiben.

## Nach PROD komplett

- Doku: `docs/migration/dev-to-test-prod-drift-2026-07.md` (P4b + P4 komplett, OF-8 schliessen),
  eigenes Migrationsdoc unter `docs/phases/`, Projektplanung als naechste Version fortschreiben.
- Danach nur noch P5 (Longhorn replica-auto-balance) offen.

## TEST-Referenz (erfolgreich abgeschlossen 16.07.2026)

Alle 4 NIEDRIG-Dienste + beide CNPG-Cluster (WAL-Archiving + Base-Backup + logisch) gegen
NAS20 verifiziert. cnpg-erp Base-Backup backupId 20260716T112126 (tl 11), cnpg-shared 002.
Test-Backup-CRs cnpg-{erp,shared}-p4b-nas20-* koennen als Nachweis in TEST verbleiben oder
aufgeraeumt werden.
