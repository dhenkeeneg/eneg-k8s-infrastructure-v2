# P4b: Backup-Dienste S3-Migration NAS10 -> NAS20 (TEST)

**Status:** TEST VOLLSTAENDIG ABGESCHLOSSEN & VERIFIZIERT (16.07.2026). PROD offen.
**Kontext:** Drift-Angleich DEV -> TEST/PROD, Prioritaet P4b (uebrige Backup-Dienste
nach P4a Thanos). Schliesst OF-8 gemeinsam mit P4a ab.
**Bearbeiter:** Daniel Henke
**Vorlage:** DEV 14a CNPG-Cutover (gekoppelter Block) + P4a-CA-Bundle-Muster.
**Scope:** MariaDB PhysicalBackup, garage-backup, odoo-backup, idoit-backup
(NIEDRIG-Risiko) + CNPG erp/shared ObjectStore + pg_dumpall (HOCH-Risiko).

---

## 1. Ausgangslage TEST (verifiziert 16.07.2026)

| Dienst | endpoint | TLS | Bucket | Secret |
|--------|----------|-----|--------|--------|
| MariaDB PhysicalBackup | nas10:8010 | false | k8s-test-mariadb-backup | mariadb-credentials |
| garage-backup | http://nas10:8010 | - | k8s-test-garage-backup | garage-backup-credentials |
| odoo-backup | http://nas10:8010 | - | k8s-test-odoo-backup | odoo-backup-credentials |
| idoit-backup | http://nas10:8010 | - | k8s-test-idoit | idoit-backup-credentials |
| CNPG erp/shared ObjectStore | http://nas10:8010 | - | k8s-test-postgres-wal | cnpg-s3-credentials |
| CNPG erp/shared pg_dumpall | http://nas10:8010 | - | k8s-test-postgres-backup | cnpg-s3-credentials |

CNPG-Ausgangszustand: beide Cluster gesund 3/3, Archiving=True, serverName leer
(Standard = Clustername), destinationPath s3://k8s-test-postgres-wal/cnpg-{erp,shared}/.

## 2. Kern-Entscheidungen

1. **Migrationsmethode:** Clean Cutover (Weg b) - Dienste starten frisch auf NAS20,
   NAS10 bleibt Fallback bis Retention. Keine Datenkopie.
2. **CNPG Weg B** (= DEV-Weg): gemeinsames cnpg-s3-credentials, gemeinsamer Cutover
   beider Cluster, danach je Cluster einzeln Base-Backup + Verifikation.
3. **serverName Standard** (Clustername), kein vN. PROD war am 14.07. bewusst von vN
   zurueckgebaut worden - dieselbe Linie fuer TEST.
4. **Retention env-gewollt UNVERAENDERT** (7d WAL, 32 Tage logisch, 168h MariaDB).
   Bewusste Abweichung zu DEV (dort gesenkt).
5. **S3-Account:** s3-k8s-test (gleicher NAS20-Account wie Loki/Thanos aus P4a).
   Access-Key kombiniertes QuObjects-Format, Secret-Key separat.
6. **CA-Bundle** (Sectigo R36+R46, oeffentlich, kein SOPS): pro Namespace ein *-s3-ca
   Secret, byte-identisch ueber alle Namespaces/Umgebungen.

## 3. NIEDRIG-Risiko-Block (durchgefuehrt, verifiziert)

Pro Dienst: CA-Datei ins secrets-Verzeichnis, kustomization um resources ergaenzt,
Credentials-Template auf NAS20/NAS_* (bzw. S3_* bei MariaDB), cronjob/physical-backup
auf https/nas20 + CA (rclone: RCLONE_CA_CERT / aws: AWS_CA_BUNDLE) + Checksum-Env.

Geaenderte/neue Dateien (kubernetes/environments/test/):
- mariadb-cluster/physical-backup.yaml; mariadb-secrets/{mariadb-s3-ca.yaml (NEU),
  kustomization.yaml, mariadb-credentials.yaml.template, .enc.yaml}
