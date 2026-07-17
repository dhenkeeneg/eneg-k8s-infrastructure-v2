# Thanos-Query Sidecar-Discovery-Fix (base, alle drei Cluster)

**Status:** ABGESCHLOSSEN (DEV + TEST + PROD, 17.07.2026).
**Charakter:** Kleiner, migrationsunabhaengiger base-Fix. Vorbestehender Bug,
cluster-uebergreifend. NICHT Teil der DEV/TEST/PROD-Drift-Angleichung (P1-P5,
abgeschlossen). Nebenbefund aus P4a (Thanos NAS20).
**Bearbeiter:** Daniel Henke (git/ArgoCD), Claude (Dateien/Verifikation read-only).

---

## 1. Problem

`thanos-query` fand den Prometheus-Sidecar-Store nicht. Der in
`base/monitoring/thanos/values.yaml` referenzierte Discovery-Service
`kube-prometheus-stack-thanos-discovery` existierte in KEINEM der drei Cluster.
Der kube-prometheus-stack legt diesen Service nur an, wenn
`prometheus.thanosService.enabled: true` gesetzt ist - das war nirgends der Fall.

Folge:
- DNS-SRV-Aufloesung lief ins Leere
  (`failed to lookup SRV records ... no such host`, ~alle 30s).
- Query kannte nur die Storegateway (historische Bloecke aus S3/NAS20), NICHT
  den Sidecar-Store. Die juengsten ~2h (nur im Sidecar, noch nicht als Block in
  S3) fehlten in Query-Abfragen bzw. Grafana-Panels ueber die Thanos-Datasource.

## 2. Diagnose (live verifiziert, alle drei Cluster, 17.07.2026)

- `kube-prometheus-stack-thanos-discovery`: existiert in DEV/TEST/PROD NICHT.
- Realer headless-Service `prometheus-operated` (operator-verwaltet) vorhanden:
  `clusterIP: None`, Port `name: grpc` / 10901 - exakt das, was das DNS-SRV-
  Muster `_grpc._tcp` braucht.
- `thanos-query`-Args enthielten den Discovery-Endpoint DOPPELT (einmal aus
  `query.stores`, einmal aus `query.dnsDiscovery.sidecarsService`) - beide auf
  denselben nicht existierenden Service. SRV-Fehler daher 2x pro Zyklus.
- Storegateway-Endpoint funktionierte (Historie kam an).

## 3. Loesungsweg-Bewertung (Weg A vs. Weg B)

**Weg A** (`prometheus.thanosService.enabled: true` im kube-prometheus-stack):
erzeugt den referenzierten Service real - aber als ZUSAETZLICHEN headless-Service,
der denselben Sidecar-gRPC-Port exponiert wie das bereits vorhandene
`prometheus-operated`. Redundanter Service + loest einen Prometheus-StatefulSet-
Reconcile aus. Doppelter Endpoint bliebe.

**Weg B** (gewaehlt): `thanos/values.yaml` auf den bereits existierenden,
operator-verwalteten `prometheus-operated` umbiegen. Kein zusaetzlicher Service,
kein Prometheus-Reconcile (nur `thanos-query` startet neu), doppelter Endpoint
wird mit-bereinigt.

