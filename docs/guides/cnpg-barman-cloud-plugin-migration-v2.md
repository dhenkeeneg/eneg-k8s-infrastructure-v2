# CNPG Barman Cloud Plugin Migration — Konsolidierte Anleitung v2

**Erstellt:** 02.04.2026
**Aktualisiert:** 07.04.2026
**Basiert auf:** v1 (02.04.2026), ergaenzt um tatsaechliche Migrationserfahrungen
**Status:** DEV abgeschlossen (07.04.2026) — TEST und PROD ausstehend
**Geschaetzter Aufwand:** 30 Minuten pro Umgebung
**Risiko:** Niedrig (bestehende Backups bleiben kompatibel)

---

## 1. Hintergrund

Die native (in-tree) Unterstuetzung fuer Barman Cloud Backups in CloudNativePG ist seit
Version 1.26.0 deprecated und wird in **CNPG 1.30.0 vollstaendig entfernt**.

Unsere aktuelle Installation nutzt CNPG Operator v1.28.1 (Helm Chart v0.27.1).
Die Migration muss **vor dem Upgrade auf 1.30.0** erfolgen.

Das externe Plugin `barman-cloud.cloudnative-pg.io` ersetzt die in-tree Barman-Funktionalitaet
und wird als offizieller Nachfolger von der CNPG-Community (CNCF Sandbox) gepflegt.

**Verwendete Versionen:**
- Barman Cloud Plugin: **v0.11.0** (Helm Chart: `plugin-barman-cloud` v0.5.0)
- Helm Repository: `https://cloudnative-pg.github.io/charts`
- RBAC-Prefix ab v0.11.0: `barman-plugin-` (Resource Name Migration Guide beachten bei Updates)

---

## 2. Betroffene Cluster und Umgebungen

| Cluster | Namespace | Umgebungen | Backup-Ziel |
|---------|-----------|------------|-------------|
| cnpg-shared | databases | DEV, TEST, PROD | nas10.eneg.de:8010 (S3/HTTP) |
| cnpg-erp | databases | DEV, TEST, PROD | nas10.eneg.de:8010 (S3/HTTP) |

---

## 3. Migrationsstatus

| Umgebung | Status | Datum | Anmerkungen |
|----------|--------|-------|-------------|
| DEV | ✅ Abgeschlossen | 07.04.2026 | WAL-Archivierung funktioniert, Full-Backups durch NAS10-Timeout blockiert (vorbestehendes Problem) |
| TEST | ⏳ Ausstehend | — | |
| PROD | ⏳ Ausstehend | — | |

---

## 4. Voraussetzungen

- [x] CNPG Operator >= 1.27.0 (aktuell: 1.28.1 ✓)
- [x] cert-manager aktiv (fuer TLS zwischen Plugin und Operator ✓)
- [x] Barman Cloud Plugin Helm Chart v0.5.0 (Plugin v0.11.0)
- [ ] Bestehende Backups auf NAS10 verifiziert (NAS10 hat aktuell S3-Timeout-Probleme)

---

## 5. Migrationsschritte (erprobt in DEV am 07.04.2026)

### Schritt 1: Barman Cloud Plugin via GitOps installieren (ArgoCD Helm App)

Neue Datei: `kubernetes/environments/{env}/infrastructure/cnpg-barman-plugin-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg-barman-plugin
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://cloudnative-pg.github.io/charts
    chart: plugin-barman-cloud
    targetRevision: 0.5.0
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
```

**Erfahrung DEV:** Das Helm Chart erstellt das Deployment als
`cnpg-barman-plugin-plugin-barman-cloud` (nicht `barman-cloud`).
Pruefen mit: `kubectl get deployments -n cnpg-system`

### Schritt 2: ObjectStore CRDs erstellen

Fuer jeden CNPG Cluster wird ein separates `ObjectStore`-CRD erstellt.
Dateien in: `kubernetes/environments/{env}/cnpg-cluster/`

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: cnpg-shared-objectstore
  namespace: databases
  labels:
    app.kubernetes.io/part-of: cloudnative-pg
    app.kubernetes.io/managed-by: argocd
spec:
  configuration:
    destinationPath: s3://k8s-{env}-postgres-wal/cnpg-shared/
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

**Wichtig:** `retentionPolicy` liegt auf `spec.retentionPolicy` (nicht innerhalb `configuration`).

