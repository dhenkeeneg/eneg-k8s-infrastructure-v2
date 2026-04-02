# CNPG Barman Cloud Plugin Migration — Konsolidierte Anleitung v1

**Erstellt:** 02.04.2026
**Basiert auf:** `cnpg-barman-cloud-plugin-migration.md` (30.03.2026) und `cnpg-barman-cloud-plugin-migration_20260315.md` (15.03.2026)
**Status:** Ausstehend — vor Upgrade auf CNPG Operator >= 1.30.0 durchfuehren
**Geschaetzter Aufwand:** 1–2 Stunden
**Risiko:** Niedrig (bestehende Backups bleiben kompatibel)

---

## 1. Hintergrund

Die native (in-tree) Unterstuetzung fuer Barman Cloud Backups in CloudNativePG ist seit
Version 1.26.0 deprecated und wird in **CNPG 1.30.0 vollstaendig entfernt**.

Unsere aktuelle Installation nutzt CNPG Operator v1.28.1 (Helm Chart v0.27.1).
Die Migration muss **vor dem Upgrade auf 1.30.0** erfolgen.

Das externe Plugin `barman-cloud.cloudnative-pg.io` ersetzt die in-tree Barman-Funktionalitaet
und wird als offizieller Nachfolger von der CNPG-Community (CNCF Sandbox) gepflegt.

**Aktuelle Plugin-Version (Stand 02.04.2026):** v0.11.0
- Helm Chart verfuegbar: `cloudnative-pg/plugin-barman-cloud`
- **Wichtig ab v0.11.0:** RBAC-Ressourcennamen wurden mit `barman-plugin-` Prefix versehen.
  Bei Updates von aelteren Versionen den "Resource Name Migration Guide" beachten.

---

## 2. Betroffene Cluster und Umgebungen

| Cluster | Namespace | Umgebungen | Backup-Ziel |
|---------|-----------|------------|-------------|
| cnpg-shared | databases | DEV, TEST, PROD | nas10.eneg.de:8010 (S3/HTTP) |
| cnpg-erp | databases | DEV, TEST, PROD | nas10.eneg.de:8010 (S3/HTTP) |

### Aktuelle Konfiguration (zu migrieren)

Betroffene Manifeste:
- `kubernetes/base/cloudnative-pg/cluster/cnpg-shared.yaml`
- `kubernetes/base/cloudnative-pg/cluster/cnpg-erp.yaml`

Beide nutzen aktuell `spec.backup.barmanObjectStore`:
```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-dev-postgres-wal/<cluster>/
      endpointURL: http://nas10.eneg.de:8010
      s3Credentials:
        accessKeyId:
          name: cnpg-s3-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-s3-credentials
          key: SECRET_ACCESS_KEY
    retentionPolicy: "7d"
```

---

## 3. Voraussetzungen

- [ ] CNPG Operator >= 1.27.0 (empfohlen fuer besseres Error-Handling; aktuell: 1.28.1 ✓)
- [ ] cert-manager aktiv (fuer TLS zwischen Plugin und Operator; bereits installiert ✓)
- [ ] Bestehende Backups auf NAS10 verifiziert und funktionsfaehig
- [ ] Barman Cloud Plugin v0.11.0 (oder aktuellste stable Version zum Zeitpunkt der Migration)

---

## 4. Migrationsschritte

### Schritt 1: Barman Cloud Plugin installieren

Das Plugin wird als Deployment im `cnpg-system` Namespace installiert.

```bash
# Aktuelle stable Version pruefen:
# https://github.com/cloudnative-pg/plugin-barman-cloud/releases

# Installation per Manifest (Beispiel fuer v0.11.0):
kubectl apply --server-side -f \
  https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.11.0/manifest.yaml

# Pruefen ob Plugin laeuft:
kubectl rollout status deployment -n cnpg-system barman-cloud
```

**Hinweis:** Version vor Installation mit der aktuellen stable Version abgleichen!
Alternativ ist ein Helm Chart verfuegbar (`cloudnative-pg/plugin-barman-cloud`).

### Schritt 2: ObjectStore CRDs erstellen

Fuer jeden CNPG Cluster wird ein separates `ObjectStore`-CRD erstellt.
Die Konfiguration wird 1:1 aus `spec.backup.barmanObjectStore` uebernommen.

**Neue Datei:** `kubernetes/base/cloudnative-pg/backup/objectstore-shared.yaml`
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: cnpg-shared-objectstore
  namespace: databases
