# Phase 7: Monitoring-Stack

**Status:** In Bearbeitung (DEV abgeschlossen)
**Beginn:** 08.04.2026
**DEV fertig:** 08.04.2026
**Voraussetzung:** Phase 8c (PROD Rollout) abgeschlossen

---

## 1. Zielsetzung

Aufbau eines vollstaendigen Monitoring- und Alerting-Stacks fuer alle drei Umgebungen
(DEV, TEST, PROD) mit Long-Term-Storage auf NAS10 S3.

### Kernziele

- **Metriken:** Cluster- und App-Metriken via Prometheus + Thanos Long-Term-Storage
- **Logs:** Zentralisierte Log-Aggregation via Loki + Grafana Alloy
- **Alerting:** E-Mail + Microsoft Teams Benachrichtigungen pro Environment
- **Dashboards:** Grafana mit vordefinierten Dashboards (Cluster, CNPG, Backups, Apps)
- **Spezial-Alerts:** CNPG WAL-Volume, Backup-Health, S3-Endpoint (NAS10)

---

## 2. Architektur-Uebersicht

```
+------------------------------------------------------------------+
|                    Monitoring Namespace                            |
|                                                                    |
|  +------------------+    +------------------+    +---------------+ |
|  | Prometheus       |    | Thanos Sidecar   |--->| NAS10 S3      | |
|  | (kube-prom-stack)|    | (im Prometheus   |    | k8s-{env}-    | |
|  | 15d Retention    |    |  Pod integriert) |    | thanos        | |
|  +--------+---------+    +------------------+    +-------+-------+ |
|           |                                              |         |
|           v                                              v         |
|  +------------------+    +------------------+    +---------------+ |
|  | AlertManager     |    | Thanos Query     |    | Thanos Store  | |
|  | E-Mail + Teams   |    | (Gateway fuer    |    | Gateway       | |
|  +------------------+    |  Grafana)        |    | (S3-Zugriff)  | |
|                          +------------------+    +---------------+ |
|                                   |                                |
|                                   v              +---------------+ |
|                          +------------------+    | Thanos        | |
|                          | Grafana          |    | Compactor     | |
|                          | Dashboards +     |    | (Downsampling)| |
|                          | Datasources      |    +---------------+ |
|                          +------------------+                      |
|                                                                    |
|  +------------------+    +------------------+                      |
|  | Loki             |    | Grafana Alloy    |                      |
|  | (Monolithic)     |<---| (DaemonSet,      |                      |
|  | S3-Backend NAS10 |    |  Log-Collector)  |                      |
|  +------------------+    +------------------+                      |
|                                                                    |
|  +------------------+                                              |
|  | Blackbox Exporter|  Probes: nas10.eneg.de:8010 (S3 Health)     |
|  +------------------+                                              |
+------------------------------------------------------------------+
```

---

## 3. Komponenten und Versionen

| Komponente | Helm Chart | Chart-Version | App-Version | Quelle |
|------------|------------|---------------|-------------|--------|
| Prometheus + Grafana + AlertManager | kube-prometheus-stack | ~82.x (latest stable) | Prometheus 3.x, Grafana 11.x | prometheus-community |
| Thanos | bitnami/thanos | latest stable | Thanos 0.37.x | bitnami |
| Loki | grafana/loki | ~6.55.x | Loki 3.7.x | grafana (community) |
| Grafana Alloy | grafana/alloy | latest stable | Alloy 1.x | grafana |
| Blackbox Exporter | prometheus-blackbox-exporter | ~11.x | 0.26.x | prometheus-community |

**Versionsabstimmung:** Exakte Versionen werden vor Implementierung per `helm search` auf
k8s-mgmt-10 ermittelt und hier dokumentiert.

---

## 4. Storage-Strategie

### Lokaler Storage (Longhorn PVCs)

| Komponente | DEV | TEST | PROD | Zweck |
|------------|-----|------|------|-------|
| Prometheus | 20Gi | 20Gi | 50Gi | Hot Data (15 Tage Retention) |
| Loki | 10Gi | 10Gi | 20Gi | WAL + Cache (Chunks auf S3) |
| Thanos Store Gateway | 10Gi | 10Gi | 10Gi | Lokaler Cache fuer S3-Queries |
| Thanos Compactor | 10Gi | 10Gi | 10Gi | Temp-Storage fuer Compaction |
| **Gesamt pro Env** | **50Gi** | **50Gi** | **90Gi** | |

### S3 Long-Term-Storage (NAS10, Port 8010, HTTP)

| Bucket | Inhalt | Retention |
|--------|--------|-----------|
| `k8s-{env}-thanos` | Prometheus-Bloecke (TSDB) via Thanos | Unbegrenzt (Compaction) |
| `k8s-{env}-loki` | Loki Log-Chunks + Index | 90 Tage (konfigurierbar) |

### S3 Accounts auf NAS10

| Account | Umgebung | Buckets |
|---------|----------|---------|
| `s3-k8s-dev` | DEV | k8s-dev-thanos, k8s-dev-loki |
| `s3-k8s-test` | TEST | k8s-test-thanos, k8s-test-loki |
| `s3-k8s-prod` | PROD | k8s-prod-thanos, k8s-prod-loki |

