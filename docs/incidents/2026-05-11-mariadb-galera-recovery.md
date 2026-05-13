# Incident: K8s-DEV Cluster Recovery (2026-05-10 bis 2026-05-12)

**Status:** abgeschlossen am 2026-05-12 ca. 18:00 MESZ
**Umgebung:** k8s-dev (k8s-dev-21/22/23)
**Zeitraum:** 2026-05-10 (Incident-Beginn) bis 2026-05-12 (vollstaendige Heilung)
**Betroffene Workloads:**
- mariadb-galera + i-doit (CMDB) — Recovery via PhysicalBackup-Restore an Tag 2
- cnpg-shared (komplett DOWN ueber 22h) — Recovery an Tag 3 via Pod-Restart
- cnpg-erp (degraded, 1 Pod Crash-Loop) — Recovery an Tag 3 via CNPG-Instance-Rebuild
- 3 nicht-DB-Volumes (registry-zot-2, thanos-compactor, thanos-storegateway-0) — Recovery an Tag 3 via Replica-Delete-Trick
**Recovery-Phasen:** 3 Arbeitstage

> **Hinweis:** Die urspruengliche Annahme zu Beginn ("CNPG konnten sich selbst recovern") war ein vorlaeufiger Beobachtungsstand am 11.05.
> Tag-3-Analyse zeigte dass cnpg-shared komplett DOWN war und cnpg-erp degraded mit einem Replica im 30-Min-Crash-Loop.

## Ausgangslage

Am 2026-05-10 ca. 14:59 CEST fuehrten EXT4-Filesystem-Fehler auf einer Longhorn-Daten-Disk
des ESXi-Hosts von k8s-dev-21 zu einem transienten I/O-Storm. Folgen:

- Longhorn: 28 Volumes degraded, 8 detached/orphan
- CNPG cnpg-erp + cnpg-shared: Failover-Versuche mit Pods stuck in PodInitializing
- MariaDB Galera: Split-Brain mit 3 verschiedenen UUIDs auf den 3 Pods, seqno=-1 ueberall
- etcd auf k8s-dev-21: Slow-Apply, Request-Timeouts, mehrfache API-Server 503

## Bereits durchgefuehrte Mitigation

1. Longhorn-Settings angepasst (replenishment-wait, concurrent-rebuild-limit)
2. k8s-dev-21 in Longhorn auf `allowScheduling=false`
3. 49 stuck retry=5 Replicas geloescht
4. CNPG-Pods cnpg-erp-4 und cnpg-shared-3 gezielt neu gestartet
5. CNPG hat sich nach Pod-Restart komplett von selbst recovered

## Aktueller offener Punkt

MariaDB Galera ist noch im Split-Brain mit CrashLoopBackOff aller 3 Pods.

WSREP-Recovery Logs:
- mariadb-galera-0: keine recoverbare Seqno (neue UUID nach Operator-Bootstrap-Versuchen)
- mariadb-galera-1: Seqno 1-2 (fast leer)
- mariadb-galera-2: Seqno 172-182 (meiste Daten)

Operator versucht endlos galera-0 als Bootstrap-Pod zu nutzen (weil safeToBootstrap=true)
und scheitert mit context deadline exceeded.

## Recovery-Strategie: Restore aus PhysicalBackup

**Backup-Quelle:**

- S3-Bucket: `k8s-dev-mariadb-backup` auf NAS10
- Prefix: `mariadb-galera/`
- File: `physicalbackup-20260509043000.xb.gz` (2.2 MB komprimiert, ~500 MB unkomprimiert)
- Zeitpunkt: 2026-05-09 04:30 UTC = 06:30 Europe/Berlin
- targetRecoveryTime: `2026-05-09T05:00:00Z`

**Datenverlust:** ca. 35 Stunden Schreibvorgaenge in i-doit zwischen 09.05. 04:30 UTC und 10.05. 14:59 CEST.
i-doit Upload-Verzeichnis wurde separat per rclone-CronJob gesichert (siehe k8s-dev-idoit Bucket),
ist damit weitgehend aktuell. Verlust betrifft DB-Eintraege.

## Recovery-Schritte

### Phase 1: GitOps-Vorbereitung (DIESER COMMIT)