Analog fuer `cnpg-erp-objectstore` mit `destinationPath: s3://k8s-{env}-postgres-wal/cnpg-erp/`.

### Schritt 3: Cluster-Manifeste anpassen

In den Cluster-YAML-Dateien die `backup`-Sektion ersetzen:

**Entfernen:**
```yaml
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-{env}-postgres-wal/cnpg-shared/
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

**Hinzufuegen:**
```yaml
  plugins:
    - enabled: true
      isWALArchiver: true
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: cnpg-shared-objectstore
```

**Wichtig (Erfahrung DEV):** CNPG setzt `enabled: true` als Kubernetes-Default.
Dieses Feld **muss im Manifest stehen**, sonst zeigt ArgoCD permanent OutOfSync.

### Schritt 4: ScheduledBackup-Ressourcen anpassen

```yaml
# Vorher (in-tree):
spec:
  method: barmanObjectStore

# Nachher (Plugin-basiert):
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

### Schritt 5: Deployment-Reihenfolge

1. **Commit & Push** aller Aenderungen (ArgoCD App + ObjectStores + Cluster + ScheduledBackups)
2. **Plugin ArgoCD App manuell applyen** (muss vor den Clustern laufen):
   ```bash
   kubectl apply -f kubernetes/environments/{env}/infrastructure/cnpg-barman-plugin-app.yaml --context k8s-{env}
   kubectl get deployments -n cnpg-system --context k8s-{env}
   ```
3. **Warten** bis Plugin 1/1 READY ist
4. **ArgoCD synct** die Cluster-Aenderungen automatisch (Sync-Wave 5 > Wave 4)
5. CNPG fuehrt **Rolling Restart** aller Pods durch (Replicas zuerst, dann Primary)
   — Cluster ist kurzzeitig degraded, das ist normal

### Schritt 6: Verifikation

```bash
# 1. Cluster healthy?
kubectl get cluster -n databases --context k8s-{env}

# 2. Alle Pods 2/2 (postgres + plugin-barman-cloud sidecar)?
kubectl get pods -n databases -l cnpg.io/podRole --context k8s-{env}

# 3. ObjectStores erstellt?
kubectl get objectstores.barmancloud.cnpg.io -n databases --context k8s-{env}

# 4. WAL-Archivierung auf Primary pruefen
kubectl logs -n databases <primary-pod> -c plugin-barman-cloud --tail=10 --context k8s-{env}
# Erwartet: "Archived WAL file" Meldungen

# 5. Manuelles Backup testen
kubectl create -f - --context k8s-{env} <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: cnpg-shared-migration-test
  namespace: databases
spec:
  cluster:
    name: cnpg-shared
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

# 6. Backup-Status pruefen (ACHTUNG: vollstaendigen CRD-Namen verwenden!)
kubectl get backups.postgresql.cnpg.io -n databases --context k8s-{env}
# NICHT: kubectl get backups (waehlt ggf. MariaDB-CRD!)

# 7. Test-Backups aufraeumen
kubectl delete backups.postgresql.cnpg.io cnpg-shared-migration-test cnpg-erp-migration-test -n databases --context k8s-{env}
```

---

## 6. Rollback-Plan

Falls Probleme auftreten:
1. `spec.plugins` aus den Cluster-Manifesten entfernen
2. `spec.backup.barmanObjectStore` wiederherstellen (inkl. `retentionPolicy`)
3. `scheduled-backup.yaml` zurueck auf `method: barmanObjectStore`
4. Commit und Push — ArgoCD synchronisiert zurueck auf in-tree Backup

Die ObjectStore-CRDs und die Plugin ArgoCD App koennen bestehen bleiben —
sie haben keine Auswirkung wenn nicht referenziert.

**Rollback ist nur moeglich solange CNPG Operator < 1.30.0!**

---

## 7. Migrationsstrategie ueber Umgebungen

**Reihenfolge:** DEV → TEST → PROD

Pro Umgebung anzupassende `destinationPath`-Werte:

| Umgebung | Bucket-Prefix | S3-Account |
|----------|---------------|------------|
| DEV | `k8s-dev-` | `s3-k8s-dev` |
| TEST | `k8s-test-` | `s3-k8s-test` |
| PROD | `k8s-prod-` | `s3-k8s-prod` |

