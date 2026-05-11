# Incident: MariaDB Galera Recovery DEV (2026-05-11)

**Status:** in Bearbeitung
**Umgebung:** k8s-dev
**Betroffene Workloads:** mariadb-galera, i-doit (CMDB)
**Andere Apps:** alle anderen DB-Workloads (CNPG-erp, CNPG-shared) konnten sich selbst recovern

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
