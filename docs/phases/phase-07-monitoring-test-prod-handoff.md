# Phase 7 - Monitoring TEST/PROD Rollout Handoff

**Erstellt:** 09.04.2026
**Vorgaenger-Chat:** Phase 7 DEV Monitoring-Stack (08-09.04.2026)
**Status:** DEV komplett, TEST + PROD offen

---

## 1. Kontext

Phase 7 Monitoring-Stack ist in DEV komplett deployed und verifiziert:
- 9 ArgoCD Apps, 23 Pods, alle Synced + Healthy
- Grafana: https://grafana-dev-v2.eneg.de (4 Datasources, 7 Dashboards)
- Alle Learnings dokumentiert in `docs/phases/phase-07-monitoring-stack.md`

**Aufgabe fuer diesen Chat:** Schritt 9 — TEST + PROD Rollout

---

## 2. Bereits erledigt (alle Envs)

- [x] S3 Buckets auf NAS10: k8s-{dev,test,prod}-{thanos,loki}
- [x] DNS-Eintraege: grafana-dev-v2.eneg.de, grafana-test.eneg.de, grafana-prod.eneg.de
- [x] Teams Channels + Webhooks: eNeG K8s {Dev v2,Test,Prod} Monitoring
- [x] Helm Repos auf k8s-mgmt-10 konfiguriert

## 3. Versionen (abgestimmt, fuer alle Envs identisch)

| Komponente | Helm Chart | Version | Image |
|------------|------------|---------|-------|
| kube-prometheus-stack | prometheus-community | 83.0.0 | diverse (Chart-Default) |
| Thanos | bitnami/thanos | 17.3.1 | quay.io/thanos/thanos:v0.39.2 |
| Loki | grafana/loki | 6.55.0 | Chart-Default |
| Alloy | grafana/alloy | 1.7.0 | Chart-Default |
| Blackbox Exporter | prometheus-community | 11.9.1 | Chart-Default |

---

## 4. DEV-Dateistruktur (als Vorlage fuer TEST/PROD)

Pro Environment muessen folgende Verzeichnisse/Dateien erstellt werden:

```
kubernetes/environments/{test|prod}/
├── monitoring/
│   └── values-override.yaml          # PVC-Groessen, AlertManager Config (SMTP + Teams)
├── monitoring-secrets/
│   ├── kustomization.yaml
│   ├── secret-generator.yaml
│   ├── alertmanager-credentials.enc.yaml   # SOPS (SMTP-PW + Teams-URL)
│   ├── grafana-admin-secret.enc.yaml       # SOPS (Admin-PW)
│   └── thanos-objstore-config.enc.yaml     # SOPS (S3 Bucket + Keys)
├── monitoring-loki/
│   └── values-override.yaml          # S3-Bucket-Name + PVC-Groesse
├── monitoring-loki-secrets/
│   ├── kustomization.yaml
│   ├── secret-generator.yaml
│   └── loki-s3-credentials.enc.yaml  # SOPS (S3 Keys)
├── monitoring-thanos/
│   └── values-override.yaml          # (minimal, ggf. PVC fuer PROD)
├── monitoring-blackbox/
│   └── values-override.yaml          # (minimal, Targets identisch)
├── monitoring-alerts/
│   └── kustomization.yaml            # Referenz auf base/ (alert-rules + servicemonitors + dashboards)
├── monitoring-ingress/
│   ├── kustomization.yaml
│   └── ingress.yaml                  # Certificate + IngressRoute (Hostname!)
└── infrastructure/
    ├── monitoring-app.yaml           # Helm Multi-Source
    ├── monitoring-secrets-app.yaml   # KSOPS
    ├── monitoring-ingress-app.yaml   # Kustomize
    ├── monitoring-alerts-app.yaml    # Kustomize
    ├── thanos-app.yaml               # Helm Multi-Source
    ├── loki-app.yaml                 # Helm Multi-Source
    ├── loki-secrets-app.yaml         # KSOPS
    ├── alloy-app.yaml                # Helm Multi-Source
    └── blackbox-exporter-app.yaml    # Helm Multi-Source
```