**Hinweis:** Bestehende S3-Accounts wiederverwenden. Buckets muessen manuell
auf NAS10 angelegt werden (gleicher Workflow wie bei CNPG/MariaDB Backups).

---

## 5. DNS und Ingress

| Umgebung | Grafana URL | Traefik IngressRoute |
|----------|-------------|----------------------|
| DEV | https://grafana-dev-v2.eneg.de | traefik Namespace, Let's Encrypt TLS |
| TEST | https://grafana-test.eneg.de | traefik Namespace, Let's Encrypt TLS |
| PROD | https://grafana-prod.eneg.de | traefik Namespace, Let's Encrypt TLS |

Prometheus, AlertManager, Thanos Query, Loki: Kein externer Ingress (nur clusterintern).
Zugriff bei Bedarf per `kubectl port-forward`.

---

## 6. Alerting-Strategie

### Alert-Kanaele

| Kanal | Ziel | Konfiguration |
|-------|------|---------------|
| E-Mail | d.henke@eneg.de (initial) | SMTP: smtpout1.eneg.customers.hosting.zone:587 |
| Teams | Je ein Channel pro Env | Incoming Webhook pro Channel |

Spaeter: Weitere E-Mail-Verteiler pro Environment.

### Alert-Routing pro Environment

| Environment | E-Mail-Empfaenger | Teams-Channel |
|-------------|-------------------|---------------|
| DEV | d.henke@eneg.de | eNeG K8s Dev v2 Monitoring |
| TEST | d.henke@eneg.de | eNeG K8s Test Monitoring |
| PROD | d.henke@eneg.de | eNeG K8s Prod Monitoring |

**Teams Webhook-Typ:** "Webhookwarnungen an Kanal senden" (Workflows/Power Automate).
Payload-Format: Adaptive Cards (nicht das alte MessageCard-Format).

### Alert-Regeln (PrometheusRule CRDs)

**Gruppe 1: Cluster-Health (aus kube-prometheus-stack Defaults)**

| Alert | Schwellwert Warning | Schwellwert Critical |
|-------|---------------------|----------------------|
| RAM-Auslastung Node | >=80% | >=90% |
| Disk-Space Node | >=80% | >=90% |
| CPU-Auslastung Node | >=85% (>5min) | >=95% (sustained) |
| Pod CrashLoopBackOff | - | >3 Restarts in 10min |
| Node NotReady | - | >5 min |
| PVC bald voll | >=80% | >=90% |

**Gruppe 2: CNPG Database Health (Custom PrometheusRules)**

| Alert | Metrik/Quelle | Warning | Critical |
|-------|---------------|---------|----------|
| CNPG WAL-Volume voll | kubelet_volume_stats_used_bytes / _capacity_bytes | >=70% | >=85% |
| CNPG WAL-Archivierung gestoppt | cnpg_pg_stat_archiver_failed_count | >5 min | >15 min |
| CNPG Cluster Not Ready | cnpg_cluster_status != 1 | - | >5 min |
| CNPG Replica Lag | cnpg_pg_replication_lag | >30s | >120s |

**Gruppe 3: Backup Health (Custom PrometheusRules)**

| Alert | Metrik/Quelle | Warning | Critical |
|-------|---------------|---------|----------|
| CronJob Backup fehlgeschlagen | kube_job_status_failed | 1x fehlgeschlagen | 2x hintereinander |
| CronJob nicht gelaufen | kube_cronjob_next_schedule_time | >2x Intervall ueberfaellig | - |
| CNPG ScheduledBackup fehlgeschlagen | cnpg_backup_info status!=completed | 1x | 2x hintereinander |

**Gruppe 4: S3 Endpoint + Infrastruktur (Blackbox Exporter)**

| Alert | Metrik/Quelle | Warning | Critical |
|-------|---------------|---------|----------|
| S3 Endpoint (NAS10) nicht erreichbar | probe_success{target="nas10.eneg.de:8010"} | - | Nicht erreichbar >5 min |
| ArgoCD App Degraded | argocd_app_info health_status | - | Degraded >15 min |
| Longhorn Volume Degraded | longhorn_volume_robustness != 1 | Degraded >10 min | Faulted |

**Gruppe 5: Thanos Health**

| Alert | Metrik/Quelle | Warning | Critical |
|-------|---------------|---------|----------|
| Thanos Sidecar nicht verbunden | thanos_sidecar_prometheus_up | - | ==0 >5 min |
| Thanos Compaction fehlgeschlagen | thanos_compact_group_compactions_failures_total | >0 | >3 in 1h |
| Thanos Store Latency hoch | thanos_store_api_duration_seconds | p99 >5s | p99 >15s |

---

## 7. Grafana Dashboards

### Vordefinierte Dashboards (aus kube-prometheus-stack)

- Kubernetes Cluster Overview
- Node Exporter (CPU, RAM, Disk, Network pro Node)
- Pod Resources
- Namespace Workloads
- PersistentVolume Usage

### Zusaetzliche Dashboards (Custom, als ConfigMap)

| Dashboard | Quelle | Inhalt |
|-----------|--------|--------|
| CNPG Cluster | CloudNativePG Grafana Dashboard (ID: 20417) | Cluster-Status, Connections, WAL, Replication Lag |
| Backup-Uebersicht | Custom | Letzte Backup-Laufzeit, Erfolg/Fehler, naechster Lauf |
| Thanos Overview | Thanos Grafana Dashboard | Sidecar, Store, Compactor Metriken |
| Loki Overview | Grafana Loki Dashboard | Ingestion Rate, Query Performance |
| ArgoCD | ArgoCD Grafana Dashboard | App Sync Status, Health |
| Longhorn | Longhorn Grafana Dashboard | Volume Health, IOPS, Latency |

