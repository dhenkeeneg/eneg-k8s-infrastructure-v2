# Runbook: Behutsamer Wiederanlauf k8s-test nach Langzeit-Abschaltung

**Erstellt:** 2026-06-29
**Umgebung:** k8s-test (k8s-test-21/22/23, K3s embedded etcd)
**Zweck:** Wiederanlauf des seit dem Rebuild-Sturm abgeschalteten TEST-Clusters,
ohne erneut eine Longhorn-Rebuild-/IO-Kaskade auszuloesen.
**Strategie:** Variante A — Zeitfenster-basiert (nutzt `replicaReplenishmentWaitInterval: 600`).
**Bezug:**
- `docs/incidents/2026-06-29-cnpg-wal-deadlock-longhorn-kaskade.md`
- `docs/phases/phase-13-kyverno-longhorn-stabilization-dev.md`
- `docs/phases/resilienz-haertung-wal-deadlock-dev.md`

> **Wichtig:** Dieses Runbook beschreibt NUR den sicheren Wiederanlauf.
> Das Nachziehen der DEV-Aenderungen (Phase 13b, PriorityClass, CNPG-Haertung,
> Velero/S3) ist ein **getrenntes** Vorhaben und erfolgt erst NACH stabilem Anlauf.

---

## Vorbemerkung: Warum dieses Vorgehen

ArgoCD ist reaktiv — es greift erst, wenn der Cluster bereits laeuft. Die
eigentliche Sturm-Bremse sitzt im **persistierten Cluster-State** (Longhorn
Settings-CRD in etcd) und greift beim Boot sofort:

- `replicaReplenishmentWaitInterval: 600` → Longhorn wartet **10 Minuten** nach
  Boot, bevor es fehlende Replicas ueberhaupt neu aufbaut. **Das ist unser Fenster.**
- `concurrentReplicaRebuildPerNodeLimit: 2` → danach max. 2 Rebuilds/Node parallel.

Da K3s **embedded etcd** nutzt, ist die kube-API erst mit **2 von 3** Nodes
(Quorum) schreibbar. Mit nur 1 Node kann auch kein Rebuild-Sturm entstehen
(Longhorn braucht Quorum + mehrere Nodes). Wir nutzen das 10-Minuten-Fenster nach
Quorum-Bildung, um zwei Bremsen scharf zu stellen, bevor der Wait-Interval ablaeuft.

**ArgoCD laeuft pro Cluster lokal** (im TEST-Cluster selbst, nicht zentral auf
mgmt-10). Es startet beim Boot mit hoch — deshalb muss es im Fenster auf 0
skaliert werden, bevor es den Base-Longhorn-Stand (`best-effort` Auto-Balance)
reconcilet.

---

## Voraussetzungen / Rollen

- **VM Power-On:** Daniel (vSphere). Claude hat keinen vSphere-Zugriff.
- **kubectl-Befehle:** Claude (per Kubernetes MCP) ODER Daniel (Terminal auf mgmt-10).
- **kubectl-Context:** `k8s-test`
- Vor Start: sicherstellen, dass alle 3 VMs aktuell **AUS** sind (verifiziert
  2026-06-29: `kubectl get nodes --context k8s-test` → Timeout, Cluster aus).

---

## Phase 0 — Pre-Flight (Cluster noch aus)

- [ ] Repo aktuell? `git pull --rebase` auf der genutzten Maschine.
- [ ] vSphere-Konsolenzugriff auf k8s-test-21/22/23 vorhanden.
- [ ] Dieses Runbook offen, kubectl-Context `k8s-test` griffbereit.
- [ ] Klar: Reihenfolge der Nodes ist **-22 → -23 → -21**.
      (-21 zuletzt, da historisches Sorgenkind: EXT4-Errors Mai, iSCSI-Altlasten Juni.)

---

## Phase 1a — Erster Node antesten (-22)

**Ziel:** Funktionstest eines einzelnen Nodes. Kein Quorum, keine schreibbare API,
keine Rebuild-Gefahr. Reiner Health-Check des Nodes.

**Daniel (vSphere):**
- [ ] VM `k8s-test-22` einschalten. k3s startet normal (NICHT deaktivieren).

**Warten:** ~2-3 Min, bis K3s-Server-Prozess laeuft.

