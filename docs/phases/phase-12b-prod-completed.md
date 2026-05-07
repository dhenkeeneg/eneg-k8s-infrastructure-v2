# Phase 12b — CoreDNS HA Rollout PROD — Completed

**Datum:** 07.05.2026
**Status:** ✅ ABGESCHLOSSEN
**Owner:** Daniel Henke
**Cluster:** k8s-prod-21/22/23 (192.168.178.21-23, K3s v1.35.1+k3s1)
**Voraussetzung:** Phase 12b TEST abgeschlossen 06.05.2026 (siehe `phase-12b-test-completed.md`)
**Resultat:** CoreDNS HA mit 3 Replicas auf 3 Nodes; K3s `--disable=coredns` persistent; alle 53 ArgoCD-Apps Synced/Healthy
**Burn-in TEST:** ~7h (verkuerzt von geplanten 24h, Rollout entschieden bei stabilem TEST-Lauf seit 06.05.2026 abends)

## Zusammenfassung

Plan B (CoreDNS HA via eigenem Helm-Chart) wurde auf PROD ausgerollt analog DEV+TEST. Der Cutover war **vollstaendig erfolgreich beim ersten Versuch**, ohne DNS-Outage und ohne unerwartete Probleme. Die TEST-Lessons (LL-T1 bis LL-T6) haben sich vollstaendig bewaehrt — der angepasste Plan im Handoff-Doc hat das Race-Risiko aus TEST sauber eliminiert.

**Performance vs DEV/TEST:**

| Aspekt | DEV (06.05.) | TEST (06.05.) | **PROD (07.05.)** |
|---|---|---|---|
| DNS-Outage | 0s | ~5min | **0s** |
| Race-Condition mit ArgoCD Auto-Sync | nein (anders Setup) | ja | **nein** (App ohne `automated:` deployed) |
| Wrangler-Cleanup-Risiko durch Playbook | n/a | umgangen reaktiv | **praeemptiv eliminiert** |
| `monitoring`-App PreSync-Hook-Hang | nein | ja | **nein** (sofort `Succeeded`) |
| Cutover-Versuche | 1 | 2 (1× Recovery, 1× sauber) | **1** |
| Pod-Verlust durch K3s-Restart | 0 (RESTARTS=0) | 0 (RESTARTS=0) | **0 (RESTARTS=0)** |

## Endzustand PROD

| Aspekt | Zustand |
|---|---|
| CoreDNS Pods | 3/3 Running, 1+1+1 auf k8s-prod-21/22/23, AntiAffinity wirksam, RESTARTS=0 |
| Service `kube-dns` | ClusterIP 10.43.0.10, 9 Endpoints (3 Pods × UDP-53/TCP-53/TCP-9153) |
| Service `coredns-metrics` | ClusterIP, 3 Endpoints, ServiceMonitor aktiv |
| K3s-Config `--disable=coredns` | Persistent in `/etc/rancher/k3s/config.yaml` aller 3 Nodes |
| Addon-CR `coredns` | Entfernt (`NotFound`), kommt nicht zurueck |
| ArgoCD App `coredns` | Synced/Healthy, Auto-Sync aktiv (prune:false, selfHeal:false) |
| ArgoCD App `monitoring` | Synced/Healthy, `kube-prometheus-stack-coredns` Service+SM gepruned |
| ServiceMonitor `coredns` (in monitoring-NS) | Aktiv mit `release: kube-prometheus-stack` Label |
| Globaler ArgoCD-Stand | Alle 53 Apps Synced/Healthy |
| End-to-End DNS | Cluster, cross-NS, extern, NodeHost — alle gruen |

## Verlauf der Session

### Schritt 1 — Vorbereitung (planmaessig, Windows-Laptop)

4 Files erstellt/geaendert auf Windows-Laptop:
- `ansible/inventory/prod/group_vars/all.yml` — `coredns` zu `k3s_disable` ergaenzt (1 Zeile)
- `kubernetes/environments/prod/coredns/values-override.yaml` — NEU mit PROD-IPs (192.168.178.21-23) als inline `hosts`-Plugin
- `kubernetes/environments/prod/infrastructure/coredns-app.yaml` — NEU, **OHNE `automated:` Block** (LL-T1 angewandt)
- `kubernetes/environments/prod/monitoring/values-override.yaml` — `coreDns.enabled: false` ergaenzt (oberhalb `prometheus:` Block)

Commit `2526fab5` auf main. Push.

### Schritt 2 — ArgoCD discovered Push, App ohne Auto-Sync angelegt

