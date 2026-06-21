# Runbook: Prometheus TSDB-WAL-Deadlock (Volume voll)

**Kategorie:** Monitoring / Prometheus / Storage
**Erstellt:** 21.06.2026 (Aufgetreten in DEV, Prometheus-PVC 20Gi voll)
**Stichworte:** no space left on device, WAL corruption, compaction failed, KubeAPIDown, TSDB

---

## Symptom

- Alerts wie `KubeAPIDown` (critical) feuern, obwohl die API-Server gesund sind.
- Viele andere Alerts "verschwinden" gleichzeitig (Prometheus erfasst keine Daten mehr).
- Prometheus-Queries liefern leere Ergebnisse, sogar `prometheus_build_info`
  oder `count(up)` sind leer.
- Pod ist `Running`/`Ready`, aber funktional tot.

Prometheus-Logs zeigen:
```
err="write to WAL: log samples: write /prometheus/wal/00003372: no space left on device"
err="compaction failed ... mkdir /prometheus/...tmp-for-creation: no space left on device"
```

Thanos-Sidecar-Logs zeigen:
```
msg="updating meta file failed" err="write /prometheus/thanos.shipper.json.tmp: no space left on device"
```

## Diagnose

### 1. Volume-Fuellstand pruefen
```bash
kubectl --context k8s-<env> -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- df -h /prometheus
```
**Deadlock-Indikator:** `Use% = 100%`, `Available = 0`.

### 2. WAL-Groesse pruefen (Kern des Deadlocks)
```bash
kubectl --context k8s-<env> -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- sh -c "du -sh /prometheus/wal; du -sh /prometheus/chunks_head; ls -d /prometheus/01* 2>/dev/null | wc -l"
```
**Deadlock-Indikator:** WAL abnorm gross (z.B. 19 GB statt < 1-2 GB), kaum/keine
persistenten Bloecke (`01...`-Verzeichnisse). Normal: WAL klein, Daten in Bloecken.

### 3. Ursache am laufenden Prometheus pruefen (nach Recovery)
```bash
# Kompaktierungs-Fehler (Vorbote)
wget -qO- 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_compactions_failed_total'
# WAL-Korruption (eigentliche Wurzel, oft Folge von Storage-I/O-Latenz)
wget -qO- 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_wal_corruptions_total'
```

### 4. Endpoint-Auslagerung (NAS20/S3) als Ursache ausschliessen
```bash
# Im thanos-sidecar-Container:
thanos tools bucket ls --objstore.config="$OBJSTORE_CONFIG"
```
Erreichbar + Bloecke gelistet => S3/NAS20 ist NICHT die Ursache. Das Problem ist
lokal (volles Volume blockiert Kompaktierung, daher entstehen keine neuen Bloecke
zum Shippen).

## Ursachenkette (DEV 21.06.2026)

1. WAL-Korruption (`wal_corruptions_total = 1`), entstanden durch fruehere
   Longhorn-I/O-Latenz-Krise (Schreib-Timeouts auf dem Prometheus-Volume).
2. Korruptes WAL blockiert die TSDB-Kompaktierung.
3. Ohne Kompaktierung wird das WAL nie zu Bloecken verarbeitet -> WAL waechst
   ungebremst.
4. WAL fuellt das gesamte PVC -> `no space left` -> Schreibstopp.
5. Folge: keine Metriken, `KubeAPIDown`, Monitoring-Blindflug.

**Wichtig:** `retentionSize` (z.B. 12GB) schuetzt NICHT, weil es nur persistierte
Bloecke begrenzt, NICHT das WAL. Ein Kompaktierungs-Ausfall haebelt die
Size-Begrenzung aus.

## Behebung

### Schritt 1: Volume vergroessern (DevOps-Weg + notwendiger PVC-Patch)

Das Prometheus-PVC wird vom prometheus-operator aus der Prometheus-CR (Helm-Values)
erzeugt. Wichtig: StatefulSet-`volumeClaimTemplates` sind **immutable** - eine reine
Git/Helm-Aenderung vergroessert das bestehende PVC NICHT automatisch. Daher Zweischritt:

**1a - Git (Soll-Zustand, dokumentiert):**
In `kubernetes/environments/dev/monitoring/values-override.yaml`:
```yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 25Gi   # vorher 20Gi
```
committen + pushen.

**1b - PVC online expandieren (loest die tatsaechliche Vergroesserung aus):**
```bash
kubectl --context k8s-<env> -n monitoring patch pvc \
  prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
  --type=merge -p '{"spec":{"resources":{"requests":{"storage":"25Gi"}}}}'
```
StorageClass `longhorn` hat `allowVolumeExpansion: true`. Longhorn expandiert den
Block-Layer online. Das PVC wechselt danach auf `FileSystemResizePending`.

### Schritt 2: Memory-Limit fuer WAL-Replay erhoehen (VOR Pod-Neustart!)