**Hinweis:** `monitoring-thanos-secrets` wird NICHT benoetigt — das Thanos objstore Secret
liegt bereits in `monitoring-secrets` (3 Secrets in einer KSOPS Kustomization).

---

## 5. Umgebungsspezifische Unterschiede

### TEST (VLAN 179)

| Parameter | Wert |
|-----------|------|
| Grafana URL | https://grafana-test.eneg.de |
| Grafana Ingress Host | grafana-test.eneg.de |
| AlertManager SMTP From | alertmanager-test@eneg.de |
| Teams Webhook | eNeG K8s Test Monitoring URL |
| Thanos S3 Bucket | k8s-test-thanos |
| Loki S3 Bucket | k8s-test-loki |
| S3 Account | s3-k8s-test |
| Prometheus PVC | 20Gi |
| Loki PVC | 10Gi |
| Loki chunksCache | 512 MB |
| Loki resultsCache | 256 MB |
| ArgoCD targetRevision | main (aktuell Single-Branch) |

### PROD (VLAN 178)

| Parameter | Wert |
|-----------|------|
| Grafana URL | https://grafana-prod.eneg.de |
| Grafana Ingress Host | grafana-prod.eneg.de |
| AlertManager SMTP From | alertmanager-prod@eneg.de |
| Teams Webhook | eNeG K8s Prod Monitoring URL |
| Thanos S3 Bucket | k8s-prod-thanos |
| Loki S3 Bucket | k8s-prod-loki |
| S3 Account | s3-k8s-prod |
| Prometheus PVC | 50Gi |
| Loki PVC | 20Gi |
| Loki chunksCache | 2048 MB |
| Loki resultsCache | 1024 MB |
| ArgoCD targetRevision | main (aktuell Single-Branch) |

---

## 6. WICHTIG: Loki S3 Bucket-Name in base values

Die Datei `kubernetes/base/monitoring/loki/values.yaml` enthaelt DEV-spezifische
S3-Bucket-Namen (`k8s-dev-loki`). Fuer TEST/PROD muessen diese in der
jeweiligen `values-override.yaml` ueberschrieben werden:

```yaml
# environments/{test|prod}/monitoring-loki/values-override.yaml
loki:
  storage:
    bucketNames:
      chunks: k8s-{test|prod}-loki
      ruler: k8s-{test|prod}-loki
```

---

## 7. CNPG PodMonitor aktivieren

In TEST und PROD muessen die CNPG Cluster-Specs angepasst werden:
- `kubernetes/environments/test/cnpg-cluster/cnpg-shared.yaml` → `enablePodMonitor: true`
- `kubernetes/environments/test/cnpg-cluster/cnpg-erp.yaml` → `enablePodMonitor: true`
- Gleich fuer prod/

---

## 8. Rollout-Reihenfolge pro Environment

**Deployment-Reihenfolge IMMER einhalten: Erst TEST, dann PROD.**
**Pro Environment nur Dateien einer Umgebung aendern → Commit → Verify → naechste Umgebung.**

### Schritt-fuer-Schritt pro Env:

1. **Dateien erstellen (Claude via Desktop Commander):**
   - values-override.yaml (monitoring, monitoring-loki, monitoring-thanos, monitoring-blackbox)
   - KSOPS Kustomizations + Secret-Generator (monitoring-secrets, monitoring-loki-secrets)
   - Secret Templates (.yaml.template)
   - monitoring-alerts Kustomization (Referenz auf base/)
   - monitoring-ingress (Certificate + IngressRoute)
   - 9 ArgoCD App-Definitionen in infrastructure/

2. **Commit + Push (Daniel, lokaler Rechner)**