---

## 8. Implementierungsplan (Schritte)

### Deployment-Reihenfolge: DEV zuerst, dann TEST, dann PROD

Jeder Schritt wird zuerst in DEV implementiert, getestet und verifiziert,
bevor die Overlays fuer TEST und PROD erstellt werden.

### Schritt 1: Vorbereitung (NAS10 + Helm Repos + Namespace)

**1a. S3 Buckets auf NAS10 anlegen** ✅
- Buckets fuer alle Umgebungen angelegt:
  k8s-dev-thanos, k8s-dev-loki, k8s-test-thanos, k8s-test-loki, k8s-prod-thanos, k8s-prod-loki

**1b. DNS-Eintraege anlegen** ✅
- grafana-dev-v2.eneg.de, grafana-test.eneg.de, grafana-prod.eneg.de
- Alle als CNAME auf traefik-{env}.eneg.de

**1c. Teams Incoming Webhooks einrichten** ✅
- Teams-Channels: eNeG K8s Dev v2 Monitoring, eNeG K8s Test Monitoring, eNeG K8s Prod Monitoring
- Webhook-Typ: "Webhookwarnungen an Kanal senden" (Power Automate Workflows)
- Alle 3 Webhook-URLs getestet und funktionsfaehig

**1d. Helm Repos auf k8s-mgmt-10 hinzufuegen**
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update
```

**1e. Exakte Versionen ermitteln und abstimmen**
```bash
helm search repo prometheus-community/kube-prometheus-stack --versions | head -5
helm search repo bitnami/thanos --versions | head -5
helm search repo grafana/loki --versions | head -5
helm search repo grafana/alloy --versions | head -5
helm search repo prometheus-community/prometheus-blackbox-exporter --versions | head -5
```

### Schritt 2: kube-prometheus-stack (DEV)

**Dateien erstellen:**
```
kubernetes/
├── base/monitoring/
│   ├── kube-prometheus-stack/
│   │   ├── values.yaml              # Generische Helm Values
│   │   └── kustomization.yaml
│   ├── namespace.yaml                # monitoring Namespace
│   └── kustomization.yaml
└── environments/dev/
    ├── monitoring/
    │   ├── values-override.yaml      # DEV-spezifisch (Retention, Resources)
    │   └── kustomization.yaml
    └── monitoring-secrets/
        ├── alertmanager-secrets.enc.yaml  # SMTP + Teams Webhook (SOPS)
        ├── kustomization.yaml
        └── secret-generator.yaml
```

**Konfiguration (values.yaml Highlights):**
- Prometheus: 15d Retention, Thanos Sidecar enabled
- Grafana: Admin-Passwort via SOPS Secret, Ingress disabled (eigene IngressRoute)
- AlertManager: E-Mail + Teams Webhook Receiver
- node-exporter: DaemonSet (automatisch)
- kube-state-metrics: Deployment (automatisch)
- Grafana Datasources: Thanos Query statt Prometheus direkt

**ArgoCD App-Definition:**
- `environments/dev/infrastructure/monitoring-app.yaml` (Multi-Source: Helm + Git Values)
- `environments/dev/infrastructure/monitoring-secrets-app.yaml`

**Verifikation:**
- [ ] Prometheus Pods Running, Targets scraping
- [ ] Grafana erreichbar unter https://grafana-dev-v2.eneg.de
- [ ] AlertManager erreichbar (port-forward)
- [ ] node-exporter + kube-state-metrics Metriken sichtbar

### Schritt 3: Thanos (DEV)

**Dateien erstellen:**
```
kubernetes/
├── base/monitoring/
│   └── thanos/
│       ├── values.yaml               # Generische Helm Values (bitnami/thanos)
│       └── kustomization.yaml
└── environments/dev/
    ├── monitoring-thanos/
    │   ├── values-override.yaml      # DEV: S3-Bucket, Endpoint, Resources
    │   └── kustomization.yaml
    └── monitoring-thanos-secrets/
        ├── thanos-s3-credentials.enc.yaml  # S3 Objstore Config (SOPS)
        ├── kustomization.yaml
        └── secret-generator.yaml
```

**Thanos-Komponenten:**
- Thanos Sidecar: Bereits in Schritt 2 via kube-prometheus-stack aktiviert
- Thanos Query: Gateway fuer Grafana (queried Sidecar + Store)
- Thanos Store Gateway: Liest historische Daten von S3
- Thanos Compactor: Downsampling + Retention auf S3

**objstore.yml Secret (SOPS-verschluesselt):**
```yaml
type: S3
config:
  bucket: k8s-dev-thanos
  endpoint: nas10.eneg.de:8010
  access_key: <S3_ACCESS_KEY>
  secret_key: <S3_SECRET_KEY>
  insecure: true           # HTTP statt HTTPS
