# Phase 10: Velero Backup + i-doit rclone Backup

**Status:** Abgeschlossen (DEV + TEST + PROD)
**Beginn:** 14.04.2026
**DEV fertig:** 14.04.2026
**TEST fertig:** 14.04.2026
**PROD fertig:** 14.04.2026
**Voraussetzung:** Phase 7 (Monitoring) abgeschlossen, Phase 8c (PROD Rollout) abgeschlossen

---

## 1. Zielsetzung

Implementierung einer vollstaendigen Kubernetes-Backup-Loesung mit Velero fuer
Cluster-Ressourcen und Persistent Volumes sowie Nachruestung eines rclone-basierten
Backups fuer i-doit Upload-Daten.

### Kernziele

- **Velero:** Taegliches Backup aller Kubernetes-Ressourcen + PV-Daten auf NAS10 S3
- **i-doit rclone:** Taegliches Backup des i-doit Upload-Verzeichnisses auf NAS10 S3
- **Disaster Recovery:** Kompletter Namespace-Restore moeglich (Velero)
- **Point-in-Time Restore:** PV-Daten-Wiederherstellung auf Tagesbasis

### Was Velero ergaenzt (bestehende Backup-Luecken)

| Bereits gesichert | Durch | Neue Velero-Schicht |
|-------------------|-------|---------------------|
| PostgreSQL-Daten | CNPG WAL + Barman + pg_dumpall | K8s-Objekte (Cluster CRD, Secrets, ConfigMaps) |
| MariaDB-Daten | MariaDB Operator Physical Backup | K8s-Objekte (MariaDB CRD, Secrets) |
| Garage S3-Inhalte | rclone CronJob | K8s-Objekte (StatefulSet, ConfigMap) |
| Odoo Filestore | rclone CronJob | K8s-Objekte (Deployment, PVC, Secrets) |
| Manifeste | Git (Single Source of Truth) | Runtime-Zustand (PVC-Bindings, CRD-Status) |


---

## 2. Komponenten und Versionen

| Komponente | Helm Chart / Image | Version | Quelle |
|------------|-------------------|---------|--------|
| Velero | vmware-tanzu/velero | **11.3.2** (App v1.17.1) | vmware-tanzu Helm Repo |
| Velero Plugin for AWS | velero/velero-plugin-for-aws | **v1.13.0** | Docker Hub |
| rclone (i-doit Backup) | rclone/rclone | **1.73.1** | Docker Hub (gleich wie Odoo/Garage) |

**Versionen abgestimmt am 14.04.2026.**
Velero v1.18 ist noch RC (v1.18.0-rc.1) — wir nutzen die stabile v1.17.1.

---

## 3. Architektur-Uebersicht

### Velero

```
+------------------------------------------------------------------+
|                      velero Namespace                              |
|                                                                    |
|  +------------------+    +------------------+                      |
|  | Velero Server    |    | node-agent       |                      |
|  | (Deployment)     |    | (DaemonSet,      |                      |
|  | Schedules,       |    |  1 Pod/Node)     |                      |
|  | Backups,         |    | fs-backup via    |                      |
|  | Restores         |    | kopia            |                      |
|  +--------+---------+    +--------+---------+                      |
|           |                       |                                |
|           v                       v                                |
|  +--------------------------------------------------+             |
|  | BackupStorageLocation (BSL)                       |             |
|  | Provider: aws (S3-kompatibel)                     |             |
|  | Bucket: k8s-{env}-velero                          |             |
|  | Endpoint: http://nas10.eneg.de:8010               |             |
|  +--------------------------------------------------+             |
+------------------------------------------------------------------+
```

### i-doit rclone Backup

```
+------------------------------------------------------------------+
|                      idoit Namespace                               |
|                                                                    |
|  +------------------+    +------------------+                      |
|  | idoit-backup     |    | idoit-data PVC   |                      |
|  | CronJob (rclone) |--->| subPath: upload   |                      |
|  | 05:30 taeglich   |    | subPath: src      |                      |
|  +--------+---------+    +------------------+                      |
|           |                                                        |
|           v                                                        |
|  +--------------------------------------------------+             |
|  | NAS10 S3: k8s-{env}-idoit                         |             |
|  | /upload/   (Uploads, Dokumente)                   |             |
|  | /src/      (config.inc.php, Konfiguration)        |             |
|  | /_backups/ (geloeschte/geaenderte Dateien, 32d)   |             |
|  +--------------------------------------------------+             |
+------------------------------------------------------------------+
```


