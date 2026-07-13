# Incident: Host-I/O-Stall ESXi s3168 -> Longhorn-Replica-Faults k8s-prod-23 (2026-07-13)

**Status:** analysiert; Gegenmassnahme (Longhorn) ausgerollt am 2026-07-13. Storage-Ursache auf ESXi s3168 noch offen (vSphere-seitig).
**Umgebung:** k8s-prod (k8s-prod-21/22/23, K3s v1.35.1, Longhorn v1.9.2)
**Schweregrad:** niedrig-mittel — kein Datenverlust, Cluster hat sich selbst erholt; erhoehte I/O-Last durch Rebuilds auf einem Node.

## Zusammenfassung

Zwei kurze, host-weite Storage-I/O-Stalls auf dem ESXi-Host s3168.eneg.de haben am
2026-07-13 gegen 12:36 und 12:54 UTC (14:36 / 14:54 Berliner Zeit) die VM-Disk-Latenz
fast aller VMs dieses Hosts massiv ansteigen lassen. k8s-prod-23 (liegt als einzige der
drei PROD-Nodes auf s3168) war mitbetroffen. In der Folge markierte die Longhorn-Engine
wiederholt Replicas auf k8s-prod-23 als 'error' (Fault) und baute sie neu auf
(Rebuild-Wellen ab ~13:04 UTC). Alle betroffenen Volumes waren nach den Rebuilds wieder
healthy. Kein Datenverlust, keine Pod-Ausfaelle.

## Betroffene Workloads

Longhorn-Volumes mit Replica auf k8s-prod-23 (Replica-Fault + Rebuild), u.a.:
- kube-prometheus-stack-grafana (50Gi)
- storage-loki-0 (20Gi)
- prometheus-kube-prometheus-stack (Volume)
- garage-meta-garage-0/1/2 (je 1Gi)

Auswirkung auf Anwendungsebene: keine sichtbaren Ausfaelle. Volumes blieben ueber die
verbleibenden Replicas (Node 21/22) verfuegbar; die Rebuilds liefen im Hintergrund.

## Ursachenkette

### Beobachtung 1 — Faults nur auf k8s-prod-23

kubectl-Events (longhorn-system) zeigten ab 13:04 UTC im Raster von ~22 Minuten
wiederholte `Faulted`-Events: "Detected replica ... (10.42.2.199:...) in error".
Die IP 10.42.2.199 ist der Instance-Manager auf k8s-prod-23. Node 21/22 zeigten
keine Faults. Alle betroffenen Volumes waren zum Untersuchungszeitpunkt bereits
wieder attached/healthy (erfolgreiche Rebuilds).

### Beobachtung 2 — Ursache liegt auf ESXi-Host-Ebene (vCenter-Metriken)

Auswertung ueber Grafana/vCenter (alloy-vcenter, DEV-zentral, deckt alle VMs ab):
- Die 3 PROD-Nodes liegen bewusst auf 3 verschiedenen ESXi-Hosts:
  k8s-prod-21 -> s2842, k8s-prod-22 -> s2843, k8s-prod-23 -> **s3168**.
- `vcenter_vm_disk_latency_max/avg_milliseconds` fuer k8s-prod-23 zeigte zwei
  Plateaus (avg UND max, je ~5 Min stabil -> kein Scrape-Artefakt):
  - ~12:36-12:40 UTC: 470 ms
  - ~12:54-12:58 UTC: 665-668 ms
- `vcenter_host_disk_latency_max_milliseconds{s3168}` bestaetigte den Stall auf
  HOST-Ebene (689 ms um 12:54). s2842/s2843 durchgehend 0-9 ms.
- Host-weit betroffen: Zu beiden Zeitpunkten sahen ~10 bzw. ~23 VMs auf s3168
  gleichzeitig >100 ms Latenz. Spitzen bei anderen VMs bis ~6748 ms (M365-MIGRATION),
  6675 ms (TSFS02), 6601 ms (SQL01). k8s-prod-23 war mit 665 ms vergleichsweise
  gering betroffen. Auch der Veeam-Proxy VBR-Proxy-S3168 lag mit 4300 ms in der Welle.

Schlussfolgerung: host-/datastore-weiter I/O-Stall auf s3168, nicht k8s-spezifisch.
Der Longhorn-Fault ist die FOLGE, nicht die Ursache.

### Beobachtung 3 — Kapazitaet ausgeschlossen

Datastores auf s3168 unauffaellig (S3168_SSD_01_VMS ~32%, S3168_HDD_01_VMS ~27%).
Longhorn-Disk auf k8s-prod-23 ~655 GB frei. Kein Platzproblem.