---

## 8. Betroffene Dateien pro Umgebung

| Datei | Aenderung |
|-------|-----------|
| `infrastructure/cnpg-barman-plugin-app.yaml` | **NEU:** ArgoCD App fuer Helm Chart |
| `cnpg-cluster/objectstore-shared.yaml` | **NEU:** ObjectStore CRD fuer cnpg-shared |
| `cnpg-cluster/objectstore-erp.yaml` | **NEU:** ObjectStore CRD fuer cnpg-erp |
| `cnpg-cluster/cnpg-shared.yaml` | **AENDERN:** `barmanObjectStore` → `plugins` |
| `cnpg-cluster/cnpg-erp.yaml` | **AENDERN:** `barmanObjectStore` → `plugins` |
| `cnpg-cluster/scheduled-backup.yaml` | **AENDERN:** `method` → `plugin` |

**Nicht betroffen:** CronJobs fuer Logical Backups (`pg_dumpall`) — diese bleiben unveraendert.

---

## 9. Lessons Learned (DEV-Migration 07.04.2026)

1. **Helm-Deployment-Name:** Das Plugin Helm Chart benennt das Deployment
   `cnpg-barman-plugin-plugin-barman-cloud` (nicht `barman-cloud`).
   `kubectl rollout status deployment -n cnpg-system barman-cloud` schlaegt daher fehl.
   Stattdessen: `kubectl get deployments -n cnpg-system` verwenden.

2. **`enabled: true` Default:** CNPG injiziert `enabled: true` in die Plugin-Konfiguration.
   Dieses Feld muss explizit im Manifest stehen, sonst bleibt ArgoCD permanent OutOfSync.

3. **CRD-Namenskonflikt bei kubectl:** `kubectl get backups` / `kubectl delete backup`
   kann die MariaDB-CRD (`backups.k8s.mariadb.com`) statt CNPG waehlen.
   Immer den vollstaendigen CRD-Namen verwenden: `backups.postgresql.cnpg.io`

4. **Rolling Restart:** CNPG startet alle Pods neu (Replicas zuerst, dann Primary).
   Cluster ist kurzzeitig degraded mit Status "Primary instance is being restarted
   without a switchover". Das ist normal und dauert ca. 2-3 Minuten.

5. **Retention-Policy-Timeout:** `barman-cloud-backup-delete` kann bei grossen S3-Buckets
   an Read-Timeouts von NAS10 scheitern. Dies ist ein vorbestehendes NAS10-Problem und
   betrifft nur das Aufraeumen alter Backups, nicht die WAL-Archivierung oder neue Backups.

6. **`retentionPolicy` Platzierung:** Im ObjectStore CRD liegt `retentionPolicy` auf
   `spec.retentionPolicy` (Toplevel), NICHT innerhalb von `spec.configuration`.

---

## 10. Offene Punkte

- [ ] NAS10 S3-Timeout-Problem untersuchen und beheben (betrifft Full-Backups und Retention)
- [ ] Alte fehlgeschlagene Backup-Objekte in S3 aufraeumen
- [ ] TEST-Migration durchfuehren
- [ ] PROD-Migration durchfuehren
- [ ] Optional: Image-Wechsel von `system` auf `standard` nach stabiler Verifikation
- [ ] Alte v1-Anleitung archivieren

---

## 11. Referenzen

- Plugin-Dokumentation: https://cloudnative-pg.io/plugin-barman-cloud/
- Offizielle Migrations-Anleitung: https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/
- Retention Policies: https://cloudnative-pg.io/plugin-barman-cloud/docs/0.4.1/retention/
- Plugin-Releases: https://github.com/cloudnative-pg/plugin-barman-cloud/releases
- Helm Chart: `cloudnative-pg/plugin-barman-cloud` (https://cloudnative-pg.github.io/charts)
- CNPG Release Notes 1.28: https://cloudnative-pg.io/docs/1.29/release_notes/v1.28/
- CNPG Deprecation-Timeline: In-tree Barman Cloud wird in CNPG 1.30.0 entfernt

---

*v2: Aktualisiert nach erfolgreicher DEV-Migration am 07.04.2026.
Enthaelt Lessons Learned und korrigierte Beispiele basierend auf tatsaechlicher Erfahrung.
Ersetzt v1 vom 02.04.2026.*
