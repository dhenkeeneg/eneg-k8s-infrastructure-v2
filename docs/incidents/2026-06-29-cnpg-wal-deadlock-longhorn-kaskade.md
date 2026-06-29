# Incident: WAL-Deadlock + Longhorn-Attach-Kaskade (2026-06-29)

**Status:** abgeschlossen am 2026-06-29 ca. 13:00 MESZ
**Umgebung:** k8s-dev (k8s-dev-21/22/23, K3s v1.35.1)
**Dauer Recovery:** ca. 4 Stunden (gestaffelt, mit Verifikation zwischen den Phasen)
**Schweregrad:** hoch — beide PostgreSQL-Cluster ohne aktiven Primary, aber kein Datenverlust

## Betroffene Workloads

- **cnpg-erp** (3-Knoten PostgreSQL, CloudNativePG v1.28.1) — kein Primary, WAL-Deadlock
- **cnpg-shared** (3-Knoten PostgreSQL) — kein Primary, WAL-Deadlock
- **mariadb-galera** — galera-1 mit faulted Volume, 0+2 Quorum hielt den Betrieb
- **loki-0** — FS-Korruption auf der PVC (2. Mal nach Mai)
- **prometheus** — Volume-Wachstum durch nicht-gepurgte Snapshots (degraded)

## Auslöser und Ursachenkette

Rund 3,5 Tage vor der Sanierung (ca. 25./26.06.) kam es zu gleichzeitigen Restarts
mehrerer Infrastruktur-Pods. Beobachtete Restart-Zaehler zum Zeitpunkt der Analyse:

- `csi-resizer` (longhorn-system): 66 Restarts
- `cnpg-cloudnative-pg` Operator: 32 Restarts
- `longhorn-manager` auf k8s-dev-21: betroffen (iSCSI-Sessions verklemmt)

Daraus entwickelte sich eine vierstufige Kaskade:

### Stufe 1 — CNPG WAL-Deadlock

Beide CNPG-Cluster verloren ihren Primary. Ohne laufenden Primary recycelt PostgreSQL
das lokale WAL nicht. Die separaten 5Gi-WAL-Volumes liefen voll (`archive_timeout`
produziert weiter Segmente). Folge: `Not enough disk space` → der CNPG-Instance-Manager
verweigert den PostgreSQL-Start (`ensure_sufficient_disk_space`-Guard) → kein Primary →
kein WAL-Recycling. Klassischer Henne-Ei-Deadlock.

WAL-Befund (Longhorn actualSize vs. spec 5Gi):
- cnpg-erp-3-wal: 8,0 GB / 5Gi (160%)
- cnpg-shared-2-wal: 8,5 GB / 5Gi (170%)
- PGDATA-Volumes (20Gi) dagegen nahezu leer (<1 GB) — eindeutig WAL, nicht Nutzdaten

Wichtig: Die S3-WAL-Archivierung (NAS20, `s3://k8s-dev-postgres-wal/`) funktionierte
durchgehend (`ContinuousArchivingSuccess: True`). Der Umzug NAS10→NAS20 war nicht die
Ursache — beide ObjectStores zeigen korrekt auf nas20.eneg.de:8010.

### Stufe 2 — Longhorn-Expansion-Hänger

Der WAL-Resize 5→8Gi (per GitOps) wurde von CNPG wegen des Disk-Space-Guards nicht
selbst angestossen (Pod startet nicht → kein Resize-Trigger). Manuelles PVC-Patch auf
8Gi loeste die Block-Expansion aus, aber die Longhorn-Engine-Online-Expansion blieb
haengen:
- Engine-Expansion mit aktivem Frontend schloss nicht ab (`expansionRequired=true` dauerhaft)
- Eine verwaiste, node-lose Replica blockierte das `Scheduled`-Flag
  (`LocalReplicaSchedulingFailure` bei `numberOfReplicas:1`, `dataLocality:strict-local`)
- Rebuild-Stau: Longhorn fuehrt nur 1 Rebuild gleichzeitig pro Node aus; ein haengender
  Loki-Rebuild blockierte die Queue

### Stufe 3 — iSCSI-Altlasten auf k8s-dev-21

Hartnaeckige Attach-Fehler auf k8s-dev-21:
`FailedAttachVolume ... DeadlineExceeded`, `volume ... is not ready for workloads`,
sowie im Instance-Manager-Log iSCSI-Logout-Fehler
(`failed to logout target: ... target likely not connected`, exit status 32).
Selbst frisch provisionierte Volumes konnten auf -21 zeitweise nicht attachen.

### Stufe 4 — Folgeschaeden

- **loki-0**: FS-Korruption (`UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY`),
  2527 FailedMount-Events ueber 3d13h. Bereits 2. Mal (Mai + Juni). Loki ist S3-backed.
- **prometheus**: Volume wuchs unaufhoerlich (actualSize ~34 GB bei spec 25Gi), weil
  2 als `markRemoved` markierte Snapshots im degraded-State nicht gepurged wurden.

## Sanierungsschritte (chronologisch)

### Phase 1 — cnpg-erp WAL-Resize + Recovery

1. WAL-Volume 5Gi→8Gi in `kubernetes/environments/dev/cnpg-cluster/cnpg-erp.yaml`
   (commit + push, ArgoCD Auto-Sync, hard-refresh angestossen)
2. PVCs manuell auf 8Gi gepatcht (cnpg-erp-3/4/7-wal), da CNPG-Guard den Auto-Resize blockierte
3. Engine-Expansion-Haenger geloest: cnpg-erp `cnpg.io/reconciliationLoop=disabled`
   annotiert, Pod entfernt → Volume detached vollstaendig → Engine startete mit Zielgroesse
   8Gi neu (`currentSize=8589934592`, `stopped`) → Reconcile reaktiviert