---

## 4. Backup-Zeitplan (Gestaffelt, alle Zeiten Europe/Berlin)

Umgebungen zeitlich gestaffelt um NAS10 S3 Rate-Limiting zu vermeiden.
PROD hat Prioritaet (fruehestes Fenster).

### PROD (00:01 – 02:00)

| Zeit | Backup | Tool |
|------|--------|------|
| 00:01 | MariaDB Physical Backup | MariaDB Operator |
| 00:15 | CNPG Barman shared (Physical) | CNPG/Barman |
| 00:20 | CNPG Barman erp (Physical) | CNPG/Barman |
| 00:30 | CNPG pg_dumpall (cnpg-shared) | CronJob |
| 00:45 | CNPG pg_dumpall (cnpg-erp) | CronJob |
| 01:00 | Garage S3 rclone | CronJob |
| 01:15 | Velero (K8s-Objekte + PV-Daten) | Velero Schedule |
| 01:45 | Odoo Filestore rclone | CronJob |
| 02:00 | i-doit Upload+src rclone | CronJob |

### TEST (02:15 – 04:15)

| Zeit | Backup | Tool |
|------|--------|------|
| 02:15 | MariaDB Physical Backup | MariaDB Operator |
| 02:30 | CNPG Barman shared (Physical) | CNPG/Barman |
| 02:35 | CNPG Barman erp (Physical) | CNPG/Barman |
| 02:45 | CNPG pg_dumpall (cnpg-shared) | CronJob |
| 03:00 | CNPG pg_dumpall (cnpg-erp) | CronJob |
| 03:15 | Garage S3 rclone | CronJob |
| 03:30 | Velero (K8s-Objekte + PV-Daten) | Velero Schedule |
| 04:00 | Odoo Filestore rclone | CronJob |
| 04:15 | i-doit Upload+src rclone | CronJob |

### DEV (04:30 – 06:30)

| Zeit | Backup | Tool |
|------|--------|------|
| 04:30 | MariaDB Physical Backup | MariaDB Operator |
| 04:45 | CNPG Barman shared (Physical) | CNPG/Barman |
| 04:50 | CNPG Barman erp (Physical) | CNPG/Barman |
| 05:00 | CNPG pg_dumpall (cnpg-shared) | CronJob |
| 05:15 | CNPG pg_dumpall (cnpg-erp) | CronJob |
| 05:30 | Garage S3 rclone | CronJob |
| 05:45 | Velero (K8s-Objekte + PV-Daten) | Velero Schedule |
| 06:15 | Odoo Filestore rclone | CronJob |
| 06:30 | i-doit Upload+src rclone | CronJob |

Alle Backups → NAS10 S3 (nas10.eneg.de:8010, HTTP).
CNPG WAL-Archivierung laeuft zusaetzlich kontinuierlich (alle Umgebungen).


---

## 5. S3 Buckets auf NAS10

### Neue Buckets (Phase 10)

| Bucket | Inhalt | Retention |
|--------|--------|-----------|
| `k8s-dev-velero` | Velero Backups (K8s-Objekte + PV-Daten) | 14 Tage (TTL) |
| `k8s-test-velero` | Velero Backups (K8s-Objekte + PV-Daten) | 14 Tage (TTL) |
| `k8s-prod-velero` | Velero Backups (K8s-Objekte + PV-Daten) | 14 Tage (TTL) |
| `k8s-dev-idoit` | i-doit Upload + src Backup | 32 Tage (rclone Cleanup) |
| `k8s-test-idoit` | i-doit Upload + src Backup | 32 Tage (rclone Cleanup) |
| `k8s-prod-idoit` | i-doit Upload + src Backup | 32 Tage (rclone Cleanup) |

**Status:** Alle Buckets auf NAS10 angelegt (14.04.2026).


