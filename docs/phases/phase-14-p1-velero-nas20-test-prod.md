# P1-Nachtrag: Velero S3-Migration NAS10 -> NAS20 (TEST + PROD)

**Status:** VOLLSTAENDIG ABGESCHLOSSEN & VERIFIZIERT (21.07.2026).
Schliesst OF-2 endgueltig. Velero war der letzte aktive NAS10-Client -
alle Backup-/Storage-Dienste aller 3 Cluster laufen jetzt auf NAS20.
**Kontext:** Nachtrag zu P1 (Velero-Checksum-Fix 14.07.). Der NAS20-Umzug war
damals bewusst auf P4 verschoben, blieb dann als einziger Rest offen.
**Bearbeiter:** Daniel Henke (git/SOPS/Sync) + Claude (Dateien/kubectl-Verify).
**Vorlage:** DEV-Velero-Override (14a-cleanup-Muster).
**Scope:** Velero BackupStorageLocation `default` in TEST + PROD.

---

## 1. Ausgangslage (Scan 21.07.2026)

Vollstaendiger NAS10-Scan aller drei Cluster (Live-MCP + Repo-Grep `nas10.eneg.de`):
- CNPG (erp+shared), Thanos, Loki, MariaDB PhysicalBackup, rclone (garage/odoo/idoit)
  in DEV/TEST/PROD bereits auf NAS20.
- **Einziger aktiver Rueckstand:** Velero-BSL in TEST + PROD zeigte noch
  `http://nas10.eneg.de:8010` mit `insecureSkipTLSVerify: "true"`. DEV bereits NAS20.
- Verbleibende nas10-Repo-Fundstellen sonst nur: Doku-Historie, Templates/Kommentare,
  ueberschriebene base/-Legacy-Bloecke (CNPG nutzt ObjectStore-CRD statt inline
  barmanObjectStore; garage/odoo/idoit Env-Overlays ersetzen die base-ConfigMap),
  bewusst deferrte Zot/Trivy-DEV-Punkte. Alles funktional irrelevant.

---

## 2. Aenderungen je Umgebung (3 Dateien)

Identisch fuer TEST und PROD (nur Bucket/Schedule env-spezifisch belassen):

1. **`velero-secrets/velero-s3-ca.yaml` (NEU)** - oeffentliches CA-Bundle
   (Sectigo Intermediate DV R36 + Root R46), byte-identisch aus DEV kopiert.
   KEIN SOPS (oeffentliche Zertifikate). QuObjects (8010) sendet nur das
   Leaf-Zert -> Kette clientseitig noetig.
2. **`velero-secrets/kustomization.yaml`** - `resources:`-Block mit
   `- velero-s3-ca.yaml` ergaenzt (war vorher nur `generators:`).
3. **`velero/values-override.yaml`:**
   - `s3Url: http://nas10...` -> `https://nas20.eneg.de:8010`
   - `insecureSkipTLSVerify: "true"` ENTFERNT
   - `configuration.extraEnvVars: AWS_CA_BUNDLE=/etc/ca/ca.crt` ergaenzt
   - Top-Level `extraVolumes`/`extraVolumeMounts` (Secret velero-s3-ca -> /etc/ca)
   - `checksumAlgorithm: ""` BLEIBT (backend-unabhaengig)
   - Bucket (`k8s-{test,prod}-velero`), Schedule (TEST 30 3, PROD 15 1), TTL 336h,
     Resource-Limits UNVERAENDERT.

## 3. Ablauf (Variante A - getrennte Repos Windows/mgmt-10)

Grund: neue Dateien liegen auf Windows, Secret-Bearbeitung MUSS auf mgmt-10 (Age-Key).
Loesung: zwei getrennte Commits, kein Repo bearbeitet fremde Dateien.

1. **Windows:** 3 Dateien committen + pushen (OHNE enc.yaml).
2. **mgmt-10:** `git pull --rebase`; `velero-s3-credentials.enc.yaml` auf NAS20-Keys
   (s3-k8s-{env}) umstellen - truncation-sicher via Temp im secrets-Verzeichnis
   (decrypt -> temp -> edit -> encrypt zu .enc.new -> mv -> rm temp); als 2. Commit pushen.
3. **Windows:** `git pull --rebase`.
4. **ArgoCD:** `velero-secrets` zuerst (CA + Credentials), dann `velero` (values).
   Beide Apps in TEST+PROD Auto-Sync/selfHeal.
5. **Pod-Restart:** `kubectl rollout restart deployment/velero -n velero`
   (S3-Creds werden nur beim Start gelesen).

Reihenfolge global: TEST komplett -> verifiziert -> PROD identisch.

## 4. Verifikation (live, je Env)

| Check | TEST | PROD |
|-------|------|------|
| BSL s3Url | https://nas20.eneg.de:8010 | https://nas20.eneg.de:8010 |
| BSL insecureSkipTLSVerify | entfernt | entfernt |
| BSL Status | Available | Available |
| Secret velero-s3-ca | vorhanden | vorhanden |
| AWS_CA_BUNDLE / Mount | /etc/ca/ca.crt, /etc/ca | /etc/ca/ca.crt, /etc/ca |
| Test-Backup | Completed, 252/252, 0 Fehler | Completed, 1126/1126, 0 Fehler |

## 5. Learnings

1. **CA-Secret fehlte in TEST+PROD** (nur DEV hatte es) - musste neu angelegt
   werden (velero-secrets-App hatte vorher keinen resources-Block).
2. **Secret-Aktualisierung nach Pod-Start wirkt nicht automatisch:** Nach dem
   ersten Sync stand die BSL kurz auf `Unavailable`, weil der Velero-Pod die
   S3-Credentials beim Start cached und nicht zur Laufzeit neu liest. Fix:
   `kubectl rollout restart deployment/velero`. -> Bei Credential-Wechsel IMMER
   Pod-Restart einplanen.
3. **Kopia-Maintain-Jobs nach BSL-Wechsel:** Alte Maintain-Jobs laufen kurz in
   `backup repository is not ready: re-establish on BSL change` (Error). Das ist
   erwarteter Uebergangs-Nachlauf, KEIN Fehler - das Repo wird beim naechsten
   Backup je Namespace gegen NAS20 neu etabliert. Ggf. kurzzeitiger
   `VeleroKopiaMaintainPersistentFailures`-Alert (for: 2h), legt sich selbst.
4. **CA-Bundle byte-identisch kopieren** (Python shutil.copyfile statt Abtippen) -
   der base64-Block ist lang und fehleranfaellig; das Zert ist fuer alle Envs gleich.