Diese Aenderung fuegt `spec.bootstrapFrom` zur MariaDB CR hinzu.
Damit weiss der mariadb-operator dass beim naechsten Provisioning aus dem
PhysicalBackup wiederhergestellt werden soll.

### Phase 2: Manuelle Recovery-Aktionen (NACH Commit-Push)

```bash
# Auf einer der Workstations mit kubectl-Zugang
export SERVER=https://192.168.180.23:6443

# 1. iDoit pausieren - keine weiteren Schreibversuche
kubectl --context=k8s-dev --server=$SERVER scale deployment idoit -n idoit --replicas=0

# 2. ArgoCD-App auto-sync ausschalten (damit selfHeal beim Loeschen nicht stoert)
kubectl --context=k8s-dev --server=$SERVER patch application mariadb-cluster -n argocd \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 3. MariaDB-CR loeschen - StatefulSet+Pods gehen weg, PVCs BLEIBEN per Operator-Verhalten
kubectl --context=k8s-dev --server=$SERVER delete mariadb mariadb-galera -n databases

# 4. PVCs loeschen damit Restore in frische Volumes erfolgt
kubectl --context=k8s-dev --server=$SERVER delete pvc -n databases \
  galera-mariadb-galera-0 galera-mariadb-galera-1 galera-mariadb-galera-2 \
  storage-mariadb-galera-0 storage-mariadb-galera-1 storage-mariadb-galera-2

# 5. ArgoCD-App syncen - die neue MariaDB-CR (mit bootstrapFrom) wird angelegt
kubectl --context=k8s-dev --server=$SERVER patch application mariadb-cluster -n argocd \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# Alternativ: argocd app sync mariadb-cluster

# 6. Restore-Job + Pod-Recovery beobachten
kubectl --context=k8s-dev --server=$SERVER get pods -n databases -w
kubectl --context=k8s-dev --server=$SERVER get jobs -n databases -w

# 7. Sobald 3/3 Pods Ready: iDoit hochfahren
kubectl --context=k8s-dev --server=$SERVER scale deployment idoit -n idoit --replicas=1
```

### Phase 3: GitOps-Cleanup (NACH Verifikation)

Wenn iDoit wieder funktioniert + Daten verifiziert: `bootstrapFrom`-Sektion aus
`mariadb-galera.yaml` wieder entfernen + zweiten Commit pushen.
Sonst initiiert der Operator den Restore bei jedem Reconcile erneut.

## Verifikations-Checkliste

- [ ] 3/3 mariadb-galera Pods Ready 2/2
- [ ] Galera-Cluster-Size = 3 (`SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='wsrep_cluster_size'`)
- [ ] iDoit kann sich verbinden (Login-Test)
- [ ] iDoit zeigt sinnvolle Datenstaende (Vergleich mit erinnertem Stand 09.05.)
- [ ] PhysicalBackup laeuft heute Nacht erfolgreich (frischer Stand)

## Lessons Learned (Entwurf)

- Galera ist sehr empfindlich gegen I/O-Stress mit gleichzeitigem Crash aller Pods.
  Operator-Bootstrap-Wahl basiert nur auf safeToBootstrap=true, nicht auf gemessener Seqno.
- Bei distroless Container-Images ist Eingriff in PVCs nur via Helper-Pod moeglich.
- PhysicalBackup mit gzip-Compression + S3 ist sehr effizient (500 MB -> 2 MB).


---

## Recovery-Verlauf (Final)

### 2026-05-11 (Tag 2) — MariaDB Galera Recovery erfolgreich

**Durchgefuehrte Aktionen:**

1. **Galera-Cluster zerstoert und aus PhysicalBackup neu aufgebaut**
   - MariaDB-CR mit `spec.bootstrapFrom` versehen (S3-Backup `physicalbackup-20260509043000.xb.gz`)
   - StatefulSet-PVCs geloescht (alte Daten weg, Recovery in frische Volumes)
   - ArgoCD-App syncen → Operator restoriert von S3-Backup
   - Galera 3/3 Pods Ready ~30 Min nach Sync