---

## 6. Velero-Konfiguration (Details)

### Backup-Umfang

| Einstellung | Wert | Beschreibung |
|-------------|------|--------------|
| `defaultVolumesToFsBackup` | `true` | Alle PVs werden per fs-backup (kopia) gesichert |
| `deployNodeAgent` | `true` | DaemonSet auf jedem Node fuer PV-Zugriff |
| `schedule` | `0 4 30 * * *` (04:30 Europe/Berlin) | Taeglich |
| `ttl` | `336h0m0s` (14 Tage) | Automatische Bereinigung |
| `s3ForcePathStyle` | `true` | Pflicht fuer NAS10 QuObjects |
| `insecureSkipTLSVerify` | `true` | NAS10 nutzt HTTP (Port 8010) |

### Velero Schedule (wird per Helm Values erstellt)

```yaml
schedules:
  daily-backup:
    disabled: false
    schedule: "30 4 * * *"
    useOwnerReferencesInBackup: false
    template:
      ttl: "336h0m0s"
      storageLocation: default
      defaultVolumesToFsBackup: true
      includedNamespaces:
        - "*"
```

### Ressourcen-Anforderungen

| Komponente | CPU Request | Memory Request | CPU Limit | Memory Limit |
|------------|-------------|----------------|-----------|--------------|
| Velero Server | 100m | 128Mi | 500m | 512Mi |
| node-agent (pro Node) | 100m | 128Mi | 500m | 512Mi |


---

## 7. i-doit rclone Backup (Details)

### Backup-Umfang

| Quelle (PVC subPath) | Ziel auf NAS10 | Beschreibung |
|-----------------------|-----------------|--------------|
| `idoit-data` subPath `upload` | `k8s-{env}-idoit/upload/` | Benutzer-Uploads, Dokumente |
| `idoit-data` subPath `src` | `k8s-{env}-idoit/src/` | config.inc.php, Konfiguration |

**Nicht gesichert:** `temp` (temporaere Dateien), `log` (Logs — werden ueber Loki aggregiert).

### Pattern

Identisch zum Odoo Filestore Backup (`environments/dev/apps/odoo/backup/`):
- ConfigMap mit `rclone.conf` + `backup.sh`
- CronJob mit PVC-Mount (readOnly) + NAS10 S3 Credentials aus SOPS Secret
- Pod-Affinity zum idoit-Pod (gleicher Node fuer schnellen PVC-Zugriff)
- rclone `sync` mit `--backup-dir` fuer geloeschte/geaenderte Dateien
- Cleanup aelterer Backups (>32 Tage)


---

## 8. Repository-Struktur (Ziel-Zustand)

```
kubernetes/
├── base/velero/
│   └── values.yaml                          # Helm Base-Values (generisch)
│
└── environments/dev/
    ├── velero/
    │   └── values-override.yaml             # DEV: S3-Endpoint, Bucket, Schedule
    ├── velero-secrets/
    │   ├── velero-s3-credentials.yaml.template
    │   ├── velero-s3-credentials.enc.yaml   # SOPS-verschluesselt
    │   ├── kustomization.yaml
    │   └── secret-generator.yaml
    ├── apps/idoit/backup/
    │   ├── cronjob.yaml                     # ConfigMap + CronJob (rclone)
    │   └── secrets/
    │       ├── idoit-backup-credentials.yaml.template
    │       ├── idoit-backup-credentials.enc.yaml  # SOPS-verschluesselt
    │       ├── kustomization.yaml
    │       └── secret-generator.yaml
    └── infrastructure/
        ├── velero-app.yaml                  # ArgoCD App (Helm Multi-Source)
        ├── velero-secrets-app.yaml          # ArgoCD App (KSOPS)
        ├── idoit-backup-app.yaml            # ArgoCD App (Kustomize)
        └── idoit-backup-secrets-app.yaml    # ArgoCD App (KSOPS)
```


---

## 9. Implementierungsplan (Schritte)

### Deployment-Reihenfolge: DEV zuerst, dann TEST, dann PROD

### Schritt 1: Vorbereitung

