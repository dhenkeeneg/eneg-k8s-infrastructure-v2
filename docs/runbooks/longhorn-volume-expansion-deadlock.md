# Runbook: Longhorn Volume Expansion Deadlock

**Kategorie:** Storage / Longhorn
**Erstellt:** 06.05.2026 (Aufgetreten in TEST + PROD beim Thanos-PVC-Resize)
**Stichworte:** Multi-Attach error, expansionRequired, Engine expansion loop

---

## Symptom

Nach einem PVC-Resize (`kubectl patch pvc ... requests.storage`) bleibt ein neu gestarteter Pod in `ContainerCreating` haengen. Events zeigen:

```
Multi-Attach error for volume "pvc-<uid>"
  Volume is already used by pod(s) <alter-pod-name>
AttachVolume.Attach failed for volume "pvc-<uid>" :
  rpc error: code = Internal desc = volume pvc-<uid> failed to attach to node <neuer-node>
  with attachmentID csi-...: the volume is currently attached to different node <alter-node>
```

Auch wenn der alte Pod laengst geloescht ist, bleibt das Volume an den alten Node "geklebt".

## Diagnose

### 1. Pod-Status pruefen
```bash
kubectl --context k8s-<env> -n <ns> get pod <pod-name> -o wide
# Erwartet: STATUS=ContainerCreating, NODE=<neuer-Node>
```

### 2. Volume-Name finden
```bash
kubectl --context k8s-<env> -n <ns> get pvc <pvc-name> \
  -o jsonpath='{.spec.volumeName}'
# Output: pvc-<uid>
```

### 3. Longhorn-Volume-Status pruefen
```bash
kubectl --context k8s-<env> -n longhorn-system get volume.longhorn.io <pvc-uid> \
  -o jsonpath='State: {.status.state}
ExpansionRequired: {.status.expansionRequired}
CurrentNode: {.status.currentNodeID}
SpecNode: {.spec.nodeID}
SpecSize: {.spec.size}
{"\n"}'
```

**Deadlock-Indikatoren:**
- `State: attached`
- `ExpansionRequired: true`
- `CurrentNode = SpecNode = <alter-Node>` (obwohl Pod auf neuem Node geschedulet ist)

### 4. Longhorn-Engine-Status pruefen
```bash
kubectl --context k8s-<env> -n longhorn-system get engine.longhorn.io \
  -l longhornvolume=<pvc-uid> \
  -o jsonpath='VolumeSize: {.items[0].spec.volumeSize}
CurrentSize: {.items[0].status.currentSize}
State: {.items[0].status.currentState}
{"\n"}'
```

**Deadlock-Indikator:**
- `VolumeSize > CurrentSize` (z.B. 32212254720 vs 10737418240)
- `State: running`

### 5. Longhorn-Manager-Logs (optional, fuer Bestaetigung)
```bash
kubectl --context k8s-<env> -n longhorn-system logs \
  -l app=longhorn-manager --tail=20 -c longhorn-manager \
  | grep "engine expansion"
```

**Deadlock-Indikator:**
- Wiederholte `Starting engine expansion from <alt> to <neu>`-Meldungen alle 5s ohne Fortschritt.

## Behebung

### Trigger: Volume manuell detachen

```bash
kubectl --context k8s-<env> -n longhorn-system patch volume.longhorn.io <pvc-uid> \
  --type=merge -p '{"spec":{"nodeID":""}}'
```

Was passiert:
1. Longhorn detached das Volume sauber vom alten Node.
2. Volume-State wechselt: `attached → attaching` (mit `nodeID=""`).
3. **Offline-Expansion** laeuft durch (Sekunden statt Loop).
4. `ExpansionRequired` wechselt auf `false`.
5. Longhorn entscheidet sich neu auf welchen Node attached wird (anhand wartender VolumeAttachments) und attached auf den **neuen** Node.
6. Pod kommt aus `ContainerCreating` → `Running`.
7. Filesystem-Resize (`resize2fs`) laeuft beim Mount automatisch.

### Verifikation
```bash
# Volume sollte attached, ohne expansion-required sein
kubectl --context k8s-<env> -n longhorn-system get volume.longhorn.io <pvc-uid> \
  -o jsonpath='State: {.status.state} ExpReq: {.status.expansionRequired} Node: {.status.currentNodeID}{"\n"}'
# Expected: State: attached  ExpReq: false  Node: <neuer-node>

# Pod sollte Running sein
kubectl --context k8s-<env> -n <ns> get pod <pod-name>
# Expected: STATUS=Running, READY=1/1

# Filesystem zeigt neue Groesse
kubectl --context k8s-<env> -n <ns> exec <pod-name> -- df -h /data
# Expected: neue Groesse (z.B. 29.4G fuer 30Gi PVC)
```

## Wann tritt der Deadlock auf?

**Bekannte Ausloeser:**
- PVC-Resize via `kubectl patch` waehrend ein Pod gerade gestoppt wird und Kubernetes den naechsten auf einem **anderen Node** schedulet.
- Schreib-Last auf dem Volume zum Zeitpunkt des Patch (Block-Expansion gerade aktiv waehrend Detach-Versuch).

**Beobachtete Faelle (eNeG):**
- 06.05.2026 TEST `thanos-compactor` 10Gi → 30Gi (PVC-uid `dca19dc6-...`)
- 06.05.2026 PROD `thanos-compactor` 10Gi → 30Gi (PVC-uid `6299ae5a-...`)
- 05.05.2026 DEV `thanos-compactor` 10Gi → 30Gi: **kein** Deadlock — Longhorn hat von selbst aufgeloest. Wahrscheinlich abhaengig von Last und Timing.

## Praevention

Fuer geplante PVC-Resizes (nicht akut-voll):
1. **Erst** das gewuenschte Soll in Git committen + ArgoCD synct (oder Helm-Upgrade).
2. **Dann** Pod loeschen — Resize laeuft ohne Doppel-Patch durch.
3. Falls trotzdem haengt: dieses Runbook anwenden.

Bei akutem Resize-Bedarf (PVC laeuft voll): manueller PVC-Patch + spaeter Git-Sync ist ok, aber Detach-Trick eventuell noetig.

## Verwandte Themen

- Longhorn Doku Online-Expansion: https://longhorn.io/docs/1.9.2/volumes-and-nodes/expansion/
- Longhorn-Bug-Tracker: ggf. Issue erstellen wenn Pattern reproduzierbar in spaeteren Versionen
- Longhorn-Version (eNeG): v1.9.2 (Longhorn-Engine v1.9.2)
- ArgoCD-Bezug: bei Resize-Konflikten sieht ArgoCD ggf. `field can not be less than status.capacity` — siehe `phases/monitoring-thanos-pvc-resize-test-prod.md` LL-2.