**Korrektur zur urspruenglichen Handoff-Annahme:** Der Einwand gegen Weg B
("prometheus-operated buendelt mehrere Ports, evtl. kein passend benannter
gRPC-Port") wurde durch die Live-Pruefung WIDERLEGT: Der Port ist explizit
`name: grpc` / 10901. Weg B ist damit voll tragfaehig und der sauberere Weg.
Deckt sich mit der Empfehlung in phase-14-p4a-thanos-nas20-test-prod.md (Abs. 6).

## 4. Umsetzung

Datei: `base/monitoring/thanos/values.yaml`, Block `query:`

Vorher:
```yaml
  stores:
    - dnssrv+_grpc._tcp.kube-prometheus-stack-thanos-discovery.monitoring.svc.cluster.local
  dnsDiscovery:
    enabled: true
    sidecarsService: kube-prometheus-stack-thanos-discovery
    sidecarsNamespace: monitoring
```

Nachher:
```yaml
  stores: []
  dnsDiscovery:
    enabled: true
    sidecarsService: prometheus-operated
    sidecarsNamespace: monitoring
```

- `sidecarsService` -> `prometheus-operated` (realer gRPC-Service).
- `stores: []` entfernt den doppelten `--endpoint`; der Sidecar-Endpoint wird
  bereits durch `dnsDiscovery.sidecarsService` erzeugt, der Storegateway-Endpoint
  kommt separat vom Chart. Ergebnis: genau 1 Sidecar + 1 Storegateway-Endpoint.

`base`-Change -> wirkt nach Sync auf alle drei Cluster.

## 5. Rollout

- commit/push (Daniel).
- Sync: DEV/TEST via Auto-Sync, PROD via selfHeal der Child-App
  `prod-monitoring-thanos` - alle drei zogen ohne manuellen Eingriff nach.
  Kein Hard-Refresh noetig gewesen (Args-Change loest thanos-query-Rollout aus).
- Nur `thanos-query` startete neu (je 1 Pod, Single-Replica). Prometheus
  unberuehrt (Weg B).

## 6. Verifikation (live, alle drei Cluster, 17.07.2026)

| Pruefpunkt | DEV | TEST | PROD |
|------------|-----|------|------|
| Query-Args: Sidecar -> `prometheus-operated` | OK | OK | OK |
| Doppelter Endpoint bereinigt (1 Sidecar + 1 Storegateway) | OK | OK | OK |
| Keine `failed to lookup SRV records` mehr | OK | OK | OK |
| Storegateway-Store "up" (Historie, keine Regression) | OK | OK | OK |
| Sidecar-Store "up" (juengste ~2h, vorher fehlend) | OK | OK | OK |
| Query-Pod 1/1 Running, 0 Restarts | OK | OK | OK |

Log-Beleg (je Cluster identisches Muster):
- `adding new store with [storeEndpoints]` -> Storegateway (10901).
- `adding new sidecar with [storeEndpoints rulesAPI exemplarsAPI targetsAPI
  MetricMetadataAPI]` -> Prometheus-Sidecar (10901). Genau dieser Store fehlte
  zuvor. Voller Feature-Satz (rules/exemplars/targets/metadata), nicht nur Store.

## 7. Lehren

- Chart-referenzierte Service-Namen nicht ungeprueft uebernehmen: der
  kube-prometheus-stack legt `*-thanos-discovery` nur bei
  `prometheus.thanosService.enabled: true` an. Ohne diesen Toggle ist
  `prometheus-operated` (immer vom Operator verwaltet) der korrekte gRPC-Store.
- `query.stores` + `query.dnsDiscovery.sidecarsService` mit demselben Ziel
  erzeugen doppelte `--endpoint`-Args. Bei Nutzung von dnsDiscovery gehoert der
  Sidecar-Eintrag NICHT zusaetzlich in stores.
- Live-Pruefung des tatsaechlichen Port-Namens (`grpc`) war ausschlaggebend fuer
  die Weg-A/B-Entscheidung - die Vorab-Annahme war falsch.

## 8. Offen / Nachlauf

- Sidecar-UPLOAD nach NAS20 erfolgt weiterhin beim naechsten regulaeren 2h-Cut
  (unabhaengig von diesem Fix; betrifft nur die Sichtbarkeit des Sidecar-STORES
  in Query, die jetzt gegeben ist).
- Keine weiteren offenen Punkte. Drift-Angleichung P1-P5 bleibt abgeschlossen;
  dieser Fix war der letzte migrationsunabhaengige Rest aus dem P4a-Nebenbefund.