- garage-backup/cronjob.yaml; garage-backup-secrets/{garage-s3-ca.yaml (NEU),
  kustomization.yaml, garage-backup-credentials.yaml.template, .enc.yaml}
- apps/odoo/backup/{cronjob.yaml, secrets/odoo-s3-ca.yaml (NEU), secrets/kustomization.yaml,
  secrets/odoo-backup-credentials.yaml.template, .enc.yaml}
- apps/idoit/backup/{cronjob.yaml, secrets/idoit-s3-ca.yaml (NEU), secrets/kustomization.yaml,
  secrets/idoit-backup-credentials.yaml.template, .enc.yaml}

NAS20-Buckets angelegt: k8s-test-mariadb-backup, k8s-test-garage-backup,
k8s-test-odoo-backup, k8s-test-idoit.

Verifikation (Live-Test je Dienst gegen NAS20):
| Dienst | Ergebnis |
|--------|----------|
| garage-backup | openproject-assets kopiert (267 KiB), kein x509 |
| odoo-backup | 2,2 MiB Filestore kopiert (nach Credential-Fix) |
| idoit-backup | NAS20-Cleanup-Zugriff ok (upload leer, src nur So) |
| MariaDB PhysicalBackup | Auto-Backup nach NAS20 (nach Loeschen+Neuanlage) |

## 4. HOCH-Risiko-Block CNPG (durchgefuehrt, verifiziert)

Geaenderte/neue Dateien:
- cnpg-secrets/cnpg-s3-ca.yaml (NEU) + kustomization.yaml (resources)
- cnpg-cluster/objectstore-{erp,shared}.yaml: endpointURL https/nas20 + endpointCA
  (cnpg-s3-ca) + instanceSidecarConfiguration Checksum-Env. Retention 7d unveraendert.
- cnpg-backup/cronjob-{erp,shared}.yaml: S3_ENDPOINT https/nas20, AWS_CA_BUNDLE,
  Checksum-Env, ca-Volume/Mount. RETENTION_DAYS 32 unveraendert.
- cnpg-secrets/s3-credentials.yaml.template + .enc.yaml auf NAS20.

Ablauf:
1. Phase 1 Probe-Pod: NAS20-Zugriff auf k8s-test-postgres-wal verifiziert
   (List/Put/Get/Delete OK, TLS + Checksum + kombinierter Key).
2. Phase 2 Dateien gebaut + YAML-validiert.
3. Phase 3 Cutover: Windows-Push -> mgmt-10 Secret-Umverschluesselung -> ArgoCD-Sync
   (cnpg-secrets zuerst + Live-Secret-Probe ROOT-OK, dann cnpg-cluster Hard-Refresh,
   dann cnpg-logical-backup).
4. Je Cluster Base-Backup erzwungen + verifiziert, dann logisches Backup getestet.

Verifikation:
| Cluster | Archiving | Base-Backup NAS20 | pg_dumpall NAS20 |
|---------|-----------|-------------------|-------------------|
| cnpg-erp | True | completed (backupId 20260716T112126, tl 11) | 930 KiB completed |
| cnpg-shared | True | completed (002) | 189 KiB completed |

## 5. Learnings (alle in TEST real aufgetreten)

1. **QuObjects-Access-Key ist kombiniert** `<user>:<token>` und gehoert komplett in
   ACCESS_KEY_ID / NAS_ACCESS_KEY_ID. SECRET_ACCESS_KEY ist ein SEPARATER, anderer Wert.
   NICHT am Doppelpunkt aufteilen. (Fuehrte bei Odoo zu 403 SignatureDoesNotMatch, als
   beide Felder den kombinierten String trugen.) Als Wertequelle ein funktionierendes
   Secret desselben Accounts (Loki/Thanos/MariaDB) nutzen.

