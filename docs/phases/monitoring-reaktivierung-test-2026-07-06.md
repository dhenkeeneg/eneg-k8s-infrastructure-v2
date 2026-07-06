# Monitoring-Reaktivierung TEST + Loki Retention-Enforcement

**Datum:** 06.07.2026
**Bearbeiter:** Daniel Henke
**Scope:** TEST (Monitoring-Reaktivierung), DEV+TEST (Loki Retention-Enforcement, base)
**Status:** ABGESCHLOSSEN (PROD offen - Cluster war aus)

---

## 1. Ausgangslage

Nach der TEST-Node-Migration auf den neuen VMware-Host (192.168.160.70) und
dem kube-vip-Rollout sollte der Monitoring-Stack in TEST wieder auf DEV-Stand
gebracht werden. Bei der Ist-Analyse zeigten sich drei Befunde.

## 2. Befund A: Kern-Stack durch pausierten application-controller degradiert

**Symptom:** Prometheus + Alertmanager standen auf `replicas: 0` (keine
Metrik-Speicherung, keine Alerts), obwohl weder base noch TEST-Override das
vorsahen (Chart-Default = 1). Die `monitoring`-App hing seit 06.05.2026 in
einem PreSync-Hook (`waiting for completion of hook .../admission`), retryCount 5.

**Wurzelursache:** Der `argocd-application-controller` (StatefulSet) stand auf
`0/0` - er war fuer die Node-Migration bewusst pausiert (dokumentiertes Muster:
Reconciliation cluster-weit anhalten). Ohne Controller wurde kein Refresh
verarbeitet, keine Sync-Operation beendet, kein selfHeal ausgefuehrt. Daher
konnte die manuell auf 0 gesetzte replicas-Zahl nicht zuruecksetzen und der
alte Sync-Hook nie abgeschlossen werden.

**Loesung:**
1. `kubectl -n argocd scale statefulset argocd-application-controller --replicas=1`
   -> Controller reconciled sofort alle TEST-Apps, heilt Migrations-Reste
   (thanos ComparisonError, mariadb-cluster, cnpg-logical-backup, openproject
   gingen von Degraded/Progressing auf Healthy).
2. Prometheus/Alertmanager kamen NICHT von allein auf 1: Der kube-prometheus-
   stack rendert `replicas` nur, wenn es in den Values steht - sonst sieht
   ArgoCD keinen Diff auf das im Live-CR manuell gesetzte `spec.replicas: 0`
   (unter ServerSideApply besonders tueckisch). **Git-Haertung noetig.**

**Git-Haertung (environments/test/monitoring/values-override.yaml):**
- `prometheus.prometheusSpec.replicas: 1`
- `alertmanager.alertmanagerSpec.replicas: 1`
Damit ist der Sollwert deterministisch verankert und driftet bei kuenftigen
Pausen nicht mehr unbemerkt weg. Ergebnis: prometheus-0 3/3, alertmanager-0 2/2.

**Lesson:** Ein manuell (oder per Pause-Prozedur) auf 0 gesetztes Prometheus/
Alertmanager-`replicas` wird von ArgoCD NICHT geheilt, wenn der Wert nicht in
den Helm-Values steht (Chart laesst das Feld sonst weg -> kein Diff). Wer
Prometheus/Alertmanager fuer eine Migration herunterfaehrt, sollte den Sollwert
(1) explizit in den Values haben oder das Herunterfahren ueber Git machen.

## 3. Befund B: Loki-CrashLoop (NAS20-CA)

Siehe `phase-14-s3-migration-nas10-nas20.md`, Abschnitt "14b TEST - Loki auf
NAS20". Kurz: fehlendes `/etc/ca/ca.crt` (CA-Volume in TEST nie gemountet),
behoben durch Cutover auf NAS20/HTTPS analog DEV (CA-Secret + Credentials +
Volume-Mount). Falsche Annahme "ca_file inert bei insecure:true" korrigiert.

## 4. Befund C -> Massnahme: Loki Retention-Enforcement (base, alle Envs)

**Befund:** Bei der Loki-Arbeit fiel auf, dass weder base noch die
gerenderte Runtime-Config einen `compactor`-Block mit `retention_enabled`
enthielt. `limits_config.retention_period` (DEV 120h, base 2160h) war gesetzt,
aber **wirkungslos** - ohne aktivierten Compactor-Retention loescht Loki NICHTS
(der Compactor macht dann nur Index-Compaction). Das betraf DEV genauso wie TEST.

**Recherche (Loki 3.6.7 / Chart grafana/loki 6.55.0):**
- retention_enabled muss true sein, sonst nur Tabellen-Compaction.
- **delete_request_store ist ab Loki 3.0 PFLICHT bei retention_enabled:true** -
  sonst CONFIG ERROR beim Start + CrashLoopBackOff
  (Grafana-Doku; GitHub grafana/loki #12588).
- Voraussetzung Index-Period 24h erfuellt (schema v13, tsdb).

**Massnahme (base/monitoring/loki/values.yaml, unter `loki:`):**
```
compactor:
  retention_enabled: true
  delete_request_store: s3
  working_directory: /var/loki/retention
  retention_delete_delay: 2h
```
Bewusst in base (gilt fuer alle Envs). Wirkung je Env ueber `retention_period`:
DEV/TEST 120h (5d, Env-Override), PROD erbt aktuell base 2160h (90d).

**Rollout (Weg 1 - base-Push + gestaffelter Sync):**
- base gepusht; DEV + TEST loki-Apps (beide automated/selfHeal) zogen die
  Aenderung. Beide loki-0 sauber neu gestartet, KEIN CrashLoop (delete_request_store
  war korrekt gesetzt). Gerenderte ConfigMap in beiden Envs enthaelt den
  compactor-Block; Log zeigt "chosen to run the compactor, starting compactor".
- PROD: Cluster war aus -> Rollout offen. base-Aenderung ist in Git; loki
  zieht sie beim naechsten PROD-Start automatisch.

**Lesson:** `retention_period` allein loescht nichts. Retention-Enforcement
braucht den Compactor mit `retention_enabled: true` UND `delete_request_store`
(ab Loki 3.0 Pflicht, sonst CrashLoop). `retention_delete_delay: 2h` als
Sicherheitspuffer gegen versehentliche Fehlkonfiguration.

## 5. Offene Folgepunkte

- **(a) PROD Monitoring-Reaktivierung + Retention:** Bei PROD-Start pruefen,
  ob Prometheus/Alertmanager replicas korrekt (ggf. gleiche Git-Haertung im
  PROD-Override noetig, falls dort ebenfalls auf 0). loki zieht Retention-
  Enforcement automatisch aus base.
- **(b) PROD Loki-Retention-Wert:** WICHTIGER WIDERSPRUCH zur Phase-14-
  Entscheidung "PROD 10 Tage". PROD hat KEIN retention_period-Override und
  wuerde base 2160h (90d) erben. Vor/bei PROD-14c: `retention_period: 240h`
  (10d) im PROD-Loki-Override setzen. Siehe phase-14 Kernentscheidungen.
- **(c) Erster Retention-Lauf beobachten (DEV/TEST):** In DEV lagen bislang
  unbegrenzt Logs (nie geloescht). Erster Compaction-Lauf loescht alles >120h -
  ggf. sichtbarer NAS20-Bucket-Rueckgang. In TEST erst in 5 Tagen sichtbar.
- **(d) 14b uebrige TEST-Dienste:** siehe phase-14 (Velero, MariaDB, CNPG,
  Thanos, Registry, Backups) - Loki war nur Dienst 1.
