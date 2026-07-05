# Incident: Longhorn Orphan-Ansammlung -> DiskPressure -> Attach-Deadlock (2026-07-05)

**Status:** abgeschlossen am 2026-07-05
**Umgebung:** k8s-dev (k8s-dev-21/22/23, K3s v1.35.1, Longhorn v1.9.2)
**Dauer Recovery:** ca. 1,5 Stunden (gestaffelt, mit Verifikation zwischen den Phasen)
**Schweregrad:** hoch — Prometheus 6h+ ohne Storage (kein DEV-Monitoring), aber kein Datenverlust

## Betroffene Workloads

- **prometheus** (kube-prometheus-stack) — Volume 6h17m nicht attachbar, Pod in Init:0/1
- **thanos-compactor** — Volume nicht attachbar, Pod ContainerStatusUnknown
- **alloy-vcenter** — Folgefehler: `connection refused` beim remote_write an Prometheus
- **k8s-dev-22** — Node komplett leer-evicted (DiskPressure-Taint NoSchedule)
- diverse Volumes voruebergehend degraded (fehlende 3. Replica von Node 22)

## Ausloeser und Ursachenkette

### Stufe 0 — Ansammlung verwaister Replica-Verzeichnisse (ab ~02.07.)

Auf k8s-dev-22 sammelten sich ab dem 02.07. verwaiste Longhorn-Replica-Verzeichnisse
unter `/var/lib/longhorn/replicas/` an. Longhorn hatte sie korrekt als `orphan`-CRs
mit `DataCleanable=True` erkannt. Auffaellig: Mehrfach-Kopien desselben Volumes auf
DEMSELBEN Node, u.a.:
- pvc-fc854505 (thanos-compactor, 30Gi): VIER Verzeichnisse = 120 GB
- pvc-5a7a95a6 (prometheus, 25Gi): ZWEI Verzeichnisse (41 GB + 25 GB) = 66 GB