2. **i-doit Reconnect** → Login funktioniert, alle wesentlichen CMDB-Daten vorhanden (Verlust nur ~35h Eingaben)
3. **6 orphan Longhorn-Volumes** aus dem Phase-1-Cleanup geloescht (alte mariadb-galera PVCs nach Recovery, Reste vom 10.05.)
4. **Rancher/Cattle-Komponenten entfernt** — nicht mehr genutzt seit Headlamp-Umstellung, Storage-Verbrauch reduziert
5. **bootstrapFrom-Sektion in mariadb-galera.yaml** zurueckgesetzt (zweiter Commit, sonst rebootstrap bei jedem Reconcile)

**Ergebnis Tag 2:** Galera + i-doit voll funktionsfaehig. Vermutung: andere DB-Cluster (cnpg-erp/cnpg-shared) hatten sich selbst stabilisiert.


### 2026-05-12 (Tag 3) — Cluster-Komplett-Heilung

**Ausgangs-Diagnose (12.05. Vormittag):**

- Node k8s-dev-21 noch instabil: 9+ NodeNotReady-Zyklen in 2h zwischen 12:10-13:09 UTC
- dmesg auf Node 21: **`sd 12:0:0:1: [sdk] Unrecovered read error`** + EXT4-Korruption + SCSI device resets
- Wurzelursache: Unrecoverable Medium Error auf Longhorn-Block-Device sdk → I/O-Errors → SCSI-Reset-Kaskaden → etcd-Slow → systemd-Watchdog killt K3s
- letzter K3s-Recovery-Restart: 13:12:18 UTC (15:12:18 MESZ)
- 9 Longhorn-Volumes degraded cluster-weit, davon viele mit Zombie-Replicas

#### Phase A: Zombie-Replica-Cleanup auf Node 21

**23 Zombie-Replicas** identifiziert auf Node 21 (state=stopped, desire=running):

| Volume | Pod | Anzahl Zombies |
|---|---|---|
| pvc-4dee8640 | storage-loki-0 | 7 |
| pvc-647331f3 | garage-meta-2 | 2 |
| pvc-7027db0a | odoo-filestore | 2 |
| pvc-71025523 | openproject-tmp | 2 |
| 12 weitere | idoit/garage/trivy/prom/n8n/cnpg-shared-WAL/grafana/etc. | je 1 |

**Vorgehen:**

1. Node 21 in Longhorn `allowScheduling=false` → keine neuen Replicas
2. Batch 1 (15:27 MESZ): 7 Loki-Zombies geloescht — Storage Node 21: 401.9 → 326.7 GB (-75 GB)
3. Validierung: kubectl Events k8s-dev-21 — seit 13:12:39 UTC keine neuen NodeNotReady-Events. SSH-dmesg: letzter SCSI-Reset 15:15:38 MESZ. **31 Min Ruhe**.
4. Batch 2 (~15:50 MESZ): alle 16 restlichen Zombies geloescht in einem Befehl — Storage Node 21: 326.7 → **193.6 GB** (-208 GB / -52% gesamt)
5. Node 21 `allowScheduling=true` zurueck → Rebuilds fuer degraded Volumes starten automatisch

**Ergebnis Phase A:** Node 21 stabil, Zombies weg, +62 GB sofort scheduled fuer Rebuilds.


#### Phase B: CNPG-Cluster Recovery

**Schwerer Befund nach Phase A:** beide CNPG-Cluster nicht gesund

- **cnpg-shared:** komplett DOWN seit 22-23h. Alle 3 Pods nicht ready. Primary cnpg-shared-4 (N21) hing 134 Min in PodInitializing, cnpg-shared-2 (N22) + cnpg-shared-3 (N23) postgres-Container "Completed" exitCode=0
- **cnpg-erp:** degraded. cnpg-erp-3 (N22) = 2/2 Primary. cnpg-erp-4 (N23) = 1/2 Unknown (exit 255, reason Unknown). cnpg-erp-5 (N23) = 1/2 Running mit **10 Restarts in 5h** (30-Min-Loop, exit 0 weil postgres jeweils gekillt bevor CNPG-Manager Shutdown erkannte)

**Wurzelursachen-Analyse via SSH-Diagnose Node 21:**

