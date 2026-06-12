# Phase 14: S3-Migration NAS10 -> NAS20

**Status:** In Bearbeitung (14a DEV: 7 von 11 Diensten migriert)
**Beginn:** 11.06.2026
**Bearbeiter:** Daniel Henke
**Methode:** Clean Cutover ueber GitOps (kein Daten-Sync), Ausnahme: Registry

**14a DEV Fortschritt:** Velero, garage/odoo/idoit-backup, MariaDB, CNPG (erp+shared,
ObjectStore+pg_dumpall+basebackup), Loki = FERTIG. Offen: Thanos (#7), Registry (#11),
14a-cleanup (skip-verify -> CA-Bundle bei Velero+rclone, NAS10_*-Karteileichen).

---

## 1. Zielsetzung

Umzug des kompletten S3-Backends von NAS10 (nas10.eneg.de:8010) auf NAS20.
Beide Systeme sind QNAP QuObjects (path-style, HTTP, insecure). NAS20 hat
weniger Speicherplatz, daher wird die Retention gesenkt.

### Kernentscheidungen

| Thema | Entscheidung |
|-------|--------------|
| Migrationsmethode | Clean Cutover (Dienste starten frisch auf NAS20) |
| Ausnahme Registry | rclone-Sync NAS10->NAS20 (Live-Daten, kein Backup) |
| Retention neu | DEV/TEST 5 Tage, PROD 10 Tage (Backup + Logs) |
| Retention-Zeitpunkt | direkt beim Cutover in NAS20-Configs setzen |
| Alt-PITR | nicht benoetigt (frischer Start akzeptiert) |
| Log-/Metrik-Historie | frischer Start akzeptiert |
| Checksum-Workarounds | bleiben erhalten (separater Test danach in DEV) |
| Credentials | 1 S3-User pro Umgebung, Stufe 1 (nur Werte tauschen) |
| Secret-Konsolidierung | Stufe 2 als separates Folge-Refactoring (spaeter) |
| garage-backup Keys | NAS10_* -> NAS_* neutral umbenennen |
| Loki S3-Config | aus base/ in env-Override pro Umgebung ziehen |
| Reihenfolge | streng DEV -> TEST -> PROD, ein Dienst nach dem anderen |
| ArgoCD SelfHeal | aktiv (nur coredns false) - bleibt so |

### NAS20 S3-Accounts (vorbereitet)

| Speicherplatz | Benutzername | Umgebung |
|---------------|--------------|----------|
| s3-k8s-dev | k8s-dev-s3 | DEV |
| s3-k8s-test | k8s-test-s3 | TEST |
| s3-k8s-prod | k8s-prod-s3 | PROD |

Bucket-Topologie wie NAS10: 1 User pro Umgebung, viele Buckets (k8s-{env}-{service}).
Bucket-Namen bleiben identisch zu NAS10.

---

## 2. QuObjects 2.5.629 - Checksum-Fix Hinweis

NAS20 laeuft mit QuObjects 2.5.629 (20.05.2026). Die Release Notes nennen:

  "Fixed an issue where S3 PUT Object requests using the latest AWS S3 SDK
   with flexible checksum headers were incorrectly rejected with HTTP 400."

Das ist mit hoher Wahrscheinlichkeit der bekannte InvalidDigest-Bug
(aws-sdk-go-v2 v1.30+ / boto3 1.36+ Trailing-Checksums). Moeglicherweise
sind die Workarounds auf NAS20 nicht mehr noetig.

ENTSCHEIDUNG: Workarounds bleiben bei der Migration ERHALTEN (Stabilitaet vor
Optimierung). Ein isolierter Test (Velero in DEV, checksumAlgorithm entfernen)
erfolgt NACH erfolgreicher Migration als separater Schritt (Phase 14e).
Das Rate-Limiting bei LIST-Operationen ist vom Fix nicht adressiert.

### Erhaltene Workarounds

| Workaround | Betrifft |
|------------|----------|
| checksumAlgorithm: "" | Velero (BSL config) |
| AWS_REQUEST_CHECKSUM_CALCULATION=when_required | CNPG ObjectStore, pg_dumpall |
| AWS_RESPONSE_CHECKSUM_VALIDATION=when_required | CNPG ObjectStore, pg_dumpall |
| rclone --fast-list (statt --checksum) | garage/odoo/idoit |

---

## 3. Migrationsmatrix (DEV - Muster fuer alle Envs)

| # | Dienst | Datei | Endpoint-Feld | Bucket DEV | Retention alt -> neu | Secret |
|---|--------|-------|---------------|------------|----------------------|--------|
| 1 | CNPG erp | cnpg-cluster/objectstore-erp.yaml | endpointURL | k8s-dev-postgres-wal | 7d -> 5d | cnpg-s3-credentials |
| 2 | CNPG shared | cnpg-cluster/objectstore-shared.yaml | endpointURL | k8s-dev-postgres-wal | 7d -> 5d | cnpg-s3-credentials |
| 3 | pg_dumpall shared | cnpg-backup/cronjob-shared.yaml | S3_ENDPOINT env | k8s-dev-postgres-backup | 32 -> 5 | cnpg-s3-credentials |
| 3b| pg_dumpall erp | cnpg-backup/cronjob-erp.yaml | S3_ENDPOINT env | k8s-dev-postgres-backup | 32 -> 5 | cnpg-s3-credentials |
| 4 | MariaDB | mariadb-cluster/physical-backup.yaml | storage.s3.endpoint | k8s-dev-mariadb-backup | 168h -> 120h | mariadb-credentials |
| 5 | Velero | velero/values-override.yaml | s3Url | k8s-dev-velero | 336h -> 120h | velero-s3-credentials |
| 6 | Loki | base -> env-override | loki.storage.s3.endpoint | k8s-dev-loki | 2160h -> 120h | loki-s3-credentials |
| 7 | Thanos | monitoring-secrets/thanos-objstore-config (SOPS) | endpoint (im Secret) | k8s-dev-thanos | unbegr. -> Compactor 5d | (im Secret) |
| 8 | garage-backup | garage-backup/cronjob.yaml | endpoint (rclone.conf) | k8s-dev-garage-backup | 32 -> 5 | garage-backup-credentials (NAS10_*->NAS_*) |
| 9 | odoo-backup | odoo-backup/cronjob.yaml | rclone.conf | k8s-dev-odoo-backup | 32 -> 5 | odoo-backup-credentials |
| 10| idoit-backup | idoit-backup/cronjob.yaml | rclone.conf | k8s-dev-idoit | 32 -> 5 | idoit-backup-credentials |
| 11| registry (Zot) | registry/values-override.yaml | regionendpoint | k8s-dev-registry | n/a (rclone-Sync) | registry-s3-credentials |

Secret-Key-Namen je Dienst unterschiedlich (Stufe 1: nur Werte tauschen, Struktur bleibt):
- cnpg-s3-credentials: ACCESS_KEY_ID / SECRET_ACCESS_KEY
- mariadb-credentials: S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY
- velero-s3-credentials: cloud (AWS-Profil-Datei)
- loki-s3-credentials: S3_ACCESS_KEY / S3_SECRET_KEY
- thanos-objstore-config: komplettes objstore.yml (inkl. endpoint)
- registry-s3-credentials: accesskey / secretkey
- garage/odoo/idoit-backup-credentials: NAS_* (nach Umbenennung)

---

## 4. Etappenstruktur

| Etappe | Inhalt | Voraussetzung |
|--------|--------|---------------|
| 14a | DEV Cutover (alle Dienste) | Buckets+Connectivity NAS20 OK |
| 14b | TEST Cutover | 14a verifiziert |
| 14c | PROD Cutover | 14b verifiziert |
| 14d | NAS10 Decommissioning | 14c + Karenzzeit stabil |
| 14e | Checksum-Workaround-Test (DEV, optional) | 14a stabil |

### Cutover-Reihenfolge je Umgebung (Dienst fuer Dienst)

Empfohlene Reihenfolge (unkritisch -> kritisch):

1. Velero (isoliert, leicht verifizierbar - Probelauf fuer das Muster)
2. garage-backup / odoo-backup / idoit-backup (rclone, taeglich)
3. pg_dumpall (erp + shared)
4. MariaDB physical-backup
5. Loki (base->override Umbau + Cutover, Pod-Neustart)
6. Thanos (SOPS-Secret)
7. CNPG erp + shared (neues basebackup - kritischster Schritt)
8. Registry (rclone-Sync + Endpoint-Wechsel - Sonderfall Live-Daten)

Pro Dienst: 1 Commit (endpoint + retention + ggf. Secret) -> push ->
ArgoCD Auto-Sync -> verifizieren -> naechster Dienst.

---

## 5. Vorbereitung (vor 14a)

- [ ] NAS20 Buckets pro Umgebung anlegen (k8s-{env}-{service}, identisch NAS10)
- [ ] NAS20 S3-Credentials (Access/Secret Key) je Umgebung notieren
- [ ] Connectivity-Test von einem Pod aus (DNS + Port erreichbar)
- [ ] DNS-Name fuer NAS20 klaeren (nas20.eneg.de?) und Endpoint-String festlegen

### Benoetigte Buckets pro Umgebung

k8s-{env}-postgres-wal, k8s-{env}-postgres-backup, k8s-{env}-mariadb-backup,
k8s-{env}-velero, k8s-{env}-loki, k8s-{env}-thanos, k8s-{env}-garage-backup,
k8s-{env}-odoo-backup, k8s-{env}-idoit, k8s-{env}-registry

---

## 6. Verifikation je Dienst (Checkliste)

| Dienst | Verifikation |
|--------|--------------|
| Velero | BSL Phase=Available, Test-Backup Completed |
| rclone-Jobs | CronJob manuell triggern, Objekte im NAS20-Bucket |
| pg_dumpall | CronJob manuell triggern, Dump im NAS20-Bucket |
| MariaDB | PhysicalBackup Job Completed, Objekt im Bucket |
| Loki | Pod Ready, neue Chunks im NAS20-Bucket, Grafana zeigt neue Logs |
| Thanos | Sidecar Connected, neue Bloecke im NAS20-Bucket |
| CNPG | neues basebackup OK, WAL-Archive laeuft (~300-650ms/WAL), kein InvalidDigest |
| Registry | Images nach Sync vorhanden, Push/Pull funktioniert |

---

## 7. Aenderungshistorie

| Datum | Was |
|-------|-----|
| 11.06.2026 | Phase 14 angelegt, Strategie + Migrationsmatrix dokumentiert |
| 11.06.2026 | ERKENNTNIS: NAS20 spricht HTTPS auf Port 8010 (NAS10 war HTTP). Alle Configs muessen von http:// auf https:// + skip-verify. Siehe Abschnitt 8. |
| 11.06.2026 | 14a Velero DEV Cutover ABGESCHLOSSEN: s3Url https://nas20.eneg.de:8010, Retention 120h (5d), checksumAlgorithm-Workaround erhalten. BSL Available, Test-Backup test-nas20-001 Completed (4349/4349 Items, 0 Errors, 15 unkritische Warnings, ~33GB auf NAS20). Hard-Refresh nach Helm-Sub-Map-Change noetig. |
| 11.06.2026 | 14a rclone-Jobs (garage/odoo/idoit) DEV Cutover ABGESCHLOSSEN: https/nas20, NAS_*-Keys, Retention 5d, --checksum entfernt. Alle drei verifiziert (garage 17KiB, odoo 9.7MiB, idoit src-Tarball 4.5MiB auf NAS20 geschrieben). TLS-Fix: RCLONE_NO_CHECK_CERTIFICATE Env-Var noetig (conf-Option no_check_certificate greift NICHT). |
| 11.06.2026 | ERKENNTNIS (generell): ArgoCD meldet bei gemounteten ConfigMap-/Secret-Aenderungen in diesem Repo "Synced", wendet sie aber NICHT an. Hard-Refresh (annotate refresh=hard) ist bei JEDEM Cutover-Schritt noetig - nicht nur Helm. |
| 11.06.2026 | ERKENNTNIS (Zertifikat): NAS20 QuObjects lieferte auf 8010 zunaechst das selbstsignierte QNAP-Default-Zert (CN=QNAP NAS, kein SAN). Nach Hinterlegung des Wildcard-Zerts als System-Standard + QuObjects-Neustart liefert 8010 jetzt das gueltige Wildcard CN=*.eneg.de (Issuer Sectigo, oeffentliche CA, im System-Trust-Store, SAN *.eneg.de + eneg.de, gueltig bis 12.09.2026). Servertyp bleibt "Eigenstaendiger Server" (Standalone), path-style bleibt. -> Echtes verifizierbares TLS fuer ALLE Dienste moeglich, kein skip-verify mehr noetig. |
| 11.06.2026 | ENTSCHEIDUNG: Ab MariaDB sauberes TLS (https + Verifikation, kein skip-verify). Bereits migrierte Dienste (Velero + 3 rclone) laufen mit skip-verify weiter (funktioniert auch mit gueltigem Zert), werden am Ende in Etappe 14a-cleanup auf sauberes TLS umgestellt. ZERT-ABLAUF 12.09.2026 als Monitoring-Punkt vormerken! |
| 11.06.2026 | ERKENNTNIS (QuObjects-Kette): QuObjects-Webserver auf 8010 sendet NUR das Leaf-Zert, nicht die Intermediate-Kette (bekanntes QuObjects-Limit, serverseitig NICHT loesbar - QTS-Webserver wuerde Kette senden, QuObjects-eigener nicht). Folge: Clients mit strikter Verifikation (z.B. MariaDB-Operator) brauchen das CA-Bundle clientseitig. |
| 11.06.2026 | 14a MariaDB DEV Cutover ABGESCHLOSSEN: PhysicalBackup endpoint https/nas20, tls.enabled:true + caSecretKeyRef (mariadb-s3-ca), maxRetention 120h. CA-Bundle = Sectigo Intermediate DV R36 + Root R46 (von crt.sectigo.com, openssl Verify rc=0). Secret mariadb-s3-ca UNVERSCHLUESSELT (oeffentliche CA) als resources-Eintrag neben ksops-generator. mariadb-credentials S3-Keys auf NAS20. WICHTIG: PhysicalBackup spec.storage IMMUTABLE -> Objekt loeschen+ArgoCD-SelfHeal legt neu an. Backup-Pod completed, kein x509-Fehler, Push+Cleanup ok. |
| 11.06.2026 | ERKENNTNIS (CNPG Init:1/2 = KEIN Fehler): CNPG-Pods zeigen in `kubectl get pods` Kurzanzeige `Init:1/2`, sind aber tatsaechlich 2/2 Running + Ready. Grund: Barman-Plugin-Sidecar (plugin-barman-cloud) ist ein NATIVER Sidecar (initContainer mit restartPolicy:Always) - laeuft dauerhaft und zaehlt daher in der Init-Spalte als "nicht abgeschlossen". Detailstatus (.status.phase=Running, conditions Ready=True) pruefen, nicht die Kurzanzeige. Verifiziert: alle 6 Pods (cnpg-erp-3/4/7, cnpg-shared-2/3/5) 2/2 Running. -> CNPG gesund, bereit fuer Migration. |
| 12.06.2026 | 14a CNPG DEV Cutover ABGESCHLOSSEN (#1/#2/#3/#3b, gekoppelter Block): ObjectStores erp+shared endpointURL https/nas20 + endpointCA (Secret cnpg-s3-ca), retention 7d->5d. pg_dumpall-CronJobs erp+shared S3_ENDPOINT https/nas20, RETENTION_DAYS 32->5, AWS_CA_BUNDLE=/etc/ca/ca.crt + ca-Volume-Mount (Secret cnpg-s3-ca). cnpg-s3-credentials: SECRET_ACCESS_KEY + S3_ENDPOINT auf NAS20 (ACCESS_KEY_ID bleibt s3-k8s-dev). Eigenes Secret cnpg-s3-ca statt mariadb-s3-ca (Entkopplung). Verifiziert: WAL-Archiving beide Primaries (~0,65-0,98s/WAL, kein x509/InvalidDigest), pg_dumpall beide Cluster (Upload complete), basebackup beide (Backup-CR completed). Rolling-Restart aller 6 Pods durch Operator (transientes Degraded, normal). |
| 12.06.2026 | ERKENNTNIS (CNPG Cloud-Plugin Status-Writeback): firstRecoverabilityPoint + lastSuccessfulBackup im Cluster-Objekt werden vom Barman Cloud Plugin NICHT zuverlaessig/sofort zurueckgeschrieben (zeigten nach Cutover noch alte NAS10-Werte). Autoritativ ist das Backup-CR (.status.phase=completed + beginWal/endWal) + erfolgreiche WAL-Archive-Logs, NICHT die Cluster-Status-Felder. barman-cloud-backup-list per manuellem exec scheitert mit "Unable to locate credentials" (Sidecar-Env wird nicht vererbt) - kein Datenproblem. |
| 12.06.2026 | 14a Loki DEV Cutover ABGESCHLOSSEN (#6, B1-Variante): base/monitoring/loki/values.yaml auf https/nas20 + insecure:false + http_config.ca_file (Quelle der Wahrheit). DEV-Override: extraVolumes/Mounts (Secret eneg-s3-ca, NS monitoring, namespace-weit fuer Loki+Thanos) + retention 120h. TEST/PROD-Overrides DEFENSIV auf NAS10/HTTP zurueckgezogen (endpoint + insecure:true), bis deren Migration. CA-Mount NUR im DEV-Override (nicht base!), sonst haengen TEST/PROD-Pods am fehlenden Secret. loki-s3-credentials S3_SECRET_KEY auf NAS20. Verifiziert: Pod 2/2, S3 Read (download ~1-2,5ms) + Write (flushing stream bis 4MB, kein failed to flush), kein x509. |
| 12.06.2026 | ERKENNTNIS (Env-Staleness bei Secret-Cutover): Dienste die S3-Credentials via extraEnvFrom/secretRef als ENV laden (Loki), bekommen Secret-Aenderungen NICHT live - Pod laedt ENV nur beim Start. Wenn Hard-Refresh den Pod VOR dem Secret-Sync neu startet, traegt er alte Credentials (Folge: InvalidAccessKeyId trotz korrektem Cluster-Secret). LEHRE: Reihenfolge = erst *-secrets-App syncen + Cluster-Secret pruefen, DANN Dienst-Pod (neu)starten. Bei Loki war ein zweiter manueller Pod-Restart noetig. |

---

## 8. WICHTIG: NAS20 nutzt HTTPS (nicht HTTP wie NAS10)

Bei der Velero-Verifikation (14a) zeigte sich: NAS20 (QuObjects 2.5.629) lauscht
auf Port 8010 mit HTTPS/TLS, waehrend NAS10 reines HTTP nutzte.

Diagnose (Test-Pod im DEV-Cluster):
- DNS OK: nas20.eneg.de -> 192.168.161.62 (NAS10: .61, gleiches Subnetz)
- Routing/Firewall OK: TCP-Connect auf 8010 erfolgreich
- HTTP-Test: "Empty reply from server" (curl 52) - Server kappt Klartext
- HTTPS-Test: TLS-Handshake OK, Server-Zert = QNAP-Default (CN=QNAP NAS,
  selbstsigniert, O=QNAP Systems)

ENTSCHEIDUNG: Cluster-Configs auf HTTPS umstellen (Option B). NAS20 behaelt
das selbstsignierte QNAP-Default-Zertifikat; alle Clients nutzen skip-verify
(wie bei NAS10 bereits konfiguriert, dort ueber HTTP ungenutzt).

### Endpoint-Schreibweise + skip-verify je Dienst

| Dienst | Endpoint-Feld | Schema noetig | skip-verify Flag |
|--------|---------------|---------------|------------------|
| Velero | s3Url | https:// | insecureSkipTLSVerify: "true" (vorhanden) |
| CNPG ObjectStore | endpointURL | https:// | (Barman nutzt endpointURL-Schema) |
| pg_dumpall | S3_ENDPOINT | https:// | boto3: verify via Schema |
| MariaDB | storage.s3.endpoint | OHNE Schema | tls.enabled: true + tls.caSecretRef ODER skip |
| Loki | loki.storage.s3.endpoint | https:// | insecure: false + s3 verify; ggf. http_config |
| Thanos | endpoint (im Secret) | OHNE Schema | insecure: false + http_config insecure_skip_verify |
| garage/odoo/idoit | rclone.conf endpoint | https:// | no_check_certificate ODER --no-check-certificate |
| Registry (Zot) | regionendpoint | OHNE Schema | secure: true + skipverify: true |

ACHTUNG: Die Schreibweise (mit/ohne Schema) und das skip-verify-Flag sind je
Dienst unterschiedlich. Pro Dienst einzeln verifizieren! Diese Tabelle ist
Arbeitsannahme - bei jedem Cutover-Schritt am echten Verhalten pruefen.


---

## 9. CA-Bundle-Muster (sauberes TLS) - dienstuebergreifend

Ab MariaDB wird sauberes TLS gefahren. Da QuObjects auf 8010 nur das Leaf-Zert
sendet (siehe Historie 11.06.), braucht JEDER strikt verifizierende Client das
Sectigo-Bundle (Intermediate DV R36 + Root R46) clientseitig. Empirisch
bestaetigt (CNPG-Test-Pod, openssl + awscli): System-Trust-Store allein
schlaegt fehl (Verify rc=21 / "unable to get local issuer certificate"),
mit Bundle rc=0 bzw. nur noch Auth-Fehler (= TLS ok).

### CA-Secret-Strategie (Stufe 1)

Secrets sind namespace-gebunden -> ein Bundle-Secret pro Namespace, von allen
Diensten des Namespace geteilt (Option 2). Inhalt ist ueberall identisch
(oeffentliche CA -> UNVERSCHLUESSELT, kein SOPS, als resources-Eintrag).

| Namespace | CA-Secret | genutzt von |
|-----------|-----------|-------------|
| databases | mariadb-s3-ca | MariaDB |
| databases | cnpg-s3-ca | CNPG (ObjectStore + pg_dumpall) |
| monitoring | eneg-s3-ca | Loki, spaeter Thanos |

OFFEN (spaetere Konsolidierung): mariadb-s3-ca + cnpg-s3-ca koennten zu einem
eneg-s3-ca im NS databases zusammengefuehrt werden. Ziel-Architektur fuer
zentrale Pflege bei Zert-Erneuerung (12.09.2026!): EINE Quell-Datei +
automatische Replikation in alle NS (Kyverno generate-Policy oder
trust-manager). Bewusst NACH der Migration, nicht waehrenddessen.

### CA-Einbindung je Client-Typ (verifiziert)

| Client (Dienst) | Feld/Mechanismus | Pfad |
|-----------------|------------------|------|
| MariaDB-Operator | tls.caSecretKeyRef | (Operator-intern) |
| Barman Go-SDK (CNPG ObjectStore) | spec.configuration.endpointCA {name,key} | (Plugin-intern) |
| awscli/botocore (pg_dumpall) | ENV AWS_CA_BUNDLE + Volume-Mount | /etc/ca/ca.crt |
| Loki Go-SDK | loki.storage.s3.http_config.ca_file + Volume-Mount | /etc/ca/ca.crt |

Kein Client macht AIA-Fetching -> Bundle MUSS clientseitig liegen.

### Multi-Env-Falle bei base-Konfiguration (Loki-Lehre, B1-Muster)

Wenn die S3-Config in einer von DEV/TEST/PROD GETEILTEN base liegt (z.B. Loki),
zieht eine base-Umstellung auf NAS20 sofort alle Envs mit. Sauberes Muster (B1):
- base = Ziel (NAS20 + ca_file-PFAD als String, inert solange env HTTP nutzt)
- DEV-Override = CA-Volume-Mount (Secret) + retention; nur hier, weil das Secret
  nur in DEV existiert (sonst Pod-Haenger in TEST/PROD)
- TEST/PROD-Override = DEFENSIV endpoint+insecure:true auf NAS10 zurueck,
  bis deren Migration ansteht (dann Rueckhol-Block entfernen)

### Cutover-Reihenfolge bei ENV-getriebenen Credentials (Loki-Lehre)

Erst *-secrets-App syncen + Cluster-Secret pruefen (kubectl get secret -o
jsonpath), DANN Dienst-Pod (neu)starten. Sonst laedt der Pod beim
Hard-Refresh-Restart alte ENV-Credentials (extraEnvFrom ist nicht live).