ArgoCDs `prod-infrastructure` App-of-Apps discovered den Push planmaessig schnell. Die `coredns`-App wurde angelegt mit:
- 9 Resources im Status `OutOfSync` / Health `Missing`
- `syncPolicy.automated:` **fehlte** wie geplant
- Folge: **kein** initialer Sync ausgeloest, kein Race mit dem manuellen Cutover

Verifiziert via `kubectl get application coredns -o yaml` — `automated:` war nicht im Spec.

### Schritt 3 — Manueller Cutover auf k8s-mgmt-10 (4 Phasen)

**Phase 1: Apply**
- Image-Pre-Warming: `sudo k3s ctr images pull docker.io/rancher/mirrored-coredns-coredns:1.14.1` auf alle 3 Nodes — Cache-Hit, ~2.7s pro Node
- `kubectl delete deployment coredns --cascade=background --wait=false` (altes K3s-Default-CoreDNS)
- `kubectl apply --server-side --force-conflicts -f /tmp/coredns-prod.yaml` — alle 9 Resources `serverside-applied`
- Rollout in 33s auf 3/3 Pods, 1+1+1 verteilt
- DNS-Test aus argocd-repo-server: kurzes False-Positive (Kommando-Artefakt mit `getent` ohne `2>&1`-Redirect → `exit code 2`); Verifikation aus zweitem Aufruf erfolgreich (`10.43.0.1`)

**Phase 2: Wrangler-Annotations strippen**
- Service `kube-dns`, ConfigMap `coredns`, ServiceAccount `coredns`
- 5 Annotations + 1 Label entfernt pro Resource:
  - `objectset.rio.cattle.io/applied`
  - `objectset.rio.cattle.io/id`
  - `objectset.rio.cattle.io/owner-gvk`
  - `objectset.rio.cattle.io/owner-name`
  - `objectset.rio.cattle.io/owner-namespace`
  - Label: `objectset.rio.cattle.io/hash`
- Verify: `grep objectset` liefert keine Treffer mehr

**Phase 3: Addon-CR loeschen**
- `kubectl delete addon.k3s.cattle.io coredns -n kube-system`
- DNS bleibt verfuegbar (kein Outage)
- Pods bleiben Running, RESTARTS=0
- Endpoints unveraendert (3 Pods)

**Phase 4: Ansible-Playbook (persistente K3s-Config)**
- Dry-Run mit `--check --diff`: zeigt sauber `+ - "coredns"` Diff in `disable:` Liste; Failure am Ende ist Check-Mode-Artefakt (`Command would have run if not in check mode`)
- Real-Run: PLAY RECAP `ok=6 changed=2 failed=0` auf allen 3 Nodes
- Sequenziell -21 → -22 → -23, je ~90s, total ca. 4-5 min
- Beobachtung: alle 3 CoreDNS-Pods nach komplettem Playbook-Run weiter `RESTARTS=0`, AGE unveraendert — K3s-Restart hat die laufenden Pods nicht angetastet (LL-T5 bestaetigt)

### Schritt 4 — ArgoCD-Adoption

- Hard refresh + manueller Sync mit `Force=true` (Field-Ownership-Uebernahme)
- 4 Iterationen Polling, dann `phase=Succeeded sync=Synced health=Healthy`
- Auto-Sync aktiviert via Patch:
  ```bash
  kubectl patch application coredns -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":false}}}}'
  ```
- Verifikation: `sync=Synced  health=Healthy  auto={"prune":false,"selfHeal":false}`

### Schritt 5 — `monitoring`-App Cleanup (kube-prometheus-stack-coredns)

**Ueberraschend einfach:** Hard refresh + manueller Sync mit `prune:true` lief direkt durch — `phase=Succeeded msg=successfully synced (no more tasks)` nach 60s. **Kein PreSync-Hook-Hang** wie in TEST (LL-T6 nicht eingetreten in PROD).

Verify:
- `service/kube-prometheus-stack-coredns` (in kube-system): NotFound ✅
- `servicemonitor/kube-prometheus-stack-coredns` (in monitoring): NotFound ✅
- `servicemonitor/coredns` (in monitoring) mit `release: kube-prometheus-stack` Label: aktiv ✅

### Schritt 6 — End-to-End-Verify