UUID `b79ad070-b55f-43ab-971c-d20c428e201f` (aus dmesg-EXT4-Fehler) entspricht:
- `/dev/longhorn/pvc-b3bf1bae-78d9-453b-8235-777636af1022` = **cnpg-shared-4 WAL-Volume**
- EXT4 state: **clean** (keine Filesystem-Korruption!)
- pg_wal-Verzeichnis lesbar, owner postgres OK
- `crictl ps -a --name postgres` → **LEER, KEIN postgres-Container auf Node 21**
- `journalctl -u k3s` letzte 15 Min fuer Pod cnpg-shared-4 → **LEER, kubelet macht nichts mit dem Pod**

→ **kubelet-State-Haenger**, kein Filesystem-Problem! Pod-Lifecycle ist verloren waehrend Containerd/K3s-Restarts der vergangenen Stunden.

**Recovery-Sequenz cnpg-shared:**

1. Pod cnpg-shared-4 (Primary, Node 21) geloescht → Pod neu auf gleichem Node, SuccessfulAttachVolume, **2/2 Running in 50s** ✅
2. Pod cnpg-shared-2 (Node 22) geloescht → WAL-Replay aus Barman-S3 (Logs: "restored log file ... from archive"), 2/2 Running nach **6m17s**
3. Pod cnpg-shared-3 (Node 23) geloescht → 2/2 Running nach **~7m**
4. **cnpg-shared 3/3 healthy** ✅

> **Erklaerung Streaming-Replication vs Archive-Recovery:** Primary recyclet WAL nach Archivierung (max_wal_size).
> Bei 23h Downtime sind WAL-Files beim Primary recycled, deshalb faellt Standby auf Barman-Archive-Recovery zurueck.
> Switch auf Streaming sobald Luecke klein genug.

**Recovery-Sequenz cnpg-erp:**

1. Pod cnpg-erp-4 (Node 23, Unknown) geloescht → 2/2 Running in **3m12s** (gleicher kubelet-Haenger-Pattern)
2. cnpg-erp-5 hatte 30-Min-Crashloop (postgres wurde wiederholt gekillt) — Diagnose ergab kuerzlich:
   - 2 Longhorn-Volumes auf Node 23 mit `dataLocality: strict-local` + `numberOfReplicas: 1`
   - Pod konnte deswegen nur auf Node 23 laufen
3. **Saubere Migration** statt Volume-Spec-Hack gewaehlt:
   - Pod cnpg-erp-5 geloescht
   - PVCs cnpg-erp-5 (pgdata) + cnpg-erp-5-wal geloescht (`reclaimPolicy: Retain` → Volumes bleiben als Sicherheitsnetz)
   - CNPG-Operator detected: "Instance fehlt" → **instance-serial-bump 5 → 6**
   - **cnpg-erp-6** auf Node 21 platziert (Anti-Affinity preference: cnpg-erp-3 auf N22, cnpg-erp-4 auf N23 → N21 freier Slot)
   - Neue PVCs via `volumeBindingMode: WaitForFirstConsumer` → Longhorn-Volumes lokal auf N21 provisioniert
   - pg_basebackup vom Primary cnpg-erp-3 ~5-10 Min → 2/2 Running auf Node 21 ✅
4. **cnpg-erp 3/3 healthy** mit **Optimal-Verteilung 1 Instanz pro Node** ✅

**Ergebnis Phase B:** beide CNPG-Cluster healthy, Verteilung wiederhergestellt.


#### Phase C: Orphan- und Degraded-Volume-Cleanup

**Orphan-Volume-Cleanup (von cnpg-erp-5 Migration):**

Nach CNPG-Instance-Bump waren 2 Longhorn-Volumes orphan auf Node 23:
- pvc-53778479 (alte cnpg-erp-5 pgdata, 21.5 GB)
- pvc-3c293cee (alte cnpg-erp-5-wal, 5.4 GB)

Cleanup-Reihenfolge:
1. `volumes.longhorn.io` direkt geloescht (`kubectl delete volume.longhorn.io ...`)
2. PVs durch CSI-Cascading-Delete automatisch entfernt
3. Storage Node 23 freigegeben: 26.9 GB

**Degraded-Volume-Cleanup (3 nicht-DB-Volumes):**