spec:
  configuration:
    destinationPath: s3://k8s-dev-postgres-wal/cnpg-shared/
    endpointURL: http://nas10.eneg.de:8010
    s3Credentials:
      accessKeyId:
        name: cnpg-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: cnpg-s3-credentials
        key: SECRET_ACCESS_KEY
```

**Neue Datei:** `kubernetes/base/cloudnative-pg/backup/objectstore-erp.yaml`
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: cnpg-erp-objectstore
  namespace: databases
spec:
  configuration:
    destinationPath: s3://k8s-dev-postgres-wal/cnpg-erp/
    endpointURL: http://nas10.eneg.de:8010
    s3Credentials:
      accessKeyId:
        name: cnpg-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: cnpg-s3-credentials
        key: SECRET_ACCESS_KEY
```

**Hinweis:** `destinationPath` muss pro Umgebung in den Kustomize-Overlays angepasst werden
(DEV: `k8s-dev-`, TEST: `k8s-test-`, PROD: `k8s-prod-`).

### Schritt 3: Cluster-Manifeste anpassen (atomare Aenderung)

In **einem einzigen Commit** muessen folgende Aenderungen vorgenommen werden:

1. `spec.backup.barmanObjectStore` Sektion **entfernen**
2. `spec.plugins` Sektion **hinzufuegen**
3. `retentionPolicy` in die ObjectStore-Konfiguration verschieben

**cnpg-shared.yaml — Entfernen (gesamte backup-Sektion):**
```yaml
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-dev-postgres-wal/cnpg-shared/
      endpointURL: http://nas10.eneg.de:8010
      s3Credentials:
        accessKeyId:
          name: cnpg-s3-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-s3-credentials
          key: SECRET_ACCESS_KEY
    retentionPolicy: "7d"
```

**cnpg-shared.yaml — Hinzufuegen:**
```yaml
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: cnpg-shared-objectstore
```

Analog fuer `cnpg-erp.yaml` mit `barmanObjectName: cnpg-erp-objectstore`.

### Schritt 4: ScheduledBackup-Ressourcen anpassen

Falls vorhanden, muessen ScheduledBackup-Ressourcen auf die Plugin-Methode umgestellt werden:

```yaml
# Vorher (in-tree):
spec:
  method: barmanObjectStore
  cluster:
    name: cnpg-shared

# Nachher (Plugin-basiert):
spec:
  method: plugin
  cluster:
    name: cnpg-shared
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

### Schritt 5: Container-Image aktualisieren (optional, empfohlen)

Nach der Migration kann das PostgreSQL-Image von `system` auf `standard` gewechselt werden,
da Barman Cloud nicht mehr im Container integriert sein muss:

```yaml
# Vorher (in-tree, benoetigt Barman im Image):
imageName: ghcr.io/cloudnative-pg/postgresql:17.8-system-bookworm

# Nachher (Plugin-basiert, leichteres Image):
imageName: ghcr.io/cloudnative-pg/postgresql:17.x-standard-bookworm
```

**Hinweis:** Die exakte Image-Version zum Zeitpunkt der Migration pruefen!
Die `system`-Images werden entfernt, wenn der in-core Barman Cloud Support entfaellt.

### Schritt 6: Deployment und Verifikation

```bash
# 1. Alle Aenderungen committen und pushen
git add kubernetes/base/cloudnative-pg/
git commit -m "feat(cnpg): migrate from in-tree barman cloud to barman cloud plugin"
git push

# 2. ArgoCD Sync abwarten oder manuell triggern

# 3. Plugin-Sidecar pruefen (laeuft als Container im Primary-Pod)
kubectl logs -n databases cnpg-shared-1 -c plugin-barman-cloud --tail=20
kubectl logs -n databases cnpg-erp-3 -c plugin-barman-cloud --tail=20

# 4. WAL-Archivierung pruefen
kubectl logs -n databases cnpg-shared-1 -c plugin-barman-cloud | grep "Archived WAL"
kubectl logs -n databases cnpg-erp-3 -c plugin-barman-cloud | grep "Archived WAL"

# 5. Manuelles Backup testen
kubectl cnpg backup -n databases cnpg-shared \
  --method=plugin \
  --plugin-name=barman-cloud.cloudnative-pg.io

kubectl cnpg backup -n databases cnpg-erp \
  --method=plugin \
  --plugin-name=barman-cloud.cloudnative-pg.io