### Ausgeschlossene Ursachen

- **Veeam-Backup:** Zur fraglichen Zeit lief laut Betreiber KEIN Veeam-Vorgang (geprueft).
- **VM-Snapshot vcenter-b:** Ein manueller Snapshot wurde 12:14 UTC erstellt, zeitlich
  22-40 Min vor den Stalls und damit als direkter Ausloeser unplausibel. Zudem war das
  Ereignis host-weit (nicht auf die Snapshot-VM begrenzt).

### Offene Ursache (vSphere-seitig)

Warum s3168 zu diesen zwei Zeitpunkten host-weit einbrach, ist storage-seitig noch
nicht geklaert. Kandidaten fuer die weitere Analyse (ESXi-Host-Logs / RAID-Controller
/ SSD-Health von s3168 um 12:36 und 12:54 UTC): Datastore-/RAID-Ereignis, Pfad-Flapping,
oder ein nicht ueber Veeam laufender I/O-intensiver Vorgang.

## Gegenmassnahme (k8s-seitig, ausgerollt 2026-07-13)

Longhorn `engineReplicaTimeout` von Default 8s (Minimum) auf 16s erhoeht (Range v1.9.2: 8-30).
Das ist der Timeout, nach dem die Engine eine nicht antwortende Replica als 'error'
markiert. 16s gibt kurzen Host-/Datastore-Latenzspitzen (mehrere Sekunden I/O-Stall)
Zeit, sich zu loesen, bevor ein Fault + Rebuild ausgeloest wird. Ergaenzt die bestehende
Storm-Protection (`concurrentReplicaRebuildPerNodeLimit: 2`,
`replicaReplenishmentWaitInterval: 600`).

**Aenderung (GitOps):**
- Datei: `kubernetes/base/longhorn/values.yaml` -> `defaultSettings.engineReplicaTimeout: 16`
- Gilt fuer DEV/TEST/PROD (Base-Wert, alle drei Umgebungen erben ihn).
- Nicht disruptiv: keine Pod-Restarts, keine Volume-Detach. Wirkt auf neue
  Replica-Verbindungen.

**Rollout (gestaffelt DEV -> TEST -> PROD, mit Verifikation):**
- DEV: hard-refresh + sync, `engine-replica-timeout=16` bestaetigt, alle Volumes healthy.
- TEST: hard-refresh + sync, `engine-replica-timeout=16` bestaetigt, alle Volumes healthy.
- PROD: hard-refresh + sync, `engine-replica-timeout=16` bestaetigt, alle 33 attachten
  Volumes healthy, ArgoCD Synced/Healthy.

Verifikationsbefehl (je Umgebung):
`kubectl get settings.longhorn.io engine-replica-timeout -n longhorn-system --context k8s-{env}`

## Bewertung / Lessons Learned

- k8s-prod ist gesund; kein Konfigurationsfehler auf Kubernetes-Seite. Longhorn hat
  korrekt reagiert (Fault -> Rebuild -> healthy).
- Die 3-Node-auf-3-Hosts-Verteilung der PROD-Nodes hat sich bewaehrt: Nur die eine VM
  auf dem gestressten Host war betroffen, das Volume blieb ueber die anderen Replicas
  verfuegbar.
- Ein zu niedriger `engineReplicaTimeout` (Default 8s) macht Longhorn empfindlich gegen
  kurze Host-Latenzspitzen. Auf gemeinsam genutzten vSphere-Datastores ist ein hoeherer
  Wert (hier 16s) robuster.
- **Offen (Nicht-k8s):** Storage-Ursache des host-weiten I/O-Stalls auf ESXi s3168
  klaeren (ESXi-Host-Logs / RAID / SSD-Health um 12:36 und 12:54 UTC).
- **Empfehlung Monitoring:** Alert auf `vcenter_host_disk_latency_max_milliseconds`
  je ESXi-Host erwaegen (Schwelle z.B. > 100 ms ueber mehrere Minuten), um solche
  host-weiten Stalls frueh zu erkennen.

## Referenzen

- `kubernetes/base/longhorn/values.yaml` (Kommentar bei `engineReplicaTimeout`)
- Verwandt: `docs/incidents/2026-05-11-mariadb-galera-recovery.md` (Storm-Protection-Settings)
- Verwandt: `docs/incidents/2026-06-29-cnpg-wal-deadlock-longhorn-kaskade.md` (I/O-Kaskade)