| Volume | Pod | Size | Problem |
|---|---|---|---|
| pvc-8ef2094e | registry-zot-2 | 10 GiB | 3 Replicas (2× N22 + 1× N23) — Anti-Affinity-Violation, 0 auf N21 |
| pvc-fc854505 | thanos-compactor | 30 GiB | 2 Replicas (N21 retry=5, N23 retry=0) — 3. fehlt, sollte auf N22 |
| pvc-ffddbaf4 | thanos-storegateway-0 | 10 GiB | 2 Replicas (N21 retry=2, N23 retry=0) — 3. fehlt, sollte auf N22 |

Auto-Replenishment hat nicht gegriffen trotz `replica-auto-balance: best-effort`.
Grund: Diese "kaputten" Replicas hatten `state: running` aber `healthyAt: <leer>` —
**Zombie-Pattern** das Longhorn nicht als "failed" erkennt.

**Replica-Delete-Trick:**

1. **pvc-fc854505:** `numberOfReplicas 3 → 2` → den retry=5-Replica (Node 21) direkt deleten → Longhorn baut sofort neuen Replica auf Node 21 (nach Hard-Anti-Affinity einziger freier Node), 30 GiB Rebuild ~10 Min. Anschliessend `numberOfReplicas 2 → 3` → dritter Replica auf Node 22 gebaut.
2. **pvc-ffddbaf4:** identischer Trick, 10 GiB Rebuild ~3 Min, dann 3. auf Node 22 ~3 Min.
3. **pvc-8ef2094e:** der "duplicate" Replica auf Node 22 (`healthyAt: <leer>`) direkt geloescht ohne numberOfReplicas-Aenderung → Longhorn baut neuen auf Node 21 (Hard-Anti-Affinity, einziger freier Slot).

**Endzustand:** **37/37 Longhorn-Volumes attached + healthy** ✅

#### Storage-Endverteilung Tag 3

| Node | Storage Scheduled | Storage Available | % Belegt |
|---|---|---|---|
| k8s-dev-21 | 293 GB | 240 GB | 60% |
| k8s-dev-22 | 298 GB | 174 GB | 65% |
| k8s-dev-23 | 298 GB | 229 GB | 60% |

Verteilung sehr ausgewogen.

#### Apps-Validierung Tag 3 (18:00 MESZ)

Alle Apps voll funktionsfaehig:
- Keycloak Login ✅
- n8n ✅
- OpenProject ✅
- Odoo ✅
- i-doit ✅
- Headlamp ✅


---

## Lessons Learned (Final, 2026-05-12)

### Infrastruktur / Kubernetes

1. **EXT4 Medium-Errors auf Longhorn-Block-Devices** (sd*) loesen Kaskade aus: I/O-Errors → SCSI-Resets → etcd-Slow → systemd-Watchdog killt K3s.
   → **dmesg + systemd-Journal sind primaere Diagnose-Quelle**, nicht kubectl events.
2. **kubelet kann nach K3s/Containerd-Restarts Pod-Lifecycle "verlieren"** ohne sichtbare Fehler:
   - `kubectl get pod`: Pod erscheint Running (Init phase)
   - `crictl ps -a --name <container>`: leer (kein Container)
   - `journalctl -u k3s`: leer fuer den Pod
   - **Loesung:** Pod loeschen, kubelet erstellt sauber neu.
3. **Galera ist sehr empfindlich gegen I/O-Stress mit gleichzeitigem Crash aller Pods.** Operator-Bootstrap-Wahl basiert nur auf `safeToBootstrap=true`, nicht auf gemessener Seqno → kann zu falschem Pod als Bootstrap-Master fuehren.
4. **Bei distroless Container-Images ist Eingriff in PVCs nur via Helper-Pod moeglich** (kein Shell im Container).

### Longhorn-spezifisch

5. **"Zombie"-Replicas** = Pattern: `state: running` + `healthyAt: <leer>` + ggfs. erhoehter `rebuildRetryCount`.
   → Longhorn behandelt sie als "in Rebuild" (nicht als "failed") → Auto-Replenishment greift NICHT.
   → **Manueller Workaround:** `kubectl delete replica.longhorn.io <name>` → Longhorn baut sofort sauberen neuen Replica.