**1a. S3 Buckets auf NAS10 anlegen** ✅
- `k8s-dev-velero`, `k8s-test-velero`, `k8s-prod-velero`
- `k8s-dev-idoit`, `k8s-test-idoit`, `k8s-prod-idoit`

**1b. Helm Repo auf k8s-mgmt-10 hinzufuegen**
```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update
helm search repo vmware-tanzu/velero --versions | head -5
```

### Schritt 2: Velero Base + DEV Overlay erstellen

**Dateien erstellen (via Desktop Commander):**
- `kubernetes/base/velero/values.yaml`
- `kubernetes/environments/dev/velero/values-override.yaml`


### Schritt 3: Velero Secrets erstellen

**Dateien erstellen (via Desktop Commander):**
- `kubernetes/environments/dev/velero-secrets/velero-s3-credentials.yaml.template`
- `kubernetes/environments/dev/velero-secrets/kustomization.yaml`
- `kubernetes/environments/dev/velero-secrets/secret-generator.yaml`

**Manuelle Schritte (Daniel auf k8s-mgmt-10):**
```bash
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/dev/velero-secrets
# Template ausfuellen und verschluesseln:
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     velero-s3-credentials.yaml.template > velero-s3-credentials.enc.yaml
```

### Schritt 4: ArgoCD Apps fuer Velero erstellen

**Dateien erstellen (via Desktop Commander):**
- `kubernetes/environments/dev/infrastructure/velero-app.yaml`
- `kubernetes/environments/dev/infrastructure/velero-secrets-app.yaml`

### Schritt 5: Velero DEV deployen und verifizieren

**Commit + Push (Daniel):**
```bash
cd ~/git/eneg-k8s-infrastructure-v2
git add kubernetes/base/velero/ kubernetes/environments/dev/velero/ \
        kubernetes/environments/dev/velero-secrets/ \
        kubernetes/environments/dev/infrastructure/velero-app.yaml \
        kubernetes/environments/dev/infrastructure/velero-secrets-app.yaml
git commit -m "Phase 10: Velero Backup DEV - Helm Chart 11.3.2, v1.17.1"
git push
```


**Verifikation Velero (k8s-mgmt-10):**
```bash
# Pods pruefen
kubectl get pods -n velero --context k8s-dev

# BackupStorageLocation Status
kubectl get backupstoragelocation -n velero --context k8s-dev

# Manuelles Test-Backup ausloesen
kubectl exec -n velero deploy/velero --context k8s-dev -- \
  velero backup create test-manual-01 --wait

# Backup-Status pruefen
kubectl exec -n velero deploy/velero --context k8s-dev -- \
  velero backup describe test-manual-01

# Schedule pruefen
kubectl exec -n velero deploy/velero --context k8s-dev -- \
  velero schedule get
```

**Erwartetes Ergebnis:**
- [ ] Velero Deployment Running (1 Pod)
- [ ] node-agent DaemonSet Running (3 Pods, einer pro Node)
- [ ] BackupStorageLocation Phase: Available
- [ ] Test-Backup Phase: Completed
- [ ] Schedule "daily-backup" erstellt

### Schritt 6: i-doit rclone Backup erstellen

**Dateien erstellen (via Desktop Commander):**
- `kubernetes/environments/dev/apps/idoit/backup/cronjob.yaml`
- `kubernetes/environments/dev/apps/idoit/backup/secrets/idoit-backup-credentials.yaml.template`
- `kubernetes/environments/dev/apps/idoit/backup/secrets/kustomization.yaml`
- `kubernetes/environments/dev/apps/idoit/backup/secrets/secret-generator.yaml`


### Schritt 7: ArgoCD Apps fuer i-doit Backup erstellen

**Dateien erstellen (via Desktop Commander):**
- `kubernetes/environments/dev/infrastructure/idoit-backup-app.yaml`
- `kubernetes/environments/dev/infrastructure/idoit-backup-secrets-app.yaml`

### Schritt 8: i-doit Backup Secrets verschluesseln + deployen

**Manuelle Schritte (Daniel auf k8s-mgmt-10):**
```bash
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/dev/apps/idoit/backup/secrets
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     idoit-backup-credentials.yaml.template > idoit-backup-credentials.enc.yaml
```

