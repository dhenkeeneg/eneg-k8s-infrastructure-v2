# Phase 7 - Alert-Uebersicht und Testplan

**Erstellt:** 09.04.2026

---

## 1. Alert-Routing (Aktuelle Konfiguration)

### Empfaenger

| Kanal | Empfaenger | Typ |
|-------|-----------|-----|
| E-Mail | d.henke@eneg.de | SMTP via smtpout1.eneg.customers.hosting.zone:587 |
| Teams | eNeG K8s Dev v2 Monitoring | Power Automate Webhook (Adaptive Cards) |

### Routing-Regeln

| Severity | Empfaenger | Repeat-Intervall | Resolved-Notification |
|----------|-----------|-------------------|----------------------|
| **warning** | E-Mail + Teams | 4 Stunden | Ja (send_resolved: true) |
| **critical** | E-Mail + Teams | 1 Stunde | Ja (send_resolved: true) |

### Inhibit-Regel
Wenn ein **critical** Alert feuert, wird der zugehoerige **warning** Alert
fuer die gleiche Kombination aus `namespace` + `alertname` unterdrueckt.
Beispiel: Wenn `CnpgWalVolumeCritical` (85%) feuert, wird `CnpgWalVolumeWarning` (70%)
nicht mehr separat gesendet.

### Gruppierung
Alerts werden nach `namespace` + `alertname` gruppiert.
- `group_wait: 30s` — Wartezeit bevor erste Benachrichtigung
- `group_interval: 5m` — Wartezeit fuer neue Alerts in bestehender Gruppe

---

## 2. Custom Alerts (4 PrometheusRules)

### 2.1 CNPG Database Health (cnpg-alerts)

| Alert | Severity | Bedingung | For | E-Mail | Teams |
|-------|----------|-----------|-----|--------|-------|
| CnpgWalVolumeWarning | ⚠️ warning | WAL-Volume >= 70% | 5m | ✅ | ✅ |
| CnpgWalVolumeCritical | 🔴 critical | WAL-Volume >= 85% | 5m | ✅ | ✅ |
| CnpgClusterNotReady | 🔴 critical | cnpg_collector_up == 0 | 5m | ✅ | ✅ |
| CnpgReplicationLagWarning | ⚠️ warning | Replication Lag > 30s | 5m | ✅ | ✅ |
| CnpgReplicationLagCritical | 🔴 critical | Replication Lag > 120s | 5m | ✅ | ✅ |
| CnpgWalArchivingFailed | ⚠️ warning | WAL-Archiv Fehler in 5min | 5m | ✅ | ✅ |

### 2.2 Backup Health (backup-alerts)

| Alert | Severity | Bedingung | For | E-Mail | Teams |
|-------|----------|-----------|-----|--------|-------|
| CronJobFailed | ⚠️ warning | Job fehlgeschlagen (databases/odoo/garage) | 5m | ✅ | ✅ |
| CronJobOverdue | ⚠️ warning | Naechster Lauf > 2h ueberfaellig | 10m | ✅ | ✅ |
| BackupPodCrashLoop | 🔴 critical | > 3 Restarts in 10min | 5m | ✅ | ✅ |

### 2.3 S3 Endpoint + Infrastruktur (blackbox-infra-alerts)

| Alert | Severity | Bedingung | For | E-Mail | Teams |
|-------|----------|-----------|-----|--------|-------|
| S3EndpointDown | 🔴 critical | TCP Probe nas10.eneg.de:8010 failed | 5m | ✅ | ✅ |
| ArgoCdAppDegraded | 🔴 critical | App health != Healthy/Progressing | 15m | ✅ | ✅ |
| LonghornVolumeDegraded | ⚠️ warning | Volume Robustness == Degraded | 10m | ✅ | ✅ |
| LonghornVolumeFaulted | 🔴 critical | Volume Robustness == Faulted | 2m | ✅ | ✅ |

### 2.4 Thanos Health (thanos-alerts)

| Alert | Severity | Bedingung | For | E-Mail | Teams |
|-------|----------|-----------|-----|--------|-------|
| ThanosSidecarDown | 🔴 critical | Sidecar kann Prometheus nicht erreichen | 5m | ✅ | ✅ |
| ThanosCompactionFailed | ⚠️ warning | > 3 fehlgeschlagene Compactions/h | 5m | ✅ | ✅ |
| ThanosStoreGatewayErrors | ⚠️ warning | S3-Zugriffsfehler in 15min | 10m | ✅ | ✅ |

---

## 3. Wichtige Default-Alerts (kube-prometheus-stack)

Diese Alerts kommen aus den Standard-Rules des kube-prometheus-stack Charts:

| Alert | Severity | Bedingung | E-Mail | Teams |
|-------|----------|-----------|--------|-------|
| NodeMemoryHighUtilization | ⚠️ warning | Node Memory > 80% | ✅ | ✅ |
| NodeFilesystemSpaceFillingUp | ⚠️ warning | Disk Space Trend: voll in 24h | ✅ | ✅ |
| NodeFilesystemSpaceFillingUp | 🔴 critical | Disk Space Trend: voll in 4h | ✅ | ✅ |
| NodeFilesystemAlmostOutOfSpace | ⚠️ warning | Disk < 5% frei | ✅ | ✅ |
| NodeFilesystemAlmostOutOfSpace | 🔴 critical | Disk < 3% frei | ✅ | ✅ |
| KubePodCrashLooping | ⚠️ warning | Pod > 0 Restarts in 10min | ✅ | ✅ |
| KubePodNotReady | ⚠️ warning | Pod NotReady > 15min | ✅ | ✅ |
| KubeDeploymentReplicasMismatch | ⚠️ warning | Replicas != gewuenscht > 15min | ✅ | ✅ |
| KubeStatefulSetReplicasMismatch | ⚠️ warning | StatefulSet Replicas Mismatch | ✅ | ✅ |
| KubePersistentVolumeFillingUp | ⚠️ warning | PVC Trend: voll in 4 Tagen | ✅ | ✅ |
| KubePersistentVolumeFillingUp | 🔴 critical | PVC < 3% frei | ✅ | ✅ |
| KubeNodeNotReady | ⚠️ warning | Node NotReady > 15min | ✅ | ✅ |
| KubeNodeUnreachable | ⚠️ warning | Node Unreachable > 5min | ✅ | ✅ |
| Watchdog | none | Heartbeat (feuert immer, beweist dass Alerting funktioniert) | ✅ | ✅ |