**Verifikation (Daniel, SSH auf k8s-test-22 — optional aber empfohlen):**
```bash
# K3s-Service-Status
sudo systemctl status k3s --no-pager | head -20

# Disk-Health pruefen (Lehre aus Mai-Incident: EXT4 Medium-Errors)
sudo dmesg -T | grep -iE 'ext4|i/o error|medium error' | tail -20
# Erwartung: KEINE neuen I/O- oder Medium-Errors

# Longhorn-Datenpfad vorhanden + mountbar
df -h /var/lib/longhorn
```

**Erwartung:**
- k3s-Service laeuft (auch ohne Quorum — Server-Prozess startet, etcd wartet auf Peers).
- `kubectl get nodes --context k8s-test` ist evtl. noch nicht / nur read-only erreichbar
  (kein Quorum) — das ist normal und OK.
- **Keine** Disk-/IO-Errors auf dem Node.

> **Stopp-Kriterium:** Wenn auf -22 Disk-/EXT4-Fehler auftauchen → NICHT weitermachen.
> Erst Node-Disk klaeren (analog Mai-Incident). Lieber -23 als ersten Node testen.

---

## Phase 1b — Zweiter Node → Quorum → SOFORT bremsen (-23)

**Das ist der kritische Schritt. Die zwei Bremsen muessen innerhalb von ~10 Min
nach Quorum-Bildung gesetzt werden (vor Ablauf des replenishment-wait-interval).**

**Daniel (vSphere):**
- [ ] VM `k8s-test-23` einschalten.

**Warten:** bis Quorum steht und API schreibbar ist. Pruefen mit:
```bash
kubectl get nodes --context k8s-test
# Erwartung: k8s-test-22 + k8s-test-23 sichtbar (ggf. NotReady/SchedulingDisabled
# anfangs), API antwortet auf Schreib-Lese-Zugriff.
```

**Sobald API antwortet — DIESE ZWEI BEFEHLE ZUERST, in dieser Reihenfolge:**

**(1) ArgoCD application-controller auf 0 skalieren** (stoppt Base-Reconcile):
```bash
kubectl --context k8s-test -n argocd scale statefulset \
  argocd-application-controller --replicas=0
```
Verifikation:
```bash
kubectl --context k8s-test -n argocd get statefulset argocd-application-controller
# Erwartung: READY 0/0
```

**(2) Longhorn Rebuild-Limit auf 0** (stoppt alle automatischen Rebuilds):
```bash
kubectl --context k8s-test -n longhorn-system patch settings.longhorn.io \
  concurrent-replica-rebuild-per-node-limit \
  --type=merge -p '{"value":"0"}'
```
Verifikation:
```bash
kubectl --context k8s-test -n longhorn-system get settings.longhorn.io \
  concurrent-replica-rebuild-per-node-limit -o jsonpath='{.value}'
# Erwartung: 0
```

> **Hinweis:** Falls die Longhorn-Manager-Pods/CRDs in den ersten Minuten noch nicht
> bereit sind (`settings.longhorn.io not found` oder `no endpoints`), kurz warten und
> Befehl (2) wiederholen. Das 10-Min-Fenster gilt ab dem Moment, in dem Longhorn-Manager
> laeuft — nicht ab Quorum. In der Praxis ist Longhorn erst nach Quorum oben, also bleibt
> Puffer. Im Zweifel den Status pruefen:
> ```bash
> kubectl --context k8s-test -n longhorn-system get pods -l app=longhorn-manager
> ```

**Kontroll-Check: laufen Rebuilds?**
```bash
# Volumes mit aktivem Rebuild (rebuildStatus) finden
kubectl --context k8s-test -n longhorn-system get engines.longhorn.io \
  -o json | python -c "import sys,json; d=json.load(sys.stdin); \
[print(e['metadata']['name'], e.get('status',{}).get('rebuildStatus')) \
for e in d['items'] if e.get('status',{}).get('rebuildStatus')]"
# Erwartung: leer (keine Ausgabe) = keine aktiven Rebuilds
```

> **Stopp-/Notfall-Kriterium:** Falls hier bereits Rebuilds laufen → siehe
> Abschnitt "Notfall: Sturm laeuft trotzdem an" unten. Nicht Node -21 starten,
> solange Rebuilds aktiv sind.

---

## Phase 1c — Dritter Node kontrolliert dazu (-21)

**Voraussetzung:** Bremsen (1)+(2) verifiziert aktiv, 0 aktive Rebuilds.

**Daniel (vSphere):**
- [ ] VM `k8s-test-21` einschalten.