**Commit + Push (Daniel):**
```bash
cd ~/git/eneg-k8s-infrastructure-v2
git add kubernetes/environments/dev/apps/idoit/backup/ \
        kubernetes/environments/dev/infrastructure/idoit-backup-app.yaml \
        kubernetes/environments/dev/infrastructure/idoit-backup-secrets-app.yaml
git commit -m "Phase 10: i-doit rclone Backup DEV - Upload + src auf NAS10 S3"
git push
```

### Schritt 9: i-doit Backup DEV verifizieren

**Verifikation (k8s-mgmt-10):**
```bash
# CronJob pruefen
kubectl get cronjob -n idoit --context k8s-dev

# Manuellen Testlauf ausloesen
kubectl create job --from=cronjob/idoit-backup idoit-backup-test-01 -n idoit --context k8s-dev

# Job-Logs pruefen
kubectl logs job/idoit-backup-test-01 -n idoit --context k8s-dev
```

**Erwartetes Ergebnis:**
- [ ] CronJob "idoit-backup" erstellt (Schedule 05:30 Europe/Berlin)
- [ ] Test-Job Phase: Succeeded
- [ ] Dateien auf NAS10 in `k8s-dev-idoit/upload/` und `k8s-dev-idoit/src/` sichtbar


### Schritt 10: Dokumentation aktualisieren

- Projektplanung v2.15 (Backup-Strategie-Tabelle, Layer 6, Phase 10 Status)
- Phase-10 Dokument mit Ergebnissen und Learnings aktualisieren

### Schritt 11: TEST + PROD Rollout

Nach erfolgreicher DEV-Verifikation:
1. Environment-Overlay-Dateien fuer TEST erstellen
2. SOPS Secrets fuer TEST verschluesseln
3. Commit/Push → Verifizieren
4. Environment-Overlay-Dateien fuer PROD + base/ erstellen
5. SOPS Secrets fuer PROD verschluesseln
6. Commit/Push → Verifizieren

**Reihenfolge:** DEV → Commit → Verify → TEST → Commit → Verify → PROD

---

## 10. Restore-Verfahren

### Velero Restore (Namespace-Wiederherstellung)

```bash
# Verfuegbare Backups auflisten
kubectl exec -n velero deploy/velero --context k8s-{env} -- \
  velero backup get

# Einzelnen Namespace wiederherstellen
kubectl exec -n velero deploy/velero --context k8s-{env} -- \
  velero restore create --from-backup <BACKUP_NAME> \
  --include-namespaces <NAMESPACE> --wait

# Restore-Status pruefen
kubectl exec -n velero deploy/velero --context k8s-{env} -- \
  velero restore describe <RESTORE_NAME> --details
```


### i-doit rclone Restore

```bash
# Auf k8s-mgmt-10: rclone Container mit PVC-Zugriff starten
kubectl run rclone-restore --rm -it \
  --image=rclone/rclone:1.73.1 \
  --overrides='{ ... }' \  # PVC-Mount + NAS10 Credentials
  -n idoit --context k8s-{env} -- \
  rclone sync nas10:k8s-{env}-idoit/upload/ /restore/upload/ \
    --config /config/rclone.conf
```

Detailliertes Restore-Verfahren wird nach DEV-Implementierung als Runbook erstellt.

---

## 11. ArgoCD Apps (Neue Apps pro Environment)

| Nr | App-Name | Typ | Sync-Wave | Pfad |
|----|----------|-----|-----------|------|
| 1 | velero-secrets | Kustomize (KSOPS) | 4 | environments/{env}/velero-secrets/ |
| 2 | velero | Helm (Multi-Source) | 5 | base/velero/ + environments/{env}/velero/ |
| 3 | idoit-backup-secrets | Kustomize (KSOPS) | 7 | environments/{env}/apps/idoit/backup/secrets/ |
| 4 | idoit-backup | Kustomize | 9 | environments/{env}/apps/idoit/backup/ |

**Gesamt: 4 neue ArgoCD Apps pro Environment**

---

## 12. Geschaetzter Aufwand