**Hinweis:** Dies ist eine Auswahl der wichtigsten Default-Alerts. kube-prometheus-stack
installiert ~100 Default-Rules. Vollstaendige Liste in Grafana unter Alerting → Alert Rules.

---

## 4. Testplan

### 4.1 Schnelltest: AlertManager erreichbar

```bash
# AlertManager Status pruefen
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
sleep 2
curl -s http://localhost:9093/api/v2/status | python3 -c "import sys,json; d=json.load(sys.stdin); print('Cluster:', d['cluster']['status'])"
kill %1 2>/dev/null
```

### 4.2 E-Mail-Test: Watchdog Alert pruefen

Der `Watchdog`-Alert feuert permanent (DeadMansSwitch). Pruefe ob er ankommt:

```bash
# Aktive Alerts anzeigen — Watchdog sollte dabei sein
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
sleep 2
curl -s http://localhost:9093/api/v2/alerts | python3 -c "
import sys,json
alerts = json.load(sys.stdin)
for a in alerts:
    name = a['labels'].get('alertname','?')
    sev = a['labels'].get('severity','?')
    state = a['status']['state']
    print(f'{name} [{sev}] - {state}')
" | head -20
kill %1 2>/dev/null
```

Pruefe E-Mail-Postfach (d.henke@eneg.de) und Teams Channel auf Watchdog-Alerts.

### 4.3 Teams Webhook-Test (manuell)

```powershell
# PowerShell auf Windows-Laptop oder Management-Server
$uri = "TEAMS_WEBHOOK_URL"
$body = @{
    type = "message"
    attachments = @(
        @{
            contentType = "application/vnd.microsoft.card.adaptive"
            content = @{
                type = "AdaptiveCard"
                version = "1.2"
                body = @(
                    @{
                        type = "TextBlock"
                        text = "TEST: AlertManager Webhook Verbindung OK"
                        weight = "bolder"
                        size = "medium"
                        color = "good"
                    }
                )
            }
        }
    )
} | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body
```

### 4.4 Gezielter Alert-Test: Blackbox Probe

S3 Endpoint Probe testen durch temporaeres Aendern des Targets auf eine ungueltige Adresse:

```bash
# VORSICHT: Nur in DEV! Aendert Blackbox-Target temporaer
# 1. Aktuellen Probe-Status pruefen (sollte 1 = OK sein)
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' 2>/dev/null

# 2. Um den Alert auszuloesen:
#    - Blackbox values-override.yaml: Target URL auf ungueltige Adresse aendern
#    - Oder: NAS10 kurz stoppen (nur wenn moeglich)
#    - Nach ~5 Minuten sollte S3EndpointDown feuern
#    - E-Mail + Teams Benachrichtigung pruefen
#    - Danach Target zuruecksetzen → Resolved-Benachrichtigung pruefen
```

### 4.5 Gezielter Alert-Test: CNPG Cluster

```bash
# CNPG Cluster-Status pruefen
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=cnpg_collector_up' 2>/dev/null

# Um CnpgClusterNotReady auszuloesen (NUR IN DEV!):
# kubectl scale deployment cnpg-controller-manager -n cnpg-system --replicas=0
# → Nach 5min sollte Alert feuern
# → kubectl scale deployment cnpg-controller-manager -n cnpg-system --replicas=1
# → Resolved-Benachrichtigung pruefen
```

### 4.6 Test-Checkliste

| Test | Methode | Erwartung | Geprueft |
|------|---------|-----------|----------|
| AlertManager erreichbar | port-forward + curl | Cluster Status OK | [ ] |
| Watchdog in Active Alerts | AlertManager API | Watchdog [none] - active | [ ] |
| E-Mail Empfang | Postfach d.henke@eneg.de | Watchdog oder andere Alerts | [ ] |
| Teams Empfang | eNeG K8s Dev v2 Monitoring | Watchdog oder andere Alerts | [ ] |
| Resolved-Notification | Alert ausloesen + beheben | "Resolved" Nachricht | [ ] |

---

## 5. Zusammenfassung Alert-Zahlen

| Kategorie | Anzahl | Warning | Critical |
|-----------|--------|---------|----------|
| CNPG Database Health | 6 | 3 | 3 |
| Backup Health | 3 | 2 | 1 |
| S3/Infra/Longhorn | 4 | 1 | 3 |
| Thanos Health | 3 | 2 | 1 |
| **Custom Gesamt** | **16** | **8** | **8** |
| kube-prometheus-stack Defaults | ~100 | ~70 | ~30 |
| **Gesamt** | **~116** | | |

Alle Alerts gehen an **beide Kanaele** (E-Mail + Teams).
Critical Alerts werden **stuendlich** wiederholt, Warning Alerts alle **4 Stunden**.

---

*Erstellt: 09.04.2026*