**Warten + beobachten** (-21 ist das Sorgenkind):
```bash
kubectl get nodes --context k8s-test
# Erwartung: alle 3 Nodes sichtbar, werden nach und nach Ready.

# Disk-Health -21 (Daniel, SSH):
sudo dmesg -T | grep -iE 'ext4|i/o error|medium error' | tail -20
```

**Wiederholt pruefen, dass Rebuild-Limit weiterhin 0 ist** (ArgoCD ist auf 0, sollte
also nicht zuruecksetzen — trotzdem kontrollieren):
```bash
kubectl --context k8s-test -n longhorn-system get settings.longhorn.io \
  concurrent-replica-rebuild-per-node-limit -o jsonpath='{.value}'
# Erwartung: 0
```

**Gesamtbild Volumes:**
```bash
kubectl --context k8s-test -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness
# Erwartung: viele 'degraded' (normal nach Langzeit-Aus) — aber KEINE aktiven Rebuilds,
# weil Limit=0. Volumes attachen, ohne dass rebuilt wird.
```

---

## Phase 2 — Cluster beruhigen, dann Rebuilds KONTROLLIERT zulassen

**Erst wenn alle 3 Nodes Ready sind und das Bild stabil ist** (keine flappenden
Pods, keine Disk-Errors), lassen wir Rebuilds gezielt und langsam wieder zu.

**Schritt 2.1 — Limit von 0 auf 1 (ein Rebuild pro Node, maximal sanft):**
```bash
kubectl --context k8s-test -n longhorn-system patch settings.longhorn.io \
  concurrent-replica-rebuild-per-node-limit \
  --type=merge -p '{"value":"1"}'
```

**Beobachten** (mehrere Minuten), wie die Rebuilds anlaufen — einzeln, nicht als Welle:
```bash
watch -n 10 "kubectl --context k8s-test -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness"
```

**IO-Last im Blick behalten** (Daniel, SSH auf je einem Node):
```bash
iostat -x 5 3   # %util der Longhorn-Disks beobachten
```

> **Faustregel:** Solange %util der Datastores nicht dauerhaft an 100% klebt und
> die Nodes Ready bleiben, ist Limit=1 sicher. Erst wenn ein Grossteil der Volumes
> wieder `healthy` ist, auf 2 erhoehen.

**Schritt 2.2 — wenn ruhig: zurueck auf Base-Default 2:**
```bash
kubectl --context k8s-test -n longhorn-system patch settings.longhorn.io \
  concurrent-replica-rebuild-per-node-limit \
  --type=merge -p '{"value":"2"}'
```

**Ziel:** alle Volumes `healthy`, Robustness nicht mehr `degraded`.
```bash
kubectl --context k8s-test -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,ROBUSTNESS:.status.robustness | grep -v healthy
# Erwartung am Ende: nur die Header-Zeile, sonst leer
```

---

## Phase 3 — ArgoCD reaktivieren (Reconcile wieder anschalten)

**Erst wenn Storage stabil ist** (alle Volumes healthy), ArgoCD wieder hochfahren.
ArgoCD zieht dann den Repo-Stand — der ist fuer TEST noch der ALTE (Base
`best-effort` Auto-Balance, kein Phase-13-Override). Das ist OK fuer den reinen
Wiederanlauf; der DEV-Nachzug kommt als getrenntes Vorhaben danach.

```bash
kubectl --context k8s-test -n argocd scale statefulset \
  argocd-application-controller --replicas=1
```

Verifikation:
```bash
kubectl --context k8s-test -n argocd get statefulset argocd-application-controller
# Erwartung: READY 1/1

# Nach ein paar Minuten App-Status pruefen:
kubectl --context k8s-test -n argocd get applications
# Erwartung: Apps gehen nach und nach auf Synced/Healthy.
```

> **Achtung Longhorn-Setting vs. ArgoCD:** Das per kubectl gesetzte Rebuild-Limit
> (jetzt 2) entspricht dem Base-Default — ArgoCD wird es also NICHT ueberschreiben.
> Haetten wir es auf einem Nicht-Default-Wert gelassen, koennte selfHeal es
> zuruecksetzen. Da Endwert = Base-Default (2), kein Konflikt.

---

## Phase 4 — Workloads-/DB-Gesundheit verifizieren

Nach ArgoCD-Reaktivierung die zustandsbehafteten Dienste pruefen (Reihenfolge:
Storage → DB → Apps):