2. **KSOPS/ArgoCD Secrets = Merge-Apply:** Bei Key-UMBENENNUNG (NAS10_* -> NAS_*)
   bleiben alte Keys als Karteileichen im Live-Secret. Loesung: Live-Secret loeschen
   (Kubernetes-MCP), selfHeal legt sauber neu an. Bei reiner WERT-Aenderung (gleiche
   Keys) NICHT noetig - normaler Sync ueberschreibt.

3. **MariaDB PhysicalBackup.spec.storage ist IMMUTABLE** (Webhook vphysicalbackup).
   Endpoint-Wechsel nur per Loeschen des Objekts -> ArgoCD-Sync legt neu an. Loeschen
   folgenlos (nur Backup-Definition). Operator startet danach Auto-Backup (= Verifikation).
   mariadb-credentials wird AUCH von mariadb-galera.yaml genutzt (ROOT_PASSWORD) -> beim
   Neuverschluesseln bestehende .enc.yaml als Basis, ROOT_PASSWORD unveraendert lassen.

4. **SOPS truncation-sicher:** NIE `sops --encrypt x > x.enc.yaml` (Shell leert Ziel bei
   Fehler). creation rules matchen auf INPUT-Pfad -> temp-Datei MUSS im secrets-Verzeichnis
   liegen (nicht /tmp). Ablauf: decrypt->tmp.yaml, nano, encrypt->enc.new, mv, rm tmp.
   Bei Bruch: git checkout stellt intakte .enc.yaml wieder her.

5. **CNPG Rolling-Restart + Longhorn-Reattach:** Beim objectstore-Cutover startet der
   Operator beide Cluster rollend neu (uebernimmt instanceSidecarConfiguration). Der
   Primary-Restart dauert wegen Longhorn strict-local Volume-Reattach ~4-5 Min pro Cluster
   (Pod scheinbar "Terminating"/Pending = KEIN Fehler). Base-Backup ERST bei 3/3 +
   Archiving=True anstossen. Ein waehrend des Restarts gestartetes Backup-CR verwaist im
   Status `started` (kein podName) und erholt sich nicht -> loeschen + neu anlegen
   (bei cnpg-shared real passiert: 001 verwaist, 002 completed).

6. **CNPG Status-Writeback:** firstRecoverabilityPoint/lastSuccessfulBackup im Cluster
   werden vom Barman-Plugin nicht zuverlaessig zurueckgeschrieben. Autoritativ ist das
   Backup-CR (.status.phase=completed + beginWal/endWal/backupId).

7. **Hard-Refresh** bei gemounteten ConfigMap-/Secret-/CRD-Aenderungen in diesem Repo
   Pflicht (ArgoCD meldet sonst "Synced" ohne Apply).

8. **RetentionPolicyFailed-Events** direkt nach CNPG-Cutover sind erwartbar (Ziel-Bucket
   leer, noch kein Base-Backup) und verschwinden nach dem 1. Base-Backup.

## 6. Offene Punkte / Nacharbeiten

- PROD-Cutover (gleiche Reihenfolge NIEDRIG -> CNPG). Handoff-Prompt:
  docs/handoff/P4b-PROD-Cutover-Handoff.md
- Test-Backup-CRs cnpg-{erp,shared}-p4b-nas20-* in TEST: als Nachweis belassen oder
  aufraeumen (unkritisch).
- Kosmetik: garage-Template TEST hat noch veralteten Kommentar "# 3. NAS10 S3
  Credentials eintragen".
- Nach PROD: OF-8 + P4 komplett abschliessen, dann nur noch P5 (Longhorn
  replica-auto-balance) offen.

## 7. Zeitleiste

| Datum | Ereignis |
|-------|----------|
| 16.07.2026 | P4b TEST NIEDRIG-Block (MariaDB/Garage/Odoo/idoit) ABGESCHLOSSEN & verifiziert |
| 16.07.2026 | P4b TEST HOCH-Block (CNPG erp+shared ObjectStore+pg_dumpall) ABGESCHLOSSEN & verifiziert |
