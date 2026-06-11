# Phase 14: S3-Migration NAS10 -> NAS20

**Status:** In Bearbeitung
**Beginn:** 11.06.2026
**Bearbeiter:** Daniel Henke
**Methode:** Clean Cutover ueber GitOps (kein Daten-Sync), Ausnahme: Registry

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