| Schritt | Beschreibung | Geschaetzter Aufwand |
|---------|--------------|----------------------|
| 1 | Vorbereitung (S3 Buckets, Helm Repo) | 30min (Daniel) |
| 2-4 | Velero Dateien erstellen + Secrets | 1-2h |
| 5 | Velero DEV deployen + verifizieren | 1h |
| 6-8 | i-doit Backup Dateien + Secrets + Deploy | 1h |
| 9 | i-doit Backup verifizieren | 30min |
| 10 | Dokumentation | 30min |
| 11 | TEST + PROD Rollout (je Env) | 1h x2 |
| **Gesamt** | | **~7-8h** |


---

## 13. Abhaengigkeiten und Voraussetzungen

| Voraussetzung | Status | Verantwortlich |
|---------------|--------|----------------|
| S3 Buckets auf NAS10 (velero + idoit) | ✅ Erledigt (alle Envs) | Daniel |
| Phase 7 Monitoring abgeschlossen | ✅ | - |
| Phase 8c PROD Rollout abgeschlossen | ✅ | - |
| Helm Repo vmware-tanzu auf k8s-mgmt-10 | Offen | Daniel (CLI) |
| Velero Versionen abgestimmt | ✅ (v1.17.1, Chart 11.3.2) | - |

---

## 14. Risiken und Mitigationen

| Risiko | Mitigation |
|--------|------------|
| NAS10 S3 Rate-Limiting bei grossen PV-Backups | fs-backup Concurrency begrenzen, Transfers limitieren |
| Velero node-agent hoher Memory bei grossen PVs | Memory-Limits setzen, Monitoring-Alert bei OOM |
| NAS10 HTTP (kein HTTPS) fuer Velero BSL | Internes Netzwerk, kein externer Zugriff |
| Velero CRDs gross (aehnlich ArgoCD) | ServerSideApply in ArgoCD App |
| Backup-Fenster kollidiert mit anderen Jobs | Zeitlich versetzt (04:30 statt 04:00) |

---

## 15. Offene Entscheidungen

- [x] Velero-Version: v1.17.1 (Helm Chart 11.3.2)
- [x] PV-Backup: Ja, fuer alle PVs (`defaultVolumesToFsBackup: true`)
- [x] Backup-Ziel: NAS10 S3 (HTTP, Port 8010)
- [x] Bucket-Namen: `k8s-{env}-velero`, `k8s-{env}-idoit`
- [x] i-doit Backup-Umfang: `upload` + `src` subPaths
- [ ] Velero CLI auf k8s-mgmt-10 installieren (optional, fuer einfacheres Restore)

---

## 16. Learnings (DEV)

1. **Velero Helm Chart Name-Prefix:** Der Schedule heisst `velero-daily-backup` (nicht `daily-backup`).
   Das Helm Chart setzt automatisch den Release-Namen als Prefix.

2. **Manuelles Schedule-Backup:** `velero backup create --from-schedule velero-daily-backup --wait`
   ist besser als manuelles Backup mit Flags, da exakt dieselben Parameter wie der Schedule
   verwendet werden (TTL, includedNamespaces, defaultVolumesToFsBackup).

3. **PV-Backup via kopia funktioniert Out-of-the-Box** mit `defaultVolumesToFsBackup: true`.
   Keine zusaetzliche Konfiguration fuer Longhorn PVCs noetig. node-agent DaemonSet
   greift direkt auf die PV-Daten auf dem jeweiligen Node zu.

4. **rclone fsnotify Warnung** (`failed to create fsnotify watcher: too many open files`)
   ist unkritisch — tritt beim Aufraemen des rclone-Prozesses auf, nicht beim Backup selbst.
   Kein Einfluss auf Backup-Integritaet.

5. **PVC subPath-Mounting in CronJob:** Bei einem PVC mit mehreren subPaths (wie idoit-data)
   wird das Volume einmal deklariert und in den volumeMounts mehrfach mit verschiedenen
   subPaths gemountet. Nicht mehrere Volume-Eintraege fuer dieselbe PVC verwenden.

