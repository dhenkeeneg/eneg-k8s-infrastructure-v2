# Wartung: ESXi s3168 Reboot -> Drain/Shutdown k8s-prod-23 (2026-07-21)

**Status:** Abgeschlossen, Cluster verifiziert sauber.
**Umgebung:** k8s-prod (Node k8s-prod-23 auf ESXi s3168.eneg.de)
**Art:** Geplante Host-Wartung (kurzzeitiges Herunterfahren s3168 fuer wenige Minuten)
**Ausfuehrung:** Node-Vorbereitung (cordon + Evakuierung zustandsloser Pods) via
Kubernetes-MCP durch Claude; VM- und Host-Shutdown/Boot durch Daniel via vSphere-GUI.

## Anlass

Kurzzeitiges Herunterfahren des ESXi-Hosts s3168 zu Wartungszwecken. Auf s3168 liegt
die K8s-VM k8s-prod-23. Der Reboot aktiviert zugleich die am 21.07. gestagte
perccli-Komponente (siehe verwandter Incident), wodurch die dort offene
Einzelplatten-Verifikation moeglich wird.

## Vorab-Pruefung (Ist-Zustand vor Eingriff)

- Alle drei PROD-Nodes `Ready`; k8s-prod-23 traegt control-plane/etcd (etcd 3/3).
- CNPG-Primaries lagen NICHT auf k8s-prod-23:
  - cnpg-erp Primary = cnpg-erp-2 (k8s-prod-22)
  - cnpg-shared Primary = cnpg-shared-1 (k8s-prod-21)
  - Auf k8s-prod-23 nur Replicas (cnpg-erp-1, cnpg-shared-2).
- MariaDB Galera: 3 Member ueber alle Nodes verteilt -> 2/3-Quorum bleibt beim Wegfall 23.
- Longhorn-Analyse (entscheidend): Die 5 Single-Replica-Volumes, deren einzige Replica
  auf k8s-prod-23 liegt, gehoeren AUSSCHLIESSLICH zu den DB-Pods, die selbst auf 23 laufen
  (cnpg-erp-1 + WAL, cnpg-shared-2 + WAL, storage-mariadb-galera-2). Kein fremder Pod auf
  21/22 haengt an einer Single-Replica auf 23. -> Drain gefahrlos.
- Alle 3-Replica-Volumes tolerieren den Ausfall von 23 (2 Replicas bleiben).

## Ablauf

1. **cordon** k8s-prod-23 (MCP) -> unschedulable.
2. **Evakuierung zustandsloser Pods** (MCP, `kubectl delete pod`, pro Namespace):
   argocd (5), kube-system coredns+metrics-server (3), monitoring Deployments
   (grafana, kube-state-metrics, msteams, blackbox, thanos-compactor), metallb controller,
   traefik, cert-manager, garage-webui, it-info-versand, mariadb-operator-webhook,
   openproject-hocuspocus. Alle sauber auf 21/22 neu gescheduled (keine Pending).
3. **Bewusst NICHT evakuiert:** StatefulSet-Pods mit lokalem Longhorn-Volume
   (cnpg-erp-1, cnpg-shared-2, mariadb-galera-2, garage-0/1, loki-0, alertmanager-0,
   loki-results-cache-0) sowie DaemonSets. Diese wurden mit dem VM-Shutdown gestoppt
   (Vorgehen laut User-Praeferenz: kein harter Drain der DB-Pods).
4. **VM-Shutdown k8s-prod-23** (Daniel, vSphere Guest-Shutdown), dann **Host s3168**.
5. **Host + VM Wiederanlauf** (Daniel), danach **uncordon** (MCP).

## Wiederanlauf-Verifikation (nach uncordon)

- **Node:** k8s-prod-23 `Ready`, `EtcdIsVoter=True`, keine Pressure-Conditions,
  etcd-Quorum wieder 3/3.
- **CNPG:** Beide Cluster nach WAL-Replay/Catch-up wieder `Cluster in healthy state`,
  3/3 ready. Primaries unveraendert auf 21/22 (kein Failover ausgeloest). Die beiden
  Replicas auf 23 durchliefen erwartungsgemaess PG crash recovery (SQLSTATE 57P03
  "the database system is starting up") bis 2/2.
- **Galera:** mariadb-galera-2 via IST rejoined (kein SST), alle 3 Member 2/2;
  Operator meldet `GaleraReady=True`.
- **Longhorn:** Nach Wiederkehr zunaechst mehrere 3-Replica-Volumes `degraded`
  (Replica auf 23 out-of-sync) -> automatischer Rebuild, gedrosselt via
  `concurrent-replica-rebuild-per-node-limit=2` (kein I/O-Storm auf shared Datastore).
  Letztes Volume (Prometheus-TSDB, pvc-e7a8e4d5) zog am laengsten nach; Rebuild lief
  sauber durch (beobachtet 85 -> 88 -> 100 %). Endzustand: **alle 33 Volumes healthy.**

## Beobachtungen / Hinweise

- **Kernel-Sprung k8s-prod-23:** Beim Reboot von `6.8.0-111` auf `6.8.0-136` gehoben.
  Kernel-Stand PROD jetzt: prod-21 = 6.8.0-134, prod-22 = 6.8.0-111 (unveraendert alt),
  prod-23 = 6.8.0-136. -> **k8s-prod-22 ist der einzige verbliebene alte Kernel.**
  Angleichung von 22 bei naechster Gelegenheit empfohlen (bekanntes Thema "Node kernel
  alignment").
- **Rebuild-Retries:** Die Replica auf 23 zeigte rebuildRetryCount=5 (fruehere Anlaeufe
  durch I/O-Stalls). Passt exakt zum s3168-RAID-Latenz-Rootcause; kein neuer Defekt.
- **perccli-Aktivierung:** Dieser Reboot aktiviert die am 21.07. auf s3168 gestagte
  perccli-Komponente. -> Die im Rootcause-Incident offene Einzelplatten-Verifikation
  (`perccli /c0 /eall /sall show all`, Media/Other-Error-Count, Verdacht Bay 6 HDD)
  ist jetzt durchfuehrbar.

## Bewertung

Node-Wartung ohne Datenverlust, ohne Failover, ohne manuellen DB-Eingriff. Vorgehen
(cordon + selektive Evakuierung, DB-Pods mit VM stoppen) hat sich bewaehrt und ist als
Muster fuer geplante Einzelnode-Wartung in PROD wiederverwendbar.

## Referenzen

- Rootcause s3168: `docs/incidents/2026-07-21-s3168-raid-latency-rootcause-prod.md`
- Vorlaeufer I/O-Stall: `docs/incidents/2026-07-13-s3168-io-stall-longhorn-faults-prod.md`
- Longhorn engineReplicaTimeout 16s: `kubernetes/base/longhorn/values.yaml`