Wichtige Erkenntnis: Das Setting `orphan-resource-auto-deletion` war die GANZE Zeit
aktiv (Wert `replica-data`, APPLIED seit Cluster-Aufbau ~136d). Es war NICHT deaktiviert.
Die Auto-Deletion griff auf Node 22 dennoch nicht, weil Longhorns Cleanup auf einem
bereits gestressten Node bzw. bei beeintraechtigtem/evictetem longhorn-manager NICHT
ausgefuehrt wird (Longhorn-Doku: "Orphaned resources on failed or unknown nodes are
not automatically cleaned up"). So entstand ein Teufelskreis: Node-Stress -> Orphans
entstehen -> Auto-Deletion greift auf dem gestressten Node nicht -> Orphans wachsen.

### Stufe 1 — DiskPressure und Massen-Eviction (05:24)

Die verwaisten Verzeichnisse (~186 GB Anteil) fuellten die Root-Disk von k8s-dev-22
auf 92% (330G/375G). Um 05:24:30 setzte das Kubelet `DiskPressure=True` und den Taint
`node.kubernetes.io/disk-pressure:NoSchedule`. Folge: ALLE Pods auf Node 22 wurden
evictet — inklusive der Longhorn-Komponenten (longhorn-manager, csi-plugin,
engine-image; instance-manager gestoppt/Completed).

### Stufe 2 — Attach-Deadlock

Prometheus (lag auf Node 22) und thanos-compactor wurden verdraengt und versuchten,
ihre Longhorn-Volumes auf anderen Nodes (21 bzw. 23) neu zu attachen. Der Attach
haengte dauerhaft (`AttachVolume.Attach failed ... DeadlineExceeded`, x174 ueber 5h42m).
Kernproblem: Der evictete longhorn-manager auf Node 22 konnte weder die Orphans
aufraeumen (der einzige Weg, Platz zu schaffen) noch beim Volume-Handling mitwirken.
Deadlock: kein Platz -> Manager tot -> kein Cleanup -> kein Platz.

### Stufe 3 — Folgefehler Monitoring

Ohne attachbares Volume blieb Prometheus 6h17m in Init:0/1. Der alloy-vcenter-Pod
(vCenter-Metriken, am selben Tag ausgerollt) lief zwar, konnte aber nicht mehr per
remote_write pushen (`connection refused` an die Prometheus-ClusterIP). DEV-Monitoring
war damit blind.

## Recovery (gestaffelt, mit Verifikation)

### Phase 1 — Deadlock durchbrechen (Platz auf Node 22 schaffen)

Da der longhorn-manager auf Node 22 evictet war, konnte Longhorn die Orphans nicht
selbst aufraeumen. Manueller Eingriff, gepaart pro Verzeichnis:
1. Orphan-CR loeschen (auf mgmt-10): `kubectl -n longhorn-system delete orphan.longhorn.io <name>`
2. Zugehoeriges Verzeichnis entfernen (auf dev-22), NACH Sicherheitscheck:
   - `sudo lsof +D <pfad>` -> kein offener Handle
   - `mount | grep <suffix>` -> kein Mount
   - `ls` zeigt Replica-Dateien (volume-head-*.img, volume.meta) -> bestaetigt Replica
   - dann `sudo rm -rf <pfad>`

WICHTIG: Beim ersten Orphan blieb das Verzeichnis trotz geloeschtem CR liegen (Manager
evictet -> kein Cleanup). Deshalb der manuelle rm-Weg. NUR verwaiste Verzeichnisse
entfernen; legitime (stopped) Replicas identifizieren und in Ruhe lassen:
- pvc-5a7a95a6-...-0b0564a6 (41G) = legitime stopped Prometheus-Replica r-b4115ac1
- pvc-fc854505-...-20232571 (30G) = legitime stopped thanos-Replica r-cf949407

Ergebnis: Disk von 92% (330G) auf 61% (218G) -> DiskPressure-Schwelle unterschritten.

### Phase 2 — Node 22 rehabilitieren

- Kubelet setzte `DiskPressure=False` (KubeletHasNoDiskPressure), Taint verschwand automatisch.
- Tote Longhorn-Pods (Evicted/Completed) manuell abgeraeumt:
  `kubectl -n longhorn-system delete pod longhorn-manager-<x> longhorn-csi-plugin-<x> engine-image-<x> instance-manager-<x>`
- DaemonSets erstellten sofort frische Pods -> longhorn-manager 2/2, csi-plugin 3/3,
  engine-image 1/1, instance-manager 1/1 auf Node 22.

### Phase 3 — Volumes und Workloads

- Beide haengenden Volumes wechselten selbstaendig auf `attached / healthy`.
- Prometheus fing sich OHNE Pod-Delete selbst (kubelet zog den Mount nach) -> 3/3 Running.
  (Vor dem geplanten Pod-Delete pruefen! Er war bereits gesund.)
- thanos-compactor als neuer Pod Running; alte Pod-Leiche (ContainerStatusUnknown) entfernt.

### Phase 4 — Rebuild abwarten (bewusst nicht forciert)

Auf Empfehlung: gewartet, bis Longhorn alle degraded Volumes rebuildet hatte (8 -> 0
degraded), BEVOR weitere Aktionen. Longhorn rebuildet gedrosselt (1 Rebuild/Node),
kein Storm. Ein Teil der neuen Replicas landete wieder auf Node 22 (legitime Belegung).

### Phase 5 — Restliche Orphans bereinigen

Nach Rehabilitierung Node 22: verbliebene Orphan-CRs auf Node 22 geloescht (die auf
21/23 hatte die Auto-Deletion inzwischen selbst abgeraeumt). Abschliessende Verifikation:
Verzeichnisse auf Platte == legitime Replica-CRs (dataDirectoryName-Abgleich), 0 Orphans
clusterweit, 37/37 Volumes healthy, Node 22 bei 45% Disk.

## Learnings

1. **Auto-Deletion schuetzt NICHT vor Ansammlung auf gestressten Nodes.** Das Setting
   war aktiv, half aber genau dort nicht, wo es gebraucht wurde (Node unter Druck).
   Die eigentliche Absicherung ist, DiskPressure gar nicht erst entstehen zu lassen
   (Monitoring/Alert, s.u.), nicht das Setting.
2. **Manueller Orphan-CR-Delete greift nur bei gesundem Manager sofort.** Bei evictetem
   Manager bleibt das Verzeichnis liegen (CR weg, Daten da) -> dann rm-Weg noetig.
   Reihenfolge strikt: erst CR loeschen, dann Verzeichnis (nie umgekehrt, nie rm bei
   noch existierendem CR).
3. **Vor rm immer verifizieren:** lsof (kein Handle) + mount (kein Mount) + legitime
   Replicas ausschliessen (dataDirectoryName-Abgleich gegen replicas.longhorn.io).
4. **Kubernetes-MCP-Delete kann bei Storage-Last timeouten** (4-Min-Hang beobachtet).
   Bei Incidents schreibende Longhorn-Operationen direkt auf mgmt-10 ausfuehren.
5. **Pod-Status vor Eingriff pruefen.** Prometheus hatte sich selbst gefangen; ein
   vorschneller Pod-Delete waere unnoetig gewesen.
6. **jsonpath-Filter ueber die Kubernetes-MCP teils unzuverlaessig** (voll ausgegeben
   statt gefiltert) — Ergebnisse gegenpruefen.

## Praevention (offen / empfohlen)

- **Alert Node-Disk** (dringend): Warn bei >80%, Critical bei >88% Root-FS je Node —
  haette den Incident Tage vorher sichtbar gemacht. Passt zu den DEV-Monitoring-Alerts.
- **Alert Orphan-Anzahl**: `longhorn_orphan` bzw. Count der orphans.longhorn.io > N ueber
  Zeit -> fruehe Warnung vor Ansammlung.
- **Root-Cause Stufe 0 offen:** WARUM entstanden die Orphans ab 02.07. in dem Ausmass?
  Kandidaten: Nachwehen der Node-Migration, Rebuild-Kaskade, wiederkehrendes Node-22-Muster.
  Bei Wiederauftreten gezielt Longhorn-Manager-Logs von Node 22 um den 02.07. sichern.
- `orphanResourceAutoDeletion` ist nun explizit in `environments/dev/longhorn/values-override.yaml`
  dokumentiert (war bereits Cluster-Default; keine Verhaltensaenderung).

## Verweise

- Runbook: docs/runbooks/longhorn-volume-expansion-deadlock.md
- Verwandter Incident: docs/incidents/2026-06-29-cnpg-wal-deadlock-longhorn-kaskade.md