6. **MariaDB PhysicalBackup `schedule.cron` ist immutable.** Der MariaDB Operator
   erlaubt keine Aenderung des Cron-Schedules ueber ein Update. Die PhysicalBackup-Ressource
   muss geloescht werden (`kubectl delete physicalbackup mariadb-galera-backup -n databases`),
   damit ArgoCD sie mit dem neuen Schedule neu erstellt.

7. **Backup-Zeitplaene umgebungsweise staffeln.** Alle Umgebungen gleichzeitig auf NAS10 S3
   schreiben zu lassen fuehrt zu Rate-Limiting (bekannt von CNPG). Loesung: PROD 00:01,
   TEST 02:15, DEV 04:30 — jeweils ~2h15min Fenster ohne Ueberlappung.

---

## 17. DEV Implementierung — Ergebnisse (14.04.2026)

### Deployed Components

| Komponente | Version | Pods | Status |
|------------|---------|------|--------|
| Velero Server | v1.17.1 (Chart 11.3.2) | 1 | ✅ Running |
| node-agent DaemonSet | v1.17.1 | 3 (je 1/Node) | ✅ Running |
| velero-plugin-for-aws | v1.13.0 | (init-container) | ✅ |
| i-doit Backup CronJob | rclone 1.73.1 | (bei Ausfuehrung) | ✅ Active |

### ArgoCD Apps (4 neue Apps)

| App | Typ | Status |
|-----|-----|--------|
| velero-secrets | Kustomize (KSOPS) | ✅ Synced+Healthy |
| velero | Helm (Multi-Source) | ✅ Synced+Healthy |
| idoit-backup-secrets | Kustomize (KSOPS) | ✅ Synced+Healthy |
| idoit-backup | Kustomize | ✅ Synced+Healthy |

### Velero Status

| Pruefpunkt | Ergebnis |
|------------|----------|
| BackupStorageLocation `default` | Available (NAS10 S3 OK) |
| Schedule `velero-daily-backup` | Enabled (30 4 * * *, TTL 336h) |
| Test-Backup headlamp (ohne PV) | Completed, 14 Objekte, 2s |
| Test-Backup idoit (mit PV) | Completed, 23 Objekte + idoit-data kopia, 13s |
| Full Backup (alle Namespaces + PVs) | Completed (via --from-schedule) |

### i-doit Backup Status

| Pruefpunkt | Ergebnis |
|------------|----------|
| CronJob `idoit-backup` | Active, Schedule 05:30 Europe/Berlin |
| Test-Lauf | Complete, 18s, src 23.7 MiB auf NAS10 |
| Bucket `k8s-dev-idoit` | Daten in /upload/ und /src/ vorhanden |

---

## 18. TEST Implementierung — Ergebnisse (14.04.2026)

Identische Konfiguration wie DEV, Bucket-Namen auf `k8s-test-*` angepasst.

| Pruefpunkt | Ergebnis |
|------------|----------|
| 4 ArgoCD Apps (velero, velero-secrets, idoit-backup, idoit-backup-secrets) | Synced+Healthy |
| Velero Server + node-agent (3/3) | Running |
| BSL `default` | Available |
| Schedule `velero-daily-backup` | Enabled |
| CronJob `idoit-backup` | Active |
| Full Backup (via --from-schedule) | Completed |
| i-doit rclone Test-Lauf | Completed |

---

## 19. PROD Implementierung — Ergebnisse (14.04.2026)

Identische Konfiguration wie DEV/TEST, Bucket-Namen auf `k8s-prod-*` angepasst.

| Pruefpunkt | Ergebnis |
|------------|----------|
| 4 ArgoCD Apps (velero, velero-secrets, idoit-backup, idoit-backup-secrets) | Synced+Healthy |
| Velero Server + node-agent (3/3) | Running |
| BSL `default` | Available |
| Schedule `velero-daily-backup` | Enabled |
| CronJob `idoit-backup` | Active |
| Full Backup (via --from-schedule) | Completed |
| i-doit rclone Test-Lauf | Completed |

---

*Erstellt: 14.04.2026*
*Letzte Aktualisierung: 14.04.2026 (DEV+TEST+PROD abgeschlossen, Zeitplaene gestaffelt)*