4. erp-3 (Primary) + erp-4 kamen 2/2 hoch

### Phase 2 — cnpg-shared WAL-Resize

1. WAL-Volume 5Gi→8Gi in `cnpg-shared.yaml` (commit + push + refresh)
2. PVCs cnpg-shared-2/3-wal auf 8Gi gepatcht
3. Lief deutlich glatter (kein Engine-Haenger, `expReq=false` sofort) — shared-3 (Primary)
   + shared-2 nach einfachem Pod-Neustart 2/2

### Phase 3 — k8s-dev-21 iSCSI-Reset

- Instance-Manager-Pod auf k8s-dev-21 neu gestartet (DaemonSet legt ihn neu an)
- ~18 Volumes wurden kurzzeitig degraded (Replica-Re-Sync auf -21), erholten sich vollstaendig
- iSCSI-Sessions sauber zurueckgesetzt

### Phase 4 — Dritte Instanzen + Galera neu provisioniert

Die dritten Instanzen (erp-7, shared-5) hingen weiter im Expansion-/Attach-Haenger auf -21
und wurden verworfen + frisch provisioniert (datensicher, da CNPG-Join vom Primary):
- erp-7 → **erp-8** (PVCs+PVs+Longhorn-Volumes geloescht, frische 8Gi-Volumes, pg_basebackup-Join)
- shared-5 → **shared-6** (analog)
- **galera-1**: faulted/iSCSI-belastetes Volume; PVCs verworfen → StatefulSet baute galera-1
  frisch → **SST von galera-0** (`JOINER → JOINED → SYNCED`, ready for connections)

### Phase 5 — Folgeschaeden bereinigt

- **loki-0**: PVC `storage-loki-0` (ReclaimPolicy Delete) verworfen → StatefulSet legte
  frische PVC an → Pod laeuft, keine fsck-Fehler mehr
- **prometheus**: kaputte Replica `-r-b2e978c5` (rebuildRetry=5, nicht in Engine-modeMap)
  entfernt → frischer Rebuild → healthy → Snapshots gepurged (actualSize 34→24,7 GB)
- Verwaiste Longhorn-Volumes der alten Instanzen (erp-7, shared-5, galera-1-alt) abgeraeumt

## Endzustand (verifiziert 2026-06-29 ~13:00)

- cnpg-erp: **3/3**, "Cluster in healthy state", Primary cnpg-erp-3 (+erp-4, erp-8)
- cnpg-shared: **3/3**, "Cluster in healthy state", Primary cnpg-shared-3 (+shared-2, shared-6)
- mariadb-galera: **0/1/2 alle 2/2**, galera-1 per SST resynchronisiert
- loki-0: laeuft (frische PVC)
- 0 nicht-laufende Pods clusterweit, 0 ungesunde Longhorn-Volumes

## Lessons Learned

- **LL-1: WAL-Deadlock ist selbstverstaerkend.** Kein Primary → WAL-Stau → Disk-full →
  kein Start → kein Primary. Der CNPG-`ensure_sufficient_disk_space`-Guard verschaerft das,
  weil er den Pod-Start verhindert, der den PVC-Resize ausloesen wuerde. Manuelles PVC-Patch
  ist der Ausweg.
- **LL-2: Longhorn-Online-Expansion mit aktivem Frontend kann haengen.** Sauberes Detach
  (Pod entfernen + Reconcile pausieren) zwingt die Engine, mit Zielgroesse neu zu starten.
- **LL-3: `dataLocality:strict-local` + voller Node = LocalReplicaSchedulingFailure.**
  Verwaiste Replicas blockieren dann die Expansion. Vor Expansion verwaiste Replicas pruefen.
- **LL-4: 1 Rebuild/Node-Limit staut bei vielen degraded Volumes.** Ein Instance-Manager-
  Neustart auf einem Node nimmt ~alle dortigen Replicas kurz offline — gezielt einsetzen.
- **LL-5: Verwerfen+Neu ist bei replizierten DBs der sauberste Weg** fuer haengende
  Einzel-Instanzen (CNPG-Join bzw. Galera-SST holen die Daten vom gesunden Quorum).
- **LL-6: Loki-FS-Korruption ist wiederkehrend (Mai+Juni).** Grundsaetzliche Ursache offen
  (Storage-Pfad / haeufige unsaubere Volume-Wechsel?). Kandidat fuer eigene Untersuchung.
- **LL-7: Snapshots werden bei degraded-State nicht gepurged** → Volume-Wachstum. Rebuild
  zum Abschluss bringen loest auch das Wachstum.

## Offene Punkte / Follow-ups

- **Resilienz-Analyse "Infra-Pod-Restarts → Kaskade"** in eigenem Chat (PriorityClasses,
  PDBs, Resource-Limits, Longhorn-Settings, Monitoring). Uebergabe-Doku vorhanden.
- **Loki-FS-Korruption** grundsaetzlich untersuchen (2. Vorfall).
- **WAL-Volume-Fuellstand-Alert** pruefen/ergaenzen (analog `CnpgReplicationSlotInactive`).
- **NFS-Follow-up aus Mai ist gegenstandslos**: kein `nfsvers` mehr im Repo, keine NFS-PVs/
  -StorageClasses, alle Backups gehen nach S3. Punkt gestrichen.
- **8Gi WAL bleibt dauerhaft** (Verkleinern nur per Instanz-Recreate moeglich, K8s-PVC-Shrink
  wird nicht unterstuetzt).
- CoreDNS Auto-Sync bewusst deaktiviert gelassen (Kernkomponente).