# 6. ObjectStore-Status pruefen
kubectl get objectstores.barmancloud.cnpg.io -n databases

# 7. Cluster-Status pruefen
kubectl get cluster -n databases -o jsonpath='{.items[*].status.conditions}'
```

---

## 5. Rollback-Plan

Falls Probleme auftreten:
1. `spec.plugins` aus den Cluster-Manifesten entfernen
2. `spec.backup.barmanObjectStore` wiederherstellen
3. Commit und Push — ArgoCD synchronisiert zurueck auf in-tree Backup

Die ObjectStore-CRDs koennen bestehen bleiben — sie haben keine Auswirkung,
wenn sie nicht referenziert werden.

**Rollback ist nur moeglich solange CNPG Operator < 1.30.0!**

---

## 6. Migrationsstrategie ueber Umgebungen

**Reihenfolge:** DEV → TEST → PROD

Jede Umgebung einzeln migrieren und verifizieren, bevor die naechste folgt.
Pro Umgebung muessen die `destinationPath`-Werte in den ObjectStore-CRDs
ueber Kustomize-Overlays angepasst werden:

| Umgebung | Bucket-Prefix | Beispiel destinationPath |
|----------|---------------|--------------------------|
| DEV | `k8s-dev-` | `s3://k8s-dev-postgres-wal/cnpg-shared/` |
| TEST | `k8s-test-` | `s3://k8s-test-postgres-wal/cnpg-shared/` |
| PROD | `k8s-prod-` | `s3://k8s-prod-postgres-wal/cnpg-shared/` |

---

## 7. Betroffene Dateien (Zusammenfassung)

| Datei | Aenderung |
|-------|-----------|
| `kubernetes/base/cloudnative-pg/backup/objectstore-shared.yaml` | **NEU:** ObjectStore CRD fuer cnpg-shared |
| `kubernetes/base/cloudnative-pg/backup/objectstore-erp.yaml` | **NEU:** ObjectStore CRD fuer cnpg-erp |
| `kubernetes/base/cloudnative-pg/cluster/cnpg-shared.yaml` | **AENDERN:** `barmanObjectStore` → `plugins` |
| `kubernetes/base/cloudnative-pg/cluster/cnpg-erp.yaml` | **AENDERN:** `barmanObjectStore` → `plugins` |
| `kubernetes/base/cloudnative-pg/cluster/scheduled-backup.yaml` | **AENDERN:** `method` → `plugin` (falls vorhanden) |
| `kubernetes/base/cloudnative-pg/backup/cronjob-shared.yaml` | **PRUEFEN:** ggf. Anpassung der Backup-Methode |
| `kubernetes/base/cloudnative-pg/backup/cronjob-erp.yaml` | **PRUEFEN:** ggf. Anpassung der Backup-Methode |

---

## 8. Wichtige Hinweise

- **Kein Datenverlust:** Bestehende Backups auf S3 bleiben vollstaendig kompatibel
- **Kein Downtime noetig:** Migration kann im laufenden Betrieb erfolgen
- **Atomare Aenderung:** Schritt 2 (ObjectStore CRDs) und Schritt 3 (Cluster-Anpassung)
  muessen in einem Commit erfolgen, damit ArgoCD beides gleichzeitig synchronisiert
- **Image-Wechsel separat:** Der optionale Wechsel von `system` auf `standard` Image
  sollte als separater Schritt nach erfolgreicher Verifikation erfolgen
- **CNPG Passwords:** Weiterhin nur hex-only (`openssl rand -hex 24`) verwenden
- **WAL-Volumes:** Monitoring-Alerts fuer CNPG WAL Volumes (70%/85%) bleiben relevant

---

## 9. Referenzen

- Offizielle Plugin-Dokumentation: https://cloudnative-pg.io/plugin-barman-cloud/
- Migrations-Anleitung: https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/
- Plugin-Releases: https://github.com/cloudnative-pg/plugin-barman-cloud/releases
- CNPG Plugin-Dokumentation: https://cloudnative-pg.io/documentation/current/plugins/
- CNPG Deprecation-Timeline: In-tree Barman Cloud wird in CNPG 1.30.0 entfernt

---

*Konsolidiert aus zwei Vorlaeufer-Dokumenten (15.03.2026 und 30.03.2026).
Versionen und Details vor der tatsaechlichen Migration erneut pruefen.*