| Check | Resultat |
|---|---|
| `getent hosts kubernetes.default.svc.cluster.local` | `10.43.0.1` ✅ |
| `getent hosts argocd-repo-server.argocd.svc.cluster.local` | `10.43.8.212` ✅ |
| `getent hosts github.com` (extern via forward) | `140.82.121.4` ✅ |
| `getent hosts k8s-prod-21` (NodeHost, hosts-Plugin) | `192.168.178.21` ✅ |
| Globaler ArgoCD App-Drift | `✅ alle Apps Synced/Healthy` |
| K3s-Config persistent auf -21/-22/-23 | `coredns` in `disable:` Liste auf allen Nodes ✅ |
| Addon-CR `coredns` | `Error from server (NotFound)` ✅ |

## Lessons Learned

### LL-P1 (Bestaetigung): TEST-Lessons LL-T1 bis LL-T6 sind alle korrekt

Der angepasste Plan im Handoff (App ohne `automated:`, Strip-Annotations vor Playbook, Apply vor Playbook) hat in PROD **vollstaendig wie geplant** funktioniert. Kein Fehler, kein Drama, kein DNS-Outage.

→ **Konsequenz:** Das Handoff-Doc `phase-12b-coredns-test-prod-handoff.md` und die TEST-Lessons sind als verlaesslicher Referenzplan etabliert. Bei aehnlichen Vorhaben in Zukunft (z.B. weitere Wrangler-Addon-Migrationen wie `metrics-server` oder `traefik`-Replacement) den gleichen Cutover-Pattern uebernehmen.

### LL-P2 (Beobachtung): `monitoring`-Sync ohne Hook-Hang

Im TEST hatte der `monitoring`-Sync einen PreSync-Hook-Hang (LL-T6). In PROD nicht. Vermutung: PROD hatte den `kube-prometheus-stack-admission-create` Job nicht so lange im Reconciler-Cache wie TEST (vielleicht wegen eines spaeteren `monitoring`-Sync-Events das den Tracker geleert hat).

→ **Konsequenz:** LL-T6 bleibt im Werkzeugkasten als bekannter Workaround, ist aber kein Muss-Schritt. Beim naechsten Mal weiter so vorgehen: erst sauber syncen lassen, nur wenn Hook-Hang auftritt den Workaround anwenden.

### LL-P3 (Tooling): `getent` ohne stderr-Redirect kann Pseudo-Failure liefern

Beim ersten DNS-Test in Phase 1 lieferte `kubectl exec ... sh -c "getent hosts ..."` `command terminated with exit code 2`, obwohl die spaetere identische Pruefung sauber lief. Vermutung: Stderr-Output (z.B. NSS-Cache-Initialisierung) hat das Exit-Status-Forwarding durch `kubectl exec` durcheinander gebracht.

→ **Konsequenz fuer zukuenftige DNS-Tests:** Immer `2>&1` verwenden oder Verifikation per `nslookup`/`dig` aus einem Pod mit voll ausgestattetem Image.

## Verbleibende Beobachtungen / Nicht-12b-Themen

Keine. Cluster meldet ausschliesslich `Watchdog`-Alert (gewuenscht, Dead-Man's-Switch). Keine offenen Critical/Warning-Alerts.

## Nächste Schritte (Block 2 der Roadmap)

Phase 12b komplett abgeschlossen (DEV+TEST+PROD). Naechster Block laut `roadmap-handoff-2026-05-06.md`:

- **Block 2:** TEST OS-Update (Rolling Reboot mit Kernel-Update, Drain/Cordon-Pattern aus DEV-Erfahrung)
  - Voraussetzung: Block 1 (PROD CoreDNS HA) **24h Burn-in stabil** → frühestens 08.05.2026 nachmittags
  - Bezugsdoc: `docs/phases/phase-11-rolling-os-update-dev.md`
- **Block 3:** PROD OS-Update (nach Block 2 + 24h Burn-in)
- **Block 4:** Phase 9a Etappe B (PROD-Zot, kombiniert mit Plan A Zot-HA)
- **Block 5:** CrowdSec/Falco

## Anhaenge

- **Vorgaengerdokumente (chronologisch):**
  - `phase-12-ha-improvements-completed.md` (DEV, 06.05.2026)
  - `phase-12b-test-completed.md` (TEST, 06.05.2026)
  - `phase-12b-coredns-test-prod-handoff.md` (Plan, eingearbeitete TEST-Lessons)
- **Verwandtes:**
  - `roadmap-handoff-2026-05-06.md` (Block-Struktur)
  - `monitoring-thanos-pvc-resize-test-prod.md` (vorheriger Mini-Block 06.05.)
  - `docs/runbooks/longhorn-volume-expansion-deadlock.md` (verwandter Mini-Run-Book aus 06.05.)