```bash
# CNPG-Cluster (beide), Container postgres explizit
kubectl --context k8s-test -n databases get cluster.postgresql.cnpg.io
# Erwartung: beide "Cluster in healthy state", je 1 Primary

# MariaDB Galera
kubectl --context k8s-test -n databases get mariadb
# Erwartung: Ready/Running, Quorum vorhanden

# Alle nicht-laufenden Pods clusterweit
kubectl --context k8s-test get pods -A --field-selector=status.phase!=Running | grep -v Completed
# Erwartung: leer (ggf. kurzzeitig Init/ContainerCreating)
```

**Aktive Alerts pruefen** (ohne Watchdog):
```bash
kubectl --context k8s-test -n monitoring exec \
  alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false'
```

---

## Notfall: Sturm laeuft trotzdem an

Falls in Phase 1b/1c entgegen der Erwartung Rebuilds als Welle starten:

1. **Sofort Limit hart auf 0** (falls noch nicht 0 oder zurueckgesetzt):
   ```bash
   kubectl --context k8s-test -n longhorn-system patch settings.longhorn.io \
     concurrent-replica-rebuild-per-node-limit --type=merge -p '{"value":"0"}'
   ```
2. **Pruefen, ob ArgoCD wirklich auf 0 ist** (haette das Setting zuruecksetzen koennen):
   ```bash
   kubectl --context k8s-test -n argocd get statefulset argocd-application-controller
   # Falls nicht 0/0 → erneut auf 0 skalieren.
   ```
3. **Auto-Balance zusaetzlich abschalten** (zweite Rebuild-Quelle):
   ```bash
   kubectl --context k8s-test -n longhorn-system patch settings.longhorn.io \
     replica-auto-balance --type=merge -p '{"value":"disabled"}'
   ```
4. **Wait-Interval hochsetzen** (mehr Ruhe vor Replenishment):
   ```bash
   kubectl --context k8s-test -n longhorn-system patch settings.longhorn.io \
     replica-replenishment-wait-interval --type=merge -p '{"value":"3600"}'
   ```
5. Laufende Rebuilds **abebben lassen** (nicht hart abbrechen), dann erst wieder
   schrittweise oeffnen (Phase 2).

> Auto-Balance nach Stabilisierung wieder auf Base-Default `best-effort` zuruecksetzen,
> sonst OutOfSync ggü. Repo. Wait-Interval ebenso zurueck auf 600.

---

## Rollback / Abbruch

- Wiederanlauf jederzeit abbrechbar durch Herunterfahren der zuletzt gestarteten VM.
- Solange Limit=0 und ArgoCD=0, ist der Cluster im "eingefrorenen" Zustand sicher.
- Keine destruktiven Aktionen in diesem Runbook — alle Aenderungen sind reversibel
  (Settings-Patch, Scale). Keine PVC-/Volume-Loeschung.

---

## Was dieses Runbook bewusst NICHT tut

- **Kein DEV-Nachzug** (Phase 13b Kyverno/Longhorn-Override, PriorityClass,
  CNPG `max_slot_wal_keep_size`, Operator 1.28.3, Velero/S3 Phase 14a) — getrenntes
  Vorhaben, erst nach stabilem Anlauf, dann sauber GitOps DEV→TEST-Muster.
- **Kein etcd-Eingriff**, kein Editieren lokaler k3s-Manifeste.
- **Kein paralleles Hochfahren** mehrerer Nodes.

---

## Checkliste (Kurzform zum Abhaken)

- [ ] Phase 0: Pre-Flight, alle VMs aus, Repo aktuell
- [ ] Phase 1a: -22 an, Health-Check OK (keine Disk-Errors)
- [ ] Phase 1b: -23 an → Quorum → ArgoCD=0 → Longhorn-Limit=0 → 0 Rebuilds verifiziert
- [ ] Phase 1c: -21 an, alle Ready, Limit weiterhin 0, keine Disk-Errors
- [ ] Phase 2: Limit 0→1, beobachten; wenn ruhig 1→2; alle Volumes healthy
- [ ] Phase 3: ArgoCD=1, Apps Synced/Healthy
- [ ] Phase 4: CNPG/Galera healthy, keine nicht-laufenden Pods, nur Watchdog-Alert
- [ ] Abschluss: kurze Notiz/Update in Projektplanung, Entscheidung ueber DEV-Nachzug
