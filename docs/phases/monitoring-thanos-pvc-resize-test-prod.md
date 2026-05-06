# Thanos Compactor PVC Resize - TEST & PROD Rollout

**Datum:** 06.05.2026
**Cluster:** k8s-test, k8s-prod
**Status:** ✅ Abgeschlossen
**Vorgaenger:** DEV-Fix vom 05.05.2026 (im Rahmen Phase 11 / "Ubuntu VMs Cluster aktualisieren")

---

## 1. Ergebnis im Ueberblick

| Cluster | PVC vorher | PVC nachher | Filesystem nach Resize | Compactor | Alerts (ohne Watchdog) |
|---------|------------|-------------|------------------------|-----------|------------------------|
| **DEV** | 10Gi | 30Gi | (siehe DEV-Eintrag) | ✅ Running | ✅ keine |
| **TEST** | 10Gi (99% voll) | 30Gi | 29.4G frei, 0% | ✅ Running auf k8s-test-23 | ✅ keine |
| **PROD** | 10Gi (95% voll) | 30Gi | 29.4G frei, 32% (9.5G belegt) | ✅ Running auf k8s-prod-23 | ✅ keine |

**Compactor compactiert wieder regulaer** in beiden Clustern (Logs zeigen erfolgreiche Compactions + Uploads nach S3 + Markierung alter Bloecke zur Loeschung).

---

## 2. Problem-Beschreibung

### Symptom

Auf TEST aktiv (06.05.2026 vor Fix):
- `KubePersistentVolumeFillingUp` (CRITICAL) — `thanos-compactor` PVC zu 99.31% voll
- `ThanosCompactionFailed` (warning) — 12 fehlgeschlagene Compactions/h, seit 04.05.2026 08:26 UTC

Auf PROD vor Fix: PVC zu 95% voll (9.2G/10G), Alert kurz vor Ausloesung.

### Root Cause

Die in der Helm-Chart-Default vorgesehenen 10Gi PVC fuer den Thanos-Compactor sind unzureichend fuer den **woechentlichen Re-Compaction-Lauf**, bei dem 24h-Bloecke zu 7d-Bloecken zusammengefasst werden.

Der Compactor benoetigt waehrend der Compaction:
- Source-Bloecke (mehrere 24h-Bloecke gleichzeitig im Working-Dir)
- Output-Block (das neue 7d-Aggregat)
- Zwischenpuffer

Beobachteter Spitzenbedarf: **ca. 14-20 GB** lokaler Working-Space.

Bei 10Gi PVC:
1. Working-Dir fuellt sich waehrend Compaction
2. Compaction faellt ab Schwelle ~99% PVC mit "no space left on device" um
3. Bei jedem erneuten Versuch das gleiche Verhalten → `ThanosCompactionFailed`-Loop
4. Daten akkumulieren weiter im Working-Dir (Cleanup nicht moeglich) → `KubePersistentVolumeFillingUp`

**DEV hat das Problem frueher gezeigt**, weil dort die meisten Test-Workloads laufen und entsprechend mehr Compaction-Last anfaellt. TEST und PROD waren bereits im selben Pattern, nur wenige Tage versetzt.

---

## 3. Loesung

### 3.1 Konzept

Compactor-PVC von **10Gi → 30Gi** erhoehen, ueber GitOps deployt durch das jeweilige `values-override.yaml` der Umgebung.

PVC-Resize geschieht in zwei Schritten:
1. **Block-Volume-Resize** (online, ohne Pod-Neustart) — Longhorn-Engine expandiert das Block-Device.
2. **Filesystem-Resize** (`resize2fs`) — geschieht erst beim **frischen Mount**, also nach Pod-Restart.

### 3.2 Ablauf pro Cluster

Identische Sequenz fuer TEST und PROD:

1. **PVC manuell patchen** (Sofort-Hilfe):
   ```bash
   kubectl --context k8s-<env> -n monitoring patch pvc thanos-compactor \
     -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'
   ```
2. **`values-override.yaml` editieren** auf der Workstation:
   ```yaml
   # kubernetes/environments/<env>/monitoring-thanos/values-override.yaml
   compactor:
     persistence:
       size: 30Gi
   ```
