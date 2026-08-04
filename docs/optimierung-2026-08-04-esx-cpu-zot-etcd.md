# Optimierung DEV: ESXi-CPU-Last, zot-Registry & etcd-Monitoring

**Datum:** 04.08.2026
**Umgebung:** DEV (VLAN 180)
**Ausloeser:** ESXi-Host `esx-test.eneg.de` durchgehend 88-99% CPU, obwohl in den
Clustern k8s-dev/k8s-test nicht aktiv gearbeitet wird (nur Monitoring laeuft).

## Ausgangslage / Symptom

- Beide Cluster (k8s-dev, k8s-test) laufen mit allen drei Nodes auf **einem** ESXi-Host.
- Host-CPU dauerhaft > 90%, keine aktive Nutzung der Anwendungen.
- Erste Vermutung: Kyverno bzw. Trivy voruebergehend deaktivieren.

## Untersuchung & Ursache

Analyse ueber kubectl (MCP) und Prometheus/Grafana (DEV):

- **Hauptverursacher: `registry-zot`** (3 Pods) - jeder Pod lief durchgehend am
  CPU-Limit (1 Core), im Leerlauf, zusammen **~2,9 Cores**. 7-Tage-Verlauf flach.
- **Kyverno ~20m, Trivy-Operator ~6m** - vernachlaessigbar, NICHT die Ursache.
- **Root-Cause (final):** die zot-**`sync`-Extension**, konkret der **pollInterval-Mirror**
  (ghcr `dhenkeeneg/**` alle 15 Min gegen das S3-Backend nas20), verursacht den Dauer-Busy-Loop.
  Logs zeigten nur Health-Probes.
- **Korrektur:** Zuerst wurde `search`/CVE vermutet und deaktiviert - das war ein Trugschluss.
  Das CPU-Abfallen fiel mit einem Pod-Neustart zusammen; mit deaktiviertem search rampte die
  Last spaeter wieder auf ~1 Core/Pod hoch. Erst das Entfernen des pollInterval-Mirrors
  (bei erhaltenem onDemand-Pull-Through) senkte zot **dauerhaft** auf ~4m/Pod (25 Min stabil).
- Gegenprobe: k8s-test hat **keine** zot-Registry und lag entsprechend niedriger.

## ESXi-Host-Analyse (vCenter-Metriken)

- Alle **sechs** k8s-VMs (dev+test) liegen auf `esx-test.eneg.de` (~28,7 GHz, kleiner Host).
  Summierter VM-Bedarf ~28,9 GHz ~= Host-Kapazitaet -> daher 88-99%.
- `esx1.eneg.de` (~30,3 GHz, vergleichbar) laeuft < 10% - aber **verplant**,
  daher ist ein VM-Rebalancing **keine Option**.
- **CPU-Ready** aller VMs = 0% -> echter Rechenbedarf, keine Overcommit-Contention.
  Last reduzieren senkt den Host also linear.
- **"Idle != lastfrei":** Die Plattform-Grundlast betraegt inhaerent ~2-3 Cores je
  3-Node-Cluster (Prometheus, Longhorn, etcd/Control-Plane, ArgoCD, diverse Operatoren).
  Nicht normal war nur zot mit ~2,9 Cores obendrauf.

## Massnahmen (GitOps)

| Schritt | Aenderung | Effekt |
|--------|-----------|--------|
| Zwischenschritt | zot `replicaCount` 3 -> 1 | ~1,9 Cores frei (temporaer) |
| Irrweg | zot `search` + `ui` = false | schien zu wirken, war aber Neustart-Artefakt - Last kam zurueck |
| HA zurueck | zot auf **2 Replicas** | - |
| **Eigentlicher Fix** | zot `sync` **pollInterval-Mirror entfernt**, onDemand-Pull-Through bleibt | zot dauerhaft **~4m/Pod** (~8m gesamt) |

- **Ergebnis:** `esx-test` von 88-99% auf im Mittel **~65-75%**; einzelne Lastspitzen erreichen
  weiterhin ~85-90% (inhaerente Grundlast des kleinen Hosts, nicht mehr zot).
- `search`/`ui` bleiben deaktiviert (nicht benoetigt, schaden nicht).
- Kyverno / Trivy-Operator bewusst **nicht** abgeschaltet (Policy/Security > ~26m Ersparnis).

## Storage-Check (Nebenbefund)

- Datastore-Latenz 0-2 ms, Node-IO-Wait 1-3,5% -> **gesund**.
- Das in den Alerts erwaehnte strukturelle ~200ms-Thema trat aktuell nicht auf.