Der Pod-Neustart loest Filesystem-Resize + WAL-Replay aus. Ein grosses WAL
(z.B. 19 GB) braucht beim Replay deutlich mehr RAM. Pruefen, ob das Limit reicht:
```bash
kubectl --context k8s-<env> -n monitoring top pod prometheus-kube-prometheus-stack-prometheus-0 --containers
```
Bei Normalverbrauch ~1,5 GB und Limit 2 Gi => **OOMKill-Risiko beim Replay**.
Limit temporaer erhoehen (via Git, sonst ueberschreibt ArgoCD):
```yaml
prometheus:
  prometheusSpec:
    resources:
      requests: { cpu: 100m, memory: 1Gi }
      limits:   { memory: 4Gi }
```
committen + pushen + Hard-Refresh.

### Schritt 3: Pod-Neustart (Filesystem-Resize + WAL-Replay + Kompaktierung)

Der Operator erstellt den Pod bei der Spec-Aenderung (Memory-Limit) automatisch neu.
Andernfalls manuell:
```bash
kubectl --context k8s-<env> -n monitoring delete pod prometheus-kube-prometheus-stack-prometheus-0
```
Beim (Re-)Mount greift `resize2fs` (FileSystemResizePending loest sich auf), dann
WAL-Replay (dauert je nach WAL-Groesse Minuten), dann erste Kompaktierung -> WAL
schrumpft -> Platz frei -> Thanos-Sidecar shippt wieder nach NAS20.

### Schritt 4: ArgoCD Hard-Refresh (mandatory bei Helm-Sub-Map-Aenderungen)
```bash
kubectl --context k8s-<env> -n argocd annotate applications.argoproj.io monitoring \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Verifikation

```bash
# Filesystem gewachsen, viel frei
kubectl --context k8s-<env> -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- df -h /prometheus
# Expected: neue Groesse (z.B. 24.4G), Use% niedrig

# WAL geschrumpft, Bloecke entstehen
kubectl --context k8s-<env> -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- du -sh /prometheus/wal
# Expected: < 100 MB

# Prometheus erfasst wieder Daten
wget -qO- 'http://localhost:9090/api/v1/query?query=count(up)'      # > 0
wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="apiserver"}'  # 3x value 1

# Kompaktierung ohne Fehler
wget -qO- 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_compactions_failed_total'  # 0

# Pod stabil, kein OOM
kubectl --context k8s-<env> -n monitoring get pod prometheus-kube-prometheus-stack-prometheus-0
# Expected: READY, RESTARTS=0
```

### Schritt 5: Memory-Limit zurueckbauen
Nach erfolgreicher Kompaktierung (WAL klein) das temporaere Limit auf einen sinnvollen
Dauerwert senken. Bei eNeG DEV: 3Gi (Normalverbrauch ~1,5GB, altes 2Gi war knapp).
Via Git + Hard-Refresh. Loest einen weiteren Pod-Neustart aus - unkritisch, da WAL
jetzt klein.

## Praevention

Seit 21.06.2026 in DEV aktiv (`monitoring-alerts/prometheus-tsdb-health-dev.yaml`):
- **PrometheusTSDBCompactionsFailing** - feuert bei fehlgeschlagener Kompaktierung
  (direkter Vorbote, bevor das WAL volllaeuft).
- **PrometheusTSDBWALCorruptions** - feuert bei WAL-Korruption (die eigentliche
  Wurzel, meist Folge von Storage-I/O-Latenz).
- **PrometheusStorageFillingUp** - feuert bei PVC-Fuellstand > 80% (letzte Sicherung
  vor dem Schreibstopp).

Weitere Massnahmen:
- PVC mit ausreichend Headroom (DEV: 25Gi bei retentionSize 12GB).
- Bei Storage-I/O-Vorfaellen (Longhorn-Latenz) danach immer
  `prometheus_tsdb_wal_corruptions_total` pruefen - eine Korruption kann
  zeitversetzt (Tage spaeter) zum Deadlock fuehren.

## Tiefere Wurzel

Der Ausloeser war eine WAL-Korruption durch Longhorn-Disk-I/O-Latenz (geteilte SSD
mit MikroK8s-Cluster, `dm-0` unter Last bei 100% util). Das Storage-I/O-
Kapazitaetsthema ist die strategische Daueraufgabe (Entkopplung/Aufruestung der
DEV-Storage). Siehe Incident-Doku der Longhorn-Rebuild-Loop-Sessions.

## Verwandte Themen

- Longhorn-Volume-Expansion: `runbooks/longhorn-volume-expansion-deadlock.md`
- Prometheus-Operator Storage-Resize: StatefulSet volumeClaimTemplates immutable
- Thanos objstore (NAS20): Secret `thanos-objstore-config`, CA `eneg-s3-ca`
- kube-prometheus-stack DEV-Override: `environments/dev/monitoring/values-override.yaml`