3. **Commit + Push** (vom Daniel):
   ```bash
   git add kubernetes/environments/<env>/monitoring-thanos/values-override.yaml
   git commit -m "fix(thanos-<env>): PVC compactor von 10Gi auf 30Gi vergroessert"
   git push
   ```
4. **ArgoCD-Hard-Refresh + Sync**:
   ```bash
   kubectl --context k8s-<env> -n argocd patch app thanos \
     --type=merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
   ```
5. **Compactor-Pod loeschen** → triggert Reattach + `resize2fs`:
   ```bash
   kubectl --context k8s-<env> -n monitoring delete pod -l app.kubernetes.io/component=compactor
   ```
6. **Bei Longhorn-Engine-Expansion-Deadlock** (siehe Lessons): aktiv detachen ueber Longhorn-CRD (Runbook `runbooks/longhorn-volume-expansion-deadlock.md`).
7. **Verifikation**:
   ```bash
   kubectl --context k8s-<env> -n monitoring exec -it thanos-compactor-... -- df -h /data
   ```

### 3.3 Zeitlicher Ablauf

| Cluster | PVC-Patch | Commit/Push | Pod-Delete | Detach-Trick noetig | Pod Running | Gesamtdauer |
|---------|-----------|-------------|------------|---------------------|-------------|-------------|
| TEST | 10:57 UTC | 11:00 UTC | 11:01 UTC | ✅ ja (11:09 UTC) | ~11:11 UTC | ~14 min |
| PROD | 16:20 UTC | 16:25 UTC | 16:28 UTC | ✅ ja (16:32 UTC) | ~16:33 UTC | ~13 min |

---

## 4. Lessons Learned

### LL-1: Longhorn-Engine-Expansion-Deadlock (TEST + PROD, in DEV nicht aufgetreten)

**Symptom:** Nach `kubectl delete pod` blieb der neue Compactor-Pod in `ContainerCreating` haengen mit:
```
Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) thanos-compactor-...-old
AttachVolume.Attach failed: the volume is currently attached to different node ...
```

**Root Cause:** Die Longhorn-Engine versucht das Volume online zu expandieren (10G → 30G), aber der Engine-Prozess kommt aus seiner `Starting engine expansion`-Schleife nicht heraus, solange das Volume an den alten Node gebunden ist (selbst wenn der alte Pod schon weg ist). Resultat:
- `volume.spec.size = 32212254720` (30 GiB)
- `engine.status.currentSize = 10737418240` (10 GiB)  
- `volume.status.expansionRequired = true`
- `volume.status.currentNodeID = <alter-Node>`

Manager-Logs zeigen alle 5s "Starting engine expansion from 10737418240 to 32212254720" ohne Fortschritt.

**Workaround:** Volume aktiv detachen ueber Longhorn-CRD:
```bash
kubectl --context k8s-<env> -n longhorn-system patch volumes.longhorn.io/<pvc-uid> \
  --type=merge -p '{"spec":{"nodeID":""}}'
```
Longhorn detached → Offline-Expansion laeuft sauber durch (innerhalb Sekunden) → Reattach auf neuem Node mit 30 GiB → Pod startet, Filesystem-Resize via `resize2fs` automatisch.

**Detail-Runbook:** [runbooks/longhorn-volume-expansion-deadlock.md](../runbooks/longhorn-volume-expansion-deadlock.md)

### LL-2: ArgoCD-Race "field can not be less than status.capacity" (PROD)

**Symptom:** Waehrend des PROD-Sync zeigte ArgoCD-Operation:
```
PersistentVolumeClaim "thanos-compactor" is invalid:
spec.resources.requests.storage: Forbidden: field can not be less than status.capacity.
Retrying attempt #4...
```

**Root Cause:** Reihenfolge-Konflikt waehrend des Resize-Vorgangs:
- PVC wurde zuerst manuell auf `Spec.Requested=30Gi` gepatcht
- Block-Volume noch nicht expandiert → `Status.Capacity` noch 10Gi
- ArgoCD-Sync versuchte gleichzeitig das Helm-Template anzuwenden, das (vor dem Git-Push der Override) noch 10Gi spezifizierte
- Apply schlug fehl: man kann `requests.storage` nicht **kleiner** als `status.capacity` machen