```

**ArgoCD App-Definitionen:**
- `environments/dev/infrastructure/thanos-app.yaml`
- `environments/dev/infrastructure/thanos-secrets-app.yaml`

**Verifikation:**
- [ ] Thanos Sidecar Connected (in Prometheus Pod Logs)
- [ ] Thanos Query erreichbar (port-forward :9090)
- [ ] Thanos Store Gateway: S3-Bloecke sichtbar
- [ ] Grafana Datasource auf Thanos Query umgestellt
- [ ] Historische Metriken (>15d) ueber Thanos Query abrufbar

---

### Schritt 4: Loki + Grafana Alloy (DEV)

**Dateien erstellen:**
```
kubernetes/
├── base/monitoring/
│   ├── loki/
│   │   ├── values.yaml               # Monolithic Mode, S3 Backend
│   │   └── kustomization.yaml
│   └── alloy/
│       ├── values.yaml               # DaemonSet, Kubernetes Log Discovery
│       └── kustomization.yaml
└── environments/dev/
    ├── monitoring-loki/
    │   ├── values-override.yaml      # DEV: S3-Bucket, Resources
    │   └── kustomization.yaml
    └── monitoring-loki-secrets/
        ├── loki-s3-credentials.enc.yaml  # S3 Credentials (SOPS)
        ├── kustomization.yaml
        └── secret-generator.yaml
```

**Loki Konfiguration:**
- deploymentMode: SingleBinary (Monolithic)
- S3 Backend auf NAS10 fuer Chunks + Index
- Lokales WAL auf Longhorn PVC
- Retention: 90 Tage auf S3

**Alloy Konfiguration:**
- DaemonSet auf allen Nodes
- loki.source.kubernetes fuer Container-Logs
- Forward an Loki clusterintern (http://loki.monitoring:3100)
- Labels: namespace, pod, container, node

**ArgoCD App-Definitionen:**
- `environments/dev/infrastructure/loki-app.yaml`
- `environments/dev/infrastructure/loki-secrets-app.yaml`
- `environments/dev/infrastructure/alloy-app.yaml`

**Verifikation:**
- [ ] Alloy DaemonSet Running auf allen 3 Nodes
- [ ] Loki Pod Running, S3-Verbindung OK
- [ ] Grafana: Loki Datasource hinzugefuegt
- [ ] LogQL Query `{namespace="monitoring"}` liefert Ergebnisse
- [ ] Logs aller Namespaces sichtbar in Grafana Explore

---

### Schritt 5: Blackbox Exporter (DEV)

**Dateien erstellen:**
```
kubernetes/
├── base/monitoring/
│   └── blackbox-exporter/
│       ├── values.yaml               # Probes: NAS10 S3 Endpoint
│       └── kustomization.yaml
└── environments/dev/
    └── monitoring-blackbox/
        ├── values-override.yaml      # DEV-spezifische Probe-Targets
        └── kustomization.yaml
```

**Blackbox Probe-Targets:**
- `http://nas10.eneg.de:8010` (S3 Endpoint Health Check)

**ArgoCD App-Definition:**
- `environments/dev/infrastructure/blackbox-exporter-app.yaml`

**Verifikation:**
- [ ] Blackbox Exporter Pod Running
- [ ] Probe-Metriken in Prometheus sichtbar (`probe_success`)
- [ ] ServiceMonitor aktiv

---

### Schritt 6: CNPG PodMonitor + Custom Alert Rules (DEV)

**6a. CNPG PodMonitor aktivieren:**
- `enablePodMonitor: true` in cnpg-shared und cnpg-erp Cluster-Specs
- Aenderung in `kubernetes/environments/dev/cnpg-cluster/cnpg-shared.yaml` und `cnpg-erp.yaml`

**6b. Custom PrometheusRule CRDs erstellen:**
```
kubernetes/
├── base/monitoring/
│   └── alert-rules/
│       ├── cnpg-alerts.yaml          # CNPG WAL, Archivierung, Cluster Health
│       ├── backup-alerts.yaml        # CronJob Failures, ScheduledBackup
│       ├── blackbox-alerts.yaml      # S3 Endpoint, ArgoCD Health
│       ├── thanos-alerts.yaml        # Thanos Sidecar, Compaction, Store
│       └── kustomization.yaml
└── environments/dev/
    └── monitoring-alerts/
        └── kustomization.yaml
```

**ArgoCD App-Definition:**
- `environments/dev/infrastructure/monitoring-alerts-app.yaml`

**Verifikation:**
- [ ] CNPG Metriken in Prometheus sichtbar (cnpg_*)
- [ ] PrometheusRules geladen (Prometheus UI → Alerts)
- [ ] Test-Alert ausloesen (z.B. Blackbox Probe auf ungueltige URL)
- [ ] E-Mail-Alert empfangen
- [ ] Teams-Alert empfangen

---

### Schritt 7: Grafana Dashboards + Datasources (DEV)

**7a. Datasources (via kube-prometheus-stack values):**
- Thanos Query als primaere Prometheus-Datasource
- Loki als Log-Datasource
- AlertManager als AlertManager-Datasource

**7b. Custom Dashboards (als ConfigMaps):**
```
kubernetes/base/monitoring/dashboards/
├── cnpg-dashboard.json
├── backup-overview-dashboard.json
├── thanos-overview-dashboard.json
└── kustomization.yaml
```

Dashboards werden als ConfigMaps mit Label `grafana_dashboard: "1"` deployed.
Grafana Sidecar laedt sie automatisch.