## Monitoring-Datenluecke im vSphere-Dashboard

- **Ursache:** Der ESXi-Host wurde am 03.08.2026 morgens umbenannt und neu in vCenter
  eingebunden. Dadurch aenderte sich der `vcenter_host`-Label (IP -> DNS):
  `192.168.160.70` -> `esx-test.eneg.de`, `192.168.160.10` -> `esx1.eneg.de`.
  Die alte Zeitreihe endete, eine neue begann -> im Dashboard "seit 03.08. keine Daten".
- **Fix:** Dashboard-Host-Variable war auf dem alten (IP-)Wert gepinnt; Umstellung
  auf die DNS-Namen behebt es. Daten flossen die ganze Zeit unter neuem Namen.
- **Lehre `label_replace`:** Ein Merge alter IP- und neuer DNS-Serie via `label_replace`
  funktioniert in **roher PromQL**, bricht aber die **Grafana-Panels** in Kombination mit
  der `$host`-Variable (No data / Fehler). Daher **verworfen**. Die IP/DNS-Trennung heilt
  sich ohnehin ueber die 7-Tage-Retention der DEV-Prometheus.

## etcd-Monitoring etabliert

- etcd-**Server**-Metriken (fsync/commit) wurden bislang **nicht** gescraped
  (nur `etcd_request_*` vom apiserver und `k3s_etcd_snapshot_*`).
- k3s exponiert die Metriken bereits: `etcd-expose-metrics: true` (Ansible k3s-config)
  auf `http://<node>:2381/metrics` (HTTP, ohne TLS).
- **Sackgasse `kubeEtcd.endpoints`:** ArgoCD schliesst die Ressource `/Endpoints` per
  `resource.exclusions` aus (ExcludedResourceWarning) -> das manuelle Endpoints-Objekt
  wird nie angewandt, bleibt leer.
- **Loesung:** `prometheus.prometheusSpec.additionalScrapeConfigs` mit `static_configs`
  auf die Node-IPs `192.168.180.21/22/23:2381` (job `kube-etcd`). Unabhaengig von
  Endpoints-Objekten. `kubeEtcd`-Exporter deaktiviert.
- **Ergebnis (gesund):** fsync p99 21=5,2 / 22=2,9 / 23=3,8 ms; commit p99
  21=5,8 / 22=3,3 / 23=4,0 ms (Richtwerte fsync < 10 ms, commit < 25 ms).

## esx1 aus Monitoring & Dashboard entfernt

Auf Wunsch (esx1 ist verplant, kein k8s-Bezug):

- **alloy-vcenter:** neuer `otelcol.processor.filter "drop_esx1"` in der vcenter-b-Pipeline
  verwirft alle Datapoints mit `vcenter_host == "esx1.eneg.de"` (Host + VMs darauf),
  bevor sie an Prometheus gehen.
- **Dashboard:** Host-Variable schliesst `esx1.eneg.de` und die alte IP `192.168.160.10`
  per `!~` aus.
- Hinweis: Ein evtl. eigener esx1-**Datastore** (Label `vcenter_datastore`) bleibt sichtbar,
  da der Filter ueber `vcenter_host` greift.

## Geaenderte Dateien (alle DEV)

- `kubernetes/environments/dev/registry/values-override.yaml` (replicaCount 3->2, search/ui=false, sync-pollInterval-Mirror entfernt = eigentlicher Fix)
- `kubernetes/environments/dev/monitoring/values-override.yaml` (kubeEtcd=false, additionalScrapeConfigs)
- `kubernetes/environments/dev/monitoring-alerts/vsphere-hosts-dashboard-cm.yaml` (Host-Variable, esx1-Ausschluss)
- `kubernetes/environments/dev/alloy-vcenter/values.yaml` (Filter drop_esx1)

## Offene Punkte / Empfehlung

- **Struktureller Hebel:** Der eigentliche Engpass ist die Groesse von `esx-test`
  (zwei komplette Cluster auf einem ~12-Thread-Host). Nachhaltig hilft nur mehr physische
  CPU (groesserer Host / esx1 freibekommen). Solange esx1 verplant ist, ist ~75% der
  realistische Betriebspunkt.
- Betroffen ist nur **DEV**: die zot-Registry existiert nur in DEV, das vCenter-Monitoring
  (alloy-vcenter) laeuft vorerst nur in DEV.
- Weitere K8s-seitige CPU-Einsparungen wuerden Beobachtbarkeit oder Resilienz kosten und
  sind daher nicht empfohlen ("Stabilitaet vor Geschwindigkeit").