6. **numberOfReplicas-Trick** zum Erzwingen einer Replenishment:
   - `spec.numberOfReplicas` runter (z.B. 3 → 2) loescht **nicht automatisch** den kaputten Replica
   - Aber: einen Replica direkt zu loeschen waehrend `numberOfReplicas` ≥ vorhandener Anzahl ist, triggert sofort einen neuen
   - Nach Heilung: `numberOfReplicas` zurueck auf Soll-Wert → Longhorn baut den fehlenden weiteren auf
7. **`reclaimPolicy: Retain`** auf Longhorn-Volumes ist Goldwert beim Recovery — orphan PVCs bleiben als Sicherheitsnetz erreichbar bis bewusst geloescht.
8. **Hard Anti-Affinity (`replica-soft-anti-affinity: false`)** zwingt jeden Replica auf einen anderen Node. Bei nur 3 Nodes ist das hart — wenn ein Node aus ist, kann ein neuer 3. Replica nicht gebaut werden.
9. **Cascading Delete in Longhorn**: `kubectl delete volumes.longhorn.io <name>` raeumt PV automatisch ab (CSI-driver entfernt finalizers).

### CNPG-spezifisch

10. **CNPG-Instance-Serial-Bump** (z.B. cnpg-erp-5 → cnpg-erp-6): Operator macht bei wiederkehrenden Replica-Fehlern automatisch eine neue Instance statt zu heilen. Alte PVCs werden orphan (mit `Retain`).
11. **Streaming-Replication vs Archive-Recovery** im CNPG-Recovery:
    - Bei Standby-Downtime < `max_wal_size`: Primary kann WAL fuer Streaming wiederherstellen
    - Bei laengerer Downtime: WAL ist recycled, Standby faellt auf **Barman-Archive-Recovery** zurueck (S3-WAL-Restore)
    - Switch zurueck auf Streaming wenn Luecke klein genug
12. **`dataLocality: strict-local`** in der StorageClass `longhorn-db` koppelt Pod und Replica hart an gleichen Node:
    - Volume kann **NICHT** remote attached werden
    - Pod-Migration zwischen Nodes erfordert Volume-Migration (komplex)
    - **Sauberste Methode:** Pod + PVCs loeschen, Operator macht `pg_basebackup` vom Primary auf neuem Node
13. **`volumeBindingMode: WaitForFirstConsumer`** + `strict-local` ist starke Kombination: Volume wird genau dort provisioniert wo der Pod scheduled wird → Operator-driven Migration funktioniert natuerlich.

### GitOps / Operatives

14. **PhysicalBackup mit gzip-Compression + S3 ist sehr effizient** (500 MB unkomprimiert → 2 MB komprimiert).
15. **CNPG Backup-Plugin Barman Cloud** funktioniert auch nach langen Outages — Archive-WAL-Restore ist robust.
16. **Recovery dauert pro Etappe**: Pod-Restart-Recovery 1-10 Min, pg_basebackup 5-10 Min (20 GB), Longhorn-Rebuild 1-15 Min je nach Volume-Groesse + Netzwerk.

## Verifikations-Status (Final)

- [x] Galera 3/3 Pods Ready 2/2, wsrep_cluster_size = 3
- [x] iDoit Login + CMDB-Daten verifiziert (Verlust ~35h)
- [x] PhysicalBackup laeuft schedulemaessig erfolgreich
- [x] cnpg-shared 3/3 healthy (Primary cnpg-shared-4 auf Node 21)
- [x] cnpg-erp 3/3 healthy mit Verteilung 1-pro-Node
- [x] mariadb-galera 3/3 healthy mit Verteilung 1-pro-Node
- [x] Alle 37 Longhorn-Volumes attached + healthy
- [x] Storage ausgewogen ueber 3 Nodes (60-65% pro Node)
- [x] Apps validiert: Keycloak, n8n, OpenProject, Odoo, i-doit, Headlamp

## Offene Punkte (nicht kritisch)

- Hohe kumulative Restart-Counts (longhorn-manager-kmf9c=41 auf N22, kyverno 47/49, csi 21-29) — ueber Wochen kumuliert, keine Sofortmassnahme noetig.
- **Empfehlung Phase 11 (Rolling OS-Update DEV):** vorher Backup-Validierung + Plan ausarbeiten dass Tag-3-Probleme nicht erneut auftreten (Pod-Recovery-Test nach jedem Node-Reboot).