**Verifikation:**
- [ ] Alle Standard-Dashboards (Cluster, Node, Pod) sichtbar
- [ ] CNPG Dashboard zeigt Cluster-Status, WAL, Connections
- [ ] Backup-Dashboard zeigt CronJob-Status
- [ ] Thanos Dashboard zeigt S3-Upload, Compaction

---

### Schritt 8: Grafana Ingress (DEV)

**Dateien erstellen:**
```
kubernetes/environments/dev/
└── monitoring-ingress/
    ├── certificate.yaml             # Let's Encrypt Zertifikat
    ├── ingress-route.yaml           # Traefik IngressRoute fuer Grafana
    └── kustomization.yaml
```

**Pattern:** Gleich wie Longhorn/Headlamp Ingress (Certificate + IngressRoute im traefik NS)

**ArgoCD App-Definition:**
- `environments/dev/infrastructure/monitoring-ingress-app.yaml`

**Verifikation:**
- [ ] https://grafana-dev-v2.eneg.de erreichbar
- [ ] TLS-Zertifikat gueltig (Let's Encrypt)
- [ ] Login mit Admin-Credentials funktioniert

---

### Schritt 9: TEST + PROD Rollout

Nach erfolgreicher DEV-Verifikation: Overlays fuer TEST und PROD erstellen.

**Pro Environment:**
1. S3 Buckets auf NAS10 anlegen (Thanos + Loki)
2. DNS-Eintrag fuer Grafana anlegen
3. Teams-Webhook URL beschaffen
4. Environment-Overlay-Dateien erstellen (gleiche Struktur wie DEV)
5. SOPS Secrets verschluesseln (S3-Credentials, AlertManager, Grafana)
6. ArgoCD App-Definitionen erstellen (~8-10 neue Apps pro Env)
7. CNPG PodMonitor aktivieren (enablePodMonitor: true)
8. Verifizierung: Grafana, Alerts, Dashboards, Logs

**Reihenfolge:** DEV → Commit → Verify → TEST → Commit → Verify → PROD

---

## 9. Repository-Struktur (Ziel-Zustand)

```
kubernetes/
├── base/monitoring/
│   ├── namespace.yaml
│   ├── kustomization.yaml
│   ├── kube-prometheus-stack/
│   │   ├── values.yaml
│   │   └── kustomization.yaml
│   ├── thanos/
│   │   ├── values.yaml
│   │   └── kustomization.yaml
│   ├── loki/
│   │   ├── values.yaml
│   │   └── kustomization.yaml
│   ├── alloy/
│   │   ├── values.yaml
│   │   └── kustomization.yaml
│   ├── blackbox-exporter/
│   │   ├── values.yaml
│   │   └── kustomization.yaml
│   ├── alert-rules/
│   │   ├── cnpg-alerts.yaml
│   │   ├── backup-alerts.yaml
│   │   ├── blackbox-alerts.yaml
│   │   ├── thanos-alerts.yaml
│   │   └── kustomization.yaml
│   └── dashboards/
│       ├── cnpg-dashboard.json
│       ├── backup-overview-dashboard.json
│       └── kustomization.yaml
└── environments/{dev,test,prod}/
    ├── monitoring/                     # kube-prometheus-stack Override
    │   ├── values-override.yaml
    │   └── kustomization.yaml
    ├── monitoring-thanos/              # Thanos Override
    │   ├── values-override.yaml
    │   └── kustomization.yaml
    ├── monitoring-loki/                # Loki Override
    │   ├── values-override.yaml
    │   └── kustomization.yaml
    ├── monitoring-blackbox/            # Blackbox Exporter Override
    │   ├── values-override.yaml
    │   └── kustomization.yaml
    ├── monitoring-alerts/              # Alert Rules (ggf. env-spezifisch)
    │   └── kustomization.yaml
    ├── monitoring-ingress/             # Grafana Ingress
    │   ├── certificate.yaml
    │   ├── ingress-route.yaml
    │   └── kustomization.yaml
    ├── monitoring-secrets/             # AlertManager + Grafana Secrets
    │   ├── alertmanager-secrets.enc.yaml
    │   ├── grafana-admin-secret.enc.yaml
    │   ├── kustomization.yaml
    │   └── secret-generator.yaml
    ├── monitoring-thanos-secrets/      # Thanos S3 Credentials
    │   ├── thanos-s3-credentials.enc.yaml
    │   ├── kustomization.yaml
    │   └── secret-generator.yaml
    ├── monitoring-loki-secrets/        # Loki S3 Credentials
    │   ├── loki-s3-credentials.enc.yaml
    │   ├── kustomization.yaml
    │   └── secret-generator.yaml
    └── infrastructure/
        ├── monitoring-app.yaml
        ├── monitoring-secrets-app.yaml
        ├── thanos-app.yaml
        ├── thanos-secrets-app.yaml
        ├── loki-app.yaml
        ├── loki-secrets-app.yaml
        ├── alloy-app.yaml
        ├── blackbox-exporter-app.yaml
        ├── monitoring-alerts-app.yaml
        └── monitoring-ingress-app.yaml
```

---

## 10. ArgoCD App-Definitionen (Neue Apps pro Environment)

| Nr | App-Name | Typ | Pfad |
|----|----------|-----|------|
| 1 | monitoring | Helm (Multi-Source) | environments/{env}/monitoring/ |
| 2 | monitoring-secrets | Kustomize (KSOPS) | environments/{env}/monitoring-secrets/ |
| 3 | thanos | Helm (Multi-Source) | environments/{env}/monitoring-thanos/ |
| 4 | thanos-secrets | Kustomize (KSOPS) | environments/{env}/monitoring-thanos-secrets/ |
| 5 | loki | Helm (Multi-Source) | environments/{env}/monitoring-loki/ |
| 6 | loki-secrets | Kustomize (KSOPS) | environments/{env}/monitoring-loki-secrets/ |
| 7 | alloy | Helm (Multi-Source) | base/monitoring/alloy/ + override |
| 8 | blackbox-exporter | Helm (Multi-Source) | environments/{env}/monitoring-blackbox/ |
| 9 | monitoring-alerts | Kustomize | environments/{env}/monitoring-alerts/ |
| 10 | monitoring-ingress | Kustomize | environments/{env}/monitoring-ingress/ |

**Gesamt: 10 neue ArgoCD Apps pro Environment** (39 bestehend + 10 = 49 pro Env)

---

## 11. Geschaetzter Aufwand

| Schritt | Beschreibung | Geschaetzter Aufwand |
|---------|--------------|----------------------|
| 1 | Vorbereitung (S3, DNS, Teams, Helm Repos) | 1h (Daniel manuell) |
| 2 | kube-prometheus-stack (DEV) | 2-3h |
| 3 | Thanos (DEV) | 1-2h |
| 4 | Loki + Alloy (DEV) | 2-3h |
| 5 | Blackbox Exporter (DEV) | 30min |
| 6 | CNPG PodMonitor + Alert Rules (DEV) | 1-2h |
| 7 | Dashboards (DEV) | 1h |
| 8 | Grafana Ingress (DEV) | 30min |
| 9 | TEST + PROD Rollout (je Env) | 2-3h x2 |
| **Gesamt** | | **~15-20h** |

---

## 12. Abhaengigkeiten und Voraussetzungen

| Voraussetzung | Status | Verantwortlich |
|---------------|--------|----------------|
| S3 Buckets auf NAS10 | ✅ Erledigt (alle Envs) | Daniel |
| DNS-Eintraege (Grafana) | ✅ Erledigt (alle Envs) | Daniel |
| Teams Incoming Webhooks | ✅ Erledigt + getestet | Daniel |
| Helm Repos auf k8s-mgmt-10 | Offen | Daniel (CLI) |
| CNPG Barman Cloud Plugin Migration | ✅ Abgeschlossen | - |
| PostgreSQL Image-Wechsel 17.9 | ✅ Abgeschlossen | - |
| Phase 8c PROD Rollout | ✅ Abgeschlossen | - |

---

## 13. Risiken und Mitigationen

| Risiko | Mitigation |
|--------|------------|
| kube-prometheus-stack CRDs gross (wie ArgoCD) | server-side apply, ggf. CRDs separat |
| NAS10 S3 Rate-Limiting (bekannt von CNPG) | Thanos Compactor Concurrency begrenzen |
| Loki hoher Memory-Verbrauch | Monolithic Mode, S3-Backend, Limits setzen |
| AlertManager SMTP-Timeouts | Retry-Config, Webhook als Fallback |
| Thanos Store Gateway langsam bei Cold Queries | Cache-PVC, Query-Timeout erhoehen |

---

## 14. Offene Entscheidungen

- [x] Exakte Helm Chart Versionen (abgestimmt 08.04.2026, siehe Abschnitt 3)
- [x] Teams Webhook URLs (erledigt, alle 3 Channels getestet)
- [x] Grafana Admin-Passwort (SOPS-verschluesselt, DEV deployed)
- [x] Loki Log-Retention Dauer: 90 Tage auf S3
- [x] Thanos Compaction: 30d raw, 180d 5m-Downsampling, 365d 1h-Downsampling

---

## 15. DEV Implementierung — Ergebnisse (08.04.2026)

### Deployed Components

| Komponente | Chart-Version | App-Version | Status |
|------------|---------------|-------------|--------|
| kube-prometheus-stack | 83.0.0 | v0.90.1 | ✅ Synced+Healthy |
| Thanos (bitnami) | 17.3.1 | v0.39.2 | ✅ Synced+Healthy |
| Loki (grafana) | 6.55.0 | 3.6.7 | ✅ Synced+Healthy |
| Grafana Alloy | 1.7.0 | v1.15.0 | ✅ Synced+Healthy |
| Blackbox Exporter | 11.9.1 | v0.28.0 | ✅ Synced+Healthy |

### ArgoCD Apps (9 neue Apps)

| App | Typ | Status |
|-----|-----|--------|
| monitoring | Helm (Multi-Source) | ✅ Synced+Healthy |
| monitoring-secrets | Kustomize (KSOPS) | ✅ Synced+Healthy |
| monitoring-ingress | Kustomize | ✅ Synced+Healthy |
| monitoring-alerts | Kustomize (Alert Rules + ServiceMonitors + Dashboards + prometheus-msteams) | ✅ Synced+Healthy |
| thanos | Helm (Multi-Source) | ✅ Synced+Healthy |
| loki | Helm (Multi-Source) | ✅ Synced+Healthy |
| loki-secrets | Kustomize (KSOPS) | ✅ Synced+Healthy |
| alloy | Helm (Multi-Source) | ✅ Synced+Healthy |
| blackbox-exporter | Helm (Multi-Source) | ✅ Synced+Healthy |

### URLs

| Service | URL |
|---------|-----|
| Grafana | https://grafana-dev-v2.eneg.de |

### Grafana Datasources

| Datasource | Typ | URL |
|------------|-----|-----|
| Prometheus | prometheus | kube-prometheus-stack-prometheus:9090 (Default) |
| Thanos | prometheus | thanos-query:9090 |
| Loki | loki | loki-gateway:80 |
| Alertmanager | alertmanager | kube-prometheus-stack-alertmanager:9093 |

### Grafana Dashboards

| Dashboard | Quelle | Ordner | Daten |
|-----------|--------|--------|-------|
| Kubernetes Cluster, Node, Pod, PVC, ... | kube-prometheus-stack Default | Default | ✅ |
| CloudNativePG | grafana.com gnetId 20417 | Custom | ✅ |
| ArgoCD Operational Overview | grafana.com gnetId 19993 | Custom | ✅ |
| Longhorn | grafana.com gnetId 16888 | Custom | ✅ |
| Loki 2.0 | grafana.com gnetId 13407 | Custom | ✅ |
| Backup Uebersicht | Custom ConfigMap (backup-overview-dashboard-cm) | General | ✅ |
| Thanos Overview | Custom ConfigMap (thanos-overview-dashboard-cm) | General | ✅ |

### Custom PrometheusRules (4)

| Rule-Name | Alerts |
|-----------|--------|
| cnpg-alerts | WAL-Volume (70%/85%), Cluster NotReady, Replication Lag, WAL-Archivierung |
| backup-alerts | CronJob Failed, CronJob Overdue, Pod CrashLoop |
| blackbox-infra-alerts | S3 Endpoint Down, ArgoCD Degraded, Longhorn Degraded/Faulted |
| thanos-alerts | Sidecar Down, Compaction Failed, Store Gateway S3-Fehler |

### ServiceMonitors (Custom, zusaetzlich zu Chart-Defaults)

| ServiceMonitor | Namespace | Targets |
|----------------|-----------|---------|
| argocd-metrics | monitoring | argocd/* (Port: metrics) |
| longhorn-manager | monitoring | longhorn-system/longhorn-manager |


### Kritische Learnings (DEV)

1. **bitnami Thanos Image nicht auf docker.io verfuegbar** (Tag `0.39.2-debian-12-r2` not found).
   Fix: Offizielles Image `quay.io/thanos/thanos:v0.39.2` + `global.security.allowInsecureImages: true`
   (bitnami Chart blockiert non-bitnami Images per Default seit 2025).

2. **K3s exponiert kubeControllerManager/Scheduler/Proxy nicht separat.**
   Fix: `kubeControllerManager.enabled: false`, `kubeScheduler.enabled: false`,
   `kubeProxy.enabled: false` in kube-prometheus-stack values.

3. **Loki Chart Default chunks-cache: 8192 MB (allocatedMemory)** — zu gross fuer DEV (12GB Nodes).
   Fix: `chunksCache.allocatedMemory: 512`, `resultsCache.allocatedMemory: 256`.
   NICHT ueber explizite `resources` setzen — Chart berechnet aus allocatedMemory.

4. **Loki `extraEnvFrom` muss unter `singleBinary` stehen**, nicht Top-Level.
   Chart ignoriert Top-Level extraEnvFrom/extraArgs im Monolithic Mode.
   Gleiches gilt fuer `extraArgs: ["-config.expand-env=true"]` (fuer Env-Var-Expansion in Config).

5. **Loki Schema-Datum** (`from` in schemaConfig) muss vor dem aeltesten erwarteten
   Log-Timestamp liegen. Empfehlung: `from: "2024-01-01"` statt aktuelles Datum.

6. **Loki Canary kann nicht deaktiviert werden** — Chart-Validierung erzwingt
   `lokiCanary.enabled: true` fuer Helm Tests. Canary-Pods sind minimal (kein Memory-Request).

7. **Grafana `additionalDataSources` darf NICHT `isDefault: true` haben**
   wenn der Default-Prometheus-Datasource ebenfalls Default ist. Zwei Defaults verursachen
   500er-Fehler beim Provisioning-Reload. Fix: `isDefault: false` fuer zusaetzliche Datasources.

8. **Blackbox Exporter: S3 Root-URL gibt 404 zurueck** (normal, kein Bucket angegeben).
   Fix: TCP Probe statt HTTP. TCP prueft ob der S3-Dienst laeuft und Verbindungen akzeptiert.
   Funktionale S3-Probleme werden durch CNPG WAL-Archivierung-Alerts separat erkannt.

9. **Grafana Datasource-Aenderungen erfordern Pod-Restart** (rollout restart deployment).
   Der Sidecar erkennt ConfigMap-Updates, aber der initiale Provisioning-Reload kann fehlschlagen.

10. **Thanos bitnami Chart: `global.security.allowInsecureImages: true`** ist sicher —
    es deaktiviert nur die bitnami-eigene Vendor-Lock-in-Pruefung, keine K8s-Security.
    Das offizielle quay.io Thanos Image ist vom CNCF-Projekt signiert und maintained.

11. **Thanos Dashboard gnetId 12937 funktioniert nicht mit bitnami Chart** —
    nutzt veraltetes Grafana `rows`-Format (2176 Zeilen, 70KB) und inkompatible Variable-Selektoren.
    Fix: Kompaktes Custom-Dashboard (160 Zeilen) als ConfigMap mit angepassten Job-Labels
    und Queries direkt aus dem offiziellen Thanos-Dashboard-Repository.

12. **gnetId-Dashboards und Sidecar-ConfigMap-Dashboards nutzen unterschiedliche Pfade:**
    gnetId → `/var/lib/grafana/dashboards/custom/` (download-dashboards init-container),
    ConfigMap → `/tmp/dashboards/` (grafana-sc-dashboard Sidecar).
    Beide Pfade muessen als separate dashboardProviders konfiguriert werden.
    Alte gnetId-Dateien bleiben auf dem PVC auch wenn der gnetId-Eintrag entfernt wird
    (manuell loeschen mit `kubectl exec ... rm`).

13. **Thanos und Loki ServiceMonitors muessen explizit aktiviert werden:**
    Thanos: `metrics.enabled: true` + `metrics.serviceMonitor.enabled: true`
    Loki: `monitoring.serviceMonitor.enabled: true`
    Ohne diese Einstellungen exportieren die Komponenten keine Metriken an Prometheus
    und die zugehoerigen Dashboards bleiben leer.

14. **Teams Webhook-Typ: "Webhookwarnungen an Kanal senden" (Power Automate Workflows).**
    Der klassische "Incoming Webhook Connector" wurde Ende 2025 durch Power Automate ersetzt.
    Payload-Format: Adaptive Cards (nicht das alte MessageCard-Format).
    AlertManager kann NICHT direkt an Power Automate Webhooks senden — es braucht einen Adapter.

15. **prometheus-msteams Adapter noetig fuer Teams-Alerts.**
    AlertManager → prometheus-msteams:2000/alertmanager → Teams Webhook (Adaptive Card).
    stakater/prometheus-msteams (v1.5.4) unterstuetzt Power Automate nativ.
    GHCR-Package ist privat (401) — Image muss selbst gebaut werden:
    `git clone github.com/stakater/prometheus-msteams`, `docker buildx build --platform linux/amd64`,
    Push nach `ghcr.io/dhenkeeneg/prometheus-msteams:v1.5.4`.
    Deployment braucht `imagePullSecrets: ghcr-pull-secret` im monitoring Namespace.
    Health-Probes: tcpSocket statt httpGet (kein /healthz Endpoint im stakater Build).

16. **DEV App-Deployments sind eigenstaendige Kopien, keine Kustomize-Overlays.**
    `environments/dev/apps/*/deployment.yaml` sind vollstaendige Dateien, nicht Overlays auf base.
    Aenderungen in `base/apps/*/` haben KEINE Wirkung — ArgoCD liest nur die Env-Dateien.
    base-Dateien dienen nur als Kopiervorlage fuer neue Environments.
    Gleiches Muster fuer TEST und PROD.

17. **KubeCPUOvercommit Threshold in DEV angepasst.**
    Default-Alert (> 0 CPU Overcommit) deaktiviert fuer DEV.
    Custom DEV-Version feuert erst bei > 0.5 CPU Overcommit.
    DEV hat 3x4 vCPU = 12 total, ~8.1 Requests nach Reduktion.
    TEST/PROD behalten den Default-Alert.

### Offene Punkte fuer TEST/PROD Rollout

- CNPG PodMonitor in TEST/PROD aktivieren (enablePodMonitor: true in cnpg-shared + cnpg-erp)
- S3 Secrets fuer TEST/PROD verschluesseln (Thanos + Loki + AlertManager + Grafana pro Env)
- AlertManager config pro Env: SMTP-Absender (alertmanager-test@/alertmanager-prod@) + Teams Webhook URL
- Grafana Admin Secret pro Env (eigenes Passwort)
- Thanos objstore Secret pro Env (Bucket: k8s-test-thanos / k8s-prod-thanos)
- Loki S3 Credentials pro Env (Bucket: k8s-test-loki / k8s-prod-loki)
- **WICHTIG:** Loki base values enthalten DEV-spezifische S3-Bucket-Namen (`k8s-dev-loki`).
  Fuer TEST/PROD muessen diese per values-override.yaml ueberschrieben werden.
- PVC-Groessen: TEST gleich wie DEV (20Gi Prometheus, 10Gi Loki, 512MB/256MB Cache);
  PROD groesser (50Gi Prometheus, 20Gi Loki, 2Gi/1Gi Cache)
- Grafana Ingress pro Env: Certificate + IngressRoute (grafana-test.eneg.de / grafana-prod.eneg.de)
- DNS-Eintraege bereits erstellt (alle 3 Envs)
- Teams Channels bereits erstellt (eNeG K8s Test/Prod Monitoring) mit Webhook-URLs
- Pro Env ~10 ArgoCD App-Definitionen erstellen (kopieren+anpassen von DEV)
- Deployment-Reihenfolge: Secrets zuerst, dann Monitoring-Stack, dann Thanos/Loki/Alloy/Blackbox/Alerts/Ingress

---

*Erstellt: 08.04.2026*
*Letzte Aktualisierung: 09.04.2026*