3. **Secrets verschluesseln (Daniel, k8s-mgmt-10):**
   - alertmanager-credentials.enc.yaml (SMTP-PW + Teams-Webhook-URL)
   - grafana-admin-secret.enc.yaml (Admin-PW)
   - thanos-objstore-config.enc.yaml (S3-Bucket + Keys)
   - loki-s3-credentials.enc.yaml (S3 Keys)
   - Commit + Push von k8s-mgmt-10

4. **Pull auf lokalem Rechner (git pull --rebase)**

5. **CNPG PodMonitor aktivieren:**
   - enablePodMonitor: true in cnpg-shared + cnpg-erp
   - Commit + Push

6. **Verifizierung:**
   ```bash
   # Alle Monitoring Apps pruefen
   kubectl get applications -n argocd --context k8s-{test|prod} | grep -E "monitoring|thanos|loki|alloy|blackbox"
   
   # Alle Pods im monitoring Namespace
   kubectl get pods -n monitoring --context k8s-{test|prod}
   
   # Grafana erreichbar
   curl -sI https://grafana-{test|prod}.eneg.de | head -5
   
   # CNPG Metriken vorhanden
   kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 --context k8s-{test|prod} \
     -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=cnpg_collector_up'
   
   # Loki Logs fliessen
   kubectl exec -n monitoring deploy/loki-gateway --context k8s-{test|prod} \
     -- wget -qO- 'http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/labels'
   
   # Blackbox NAS10 Probe
   kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 --context k8s-{test|prod} \
     -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success'
   ```

---

## 9. Referenzdateien (DEV als Vorlage)

Alle DEV-Dateien koennen 1:1 kopiert und angepasst werden:

| DEV-Datei | Aenderungen fuer TEST/PROD |
|-----------|---------------------------|
| `environments/dev/monitoring/values-override.yaml` | SMTP-From, Teams-Webhook-URL, PVC-Groesse (PROD) |
| `environments/dev/monitoring-secrets/kustomization.yaml` | Namespace bleibt `monitoring` |
| `environments/dev/monitoring-secrets/secret-generator.yaml` | Identisch |
| `environments/dev/monitoring-secrets/*.yaml.template` | S3-Bucket-Namen, Teams-URL, Grafana-PW |
| `environments/dev/monitoring-loki/values-override.yaml` | S3-Bucket-Name, PVC-Groesse (PROD) |
| `environments/dev/monitoring-loki-secrets/*` | S3-Credentials |
| `environments/dev/monitoring-thanos/values-override.yaml` | ggf. PVC-Groessen (PROD) |
| `environments/dev/monitoring-blackbox/values-override.yaml` | Identisch (NAS10 gleich fuer alle) |
| `environments/dev/monitoring-alerts/kustomization.yaml` | Identisch (base-Referenz) |
| `environments/dev/monitoring-ingress/ingress.yaml` | Hostname anpassen |
| `environments/dev/infrastructure/monitoring-*.yaml` | Pfade: dev→test/prod, ggf. targetRevision |
| `environments/dev/infrastructure/thanos-app.yaml` | Pfade: dev→test/prod |
| `environments/dev/infrastructure/loki-*.yaml` | Pfade: dev→test/prod |
| `environments/dev/infrastructure/alloy-app.yaml` | Pfade: dev→test/prod |
| `environments/dev/infrastructure/blackbox-exporter-app.yaml` | Pfade: dev→test/prod |

---

## 10. Bekannte Stolperfallen

- **Loki S3 Bucket hardcoded in base:** Muss per Override ueberschrieben werden (Abschnitt 6)
- **Grafana braucht Pod-Restart** nach Secret/ConfigMap-Aenderungen
- **StatefulSet Pods** (Thanos Store Gateway, Loki) brauchen `kubectl delete pod` fuer Spec-Updates
- **git pull --rebase** noetig wenn von k8s-mgmt-10 und lokalem Rechner parallel gepusht wird
- **ArgoCD synct alle 3 Minuten** — fuer schnellere Updates: ArgoCD UI → App → Refresh → Sync

---

*Erstellt: 09.04.2026*