**Aufloesung:** Self-healing nach Volume-Expansion. Sobald `Status.Capacity=30Gi` erreicht ist, ist Spec=30Gi >= Status=30Gi und der Apply geht durch. Der Operation-Status zeigt vorruebergehend `Failed`, aber `Sync=Synced` und `Health=Healthy` werden erreicht.

**Praevention fuer naechstes Mal:** Reihenfolge umdrehen — **erst Git-Push** mit dem neuen `values-override.yaml`, **dann** PVC-Patch (oder gleich auf ArgoCD-Sync warten). Dann ist Helm-Template direkt 30Gi und kein Race moeglich.

### LL-3: Reihenfolge "Cluster zuerst patchen, dann Git-Push" funktioniert, ist aber nicht optimal

In dieser Session wurde der PVC-Patch jeweils **vor** dem Git-Push ausgefuehrt (als Sofort-Hilfe gegen den vollen PVC). Das ist akzeptabel, weil:
- ArgoCD nach Git-Push automatisch synct und Cluster-State mit Git-State konsistent macht
- Die ArgoCD-Race aus LL-2 ist eine kosmetische Stoerung, kein echtes Problem

**Bessere Reihenfolge fuer Zukunft** (z.B. wenn PVC nicht akut voll, sondern praeventiv):
1. `values-override.yaml` editieren
2. Git-Push
3. ArgoCD-Sync abwarten
4. Pod loeschen → Reattach + Filesystem-Resize
5. (kein manueller PVC-Patch noetig)

---

## 5. Verifikations-Befehle

### Status-Quick-Check pro Cluster
```bash
# PVC-Status
kubectl --context k8s-<env> -n monitoring get pvc thanos-compactor \
  -o jsonpath='{.spec.resources.requests.storage}/{.status.capacity.storage}'

# Filesystem-Auslastung
kubectl --context k8s-<env> -n monitoring exec \
  $(kubectl --context k8s-<env> -n monitoring get pod -l app.kubernetes.io/component=compactor -o name) \
  -- df -h /data

# ArgoCD-App
kubectl --context k8s-<env> -n argocd get app thanos \
  -o jsonpath='Sync={.status.sync.status} Health={.status.health.status}{"\n"}'

# Aktive Alerts (ohne Watchdog)
kubectl --context k8s-<env> -n monitoring exec \
  alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?active=true' \
  | python3 -c 'import sys,json; [print(a["labels"]["alertname"], a["labels"].get("severity","")) for a in json.load(sys.stdin) if a["labels"]["alertname"]!="Watchdog"]'
```

### Erwartetes Ergebnis nach Fix
- PVC: `30Gi/30Gi`
- Filesystem: `29.4G` total, ~5-15G belegt (je nach Workload), <50% Auslastung
- ArgoCD: `Sync=Synced Health=Healthy`
- Alerts: leer (nur Watchdog)

---

## 6. Geaenderte Dateien (Git)

```
kubernetes/environments/test/monitoring-thanos/values-override.yaml
kubernetes/environments/prod/monitoring-thanos/values-override.yaml
```

DEV-Override wurde am 05.05.2026 in separater Session geaendert.

---

## 7. Naechste Schritte / Monitoring

- **24-48h Beobachtung** auf TEST + PROD: Compactor-Logs, PVC-Auslastung, keine erneuten `ThanosCompactionFailed`
- **Erwartung:** PVC-Auslastung pendelt zwischen 0% (post-cleanup) und ~50-60% (Spitze waehrend Re-Compaction). Falls Auslastung auf >70% steigt, weitere Ursachen-Analyse (groesseres Retention, mehr Source-Bloecke).
- **Fuer Phase 9a Security TEST/PROD und folgende Phasen:** Dieser Fix ist die Voraussetzung fuer einen sauberen Cluster-State (keine Storming-Alerts mehr).

---

## 8. Querverweise

- **DEV-Vorlauf:** Phase 11 Lessons / "Ubuntu VMs in Clustern aktualisieren" (DEV-Fix 05.05.2026)
- **TEST-Phase-12b-Bezug:** [phase-12b-test-completed.md](phase-12b-test-completed.md) (Pre-Existing Issues — auf diesen Fix verweisend)
- **Runbook:** [runbooks/longhorn-volume-expansion-deadlock.md](../runbooks/longhorn-volume-expansion-deadlock.md)
- **Repository-Stand:** Projektplanung v2.20
