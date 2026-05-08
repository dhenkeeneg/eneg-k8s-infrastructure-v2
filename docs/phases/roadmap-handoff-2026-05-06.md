# Roadmap-Handoff — Stand 06.05.2026 Nachmittag

**Status:** Aktueller Master-Plan fuer die naechsten ~2 Wochen
**Erstellt:** 06.05.2026 (nach erfolgreichem Thanos-PVC-Resize TEST + PROD)
**Aktualisiert:** 07.05.2026 (Block 1 PROD CoreDNS HA abgeschlossen)
**Owner:** Daniel Henke
**Naechste Aktion:** Block 2 — Phase 11 Rolling OS-Update TEST (frueh. 08.05.2026 nachmittags nach 24h PROD-Burn-in)

---

## 1. Kontext & Stand 06.05.2026

### Heute abgeschlossen
- **Thanos Compactor PVC 10Gi → 30Gi** in TEST und PROD (analog DEV vom 05.05.)
- Doku: `docs/phases/monitoring-thanos-pvc-resize-test-prod.md`
- Runbook NEU: `docs/runbooks/longhorn-volume-expansion-deadlock.md` (erstes File im runbooks/-Verzeichnis)
- Querverweis-Update: `docs/phases/phase-12b-test-completed.md`

### Cluster-Health (Verifikation 06.05.2026 ~17:00 UTC)
| Cluster | Nodes | ArgoCD Apps | Aktive Alerts (ohne Watchdog) | Thanos Compactor PVC |
|---|---|---|---|---|
| **DEV** | 3/3 Ready | ✅ | ✅ keine | 30Gi (gefixt 05.05.) |
| **TEST** | 3/3 Ready | ✅ Synced/Healthy | ✅ keine | 30Gi (gefixt 06.05.) |
| **PROD** | 3/3 Ready | ✅ Synced/Healthy | ✅ keine | 30Gi (gefixt 06.05.) |

### Letzte abgeschlossene Phasen (Chronologie)
| Datum | Phase / Aktion | Scope |
|---|---|---|
| 22.04. | Phase 9a Etappe A — Trivy Mirror Fix | DEV |
| 30.04. | Phase 11 — Rolling OS-Update (mit Vorfall, triggerte Phase 12) | DEV |
| 06.05. fruh | Phase 12 Plan A — Zot HA (3 Replicas + Anti-Affinity) | DEV |
| 06.05. fruh | Phase 12 Plan B — CoreDNS HA via eigenem Helm-Chart | DEV |
| 06.05. mittag | Phase 12b — CoreDNS HA Rollout (mit 5min DNS-Outage) | TEST |
| 06.05. nachmittag | Thanos Compactor PVC Resize | TEST + PROD |
| 07.05. fruh | Phase 12b — CoreDNS HA Rollout (0s Outage, sauber beim 1. Versuch) | **PROD** |

**Projektplanung:** v2.20 (`docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.20.md`)

---

## 2. Backlog priorisiert

### 🔴 Hohe Prioritaet — mit Deadline-Charakter

| # | Aufgabe | Voraussetzung | Risiko | Aufwand | Doku |
|---|---|---|---|---|---|
| 1 | ~~Phase 12b CoreDNS HA **PROD**~~ ✅ ABGESCHLOSSEN 07.05.2026 | TEST 24h Burn-in | Mittel | 1-2h (real ~1h) | phase-12b-prod-completed.md |
| 2 | Phase 11 Rolling OS-Update **TEST** | Block 1 fertig | Mittel | 3-4h | phase-11-rolling-os-update-dev.md |
| 3 | Phase 11 Rolling OS-Update **PROD** | Block 2 verifiziert | Mittel | 3-4h | (gleich) |
| 4 | Phase 9a Etappe B — PROD-Zot + Cutover | Block 3 fertig (nicht zwingend, aber sauberer) | Mittel | 0,5-1 Tag | guides/phase-09a-test-prod-handoff.md |

### 🟡 Mittlere Prioritaet

| # | Aufgabe | Voraussetzung | Aufwand |
|---|---|---|---|
| 5 | Phase 9 — CrowdSec DEV → TEST → PROD | Block 4 fertig | 1 Tag DEV + je 2-3h |
| 6 | Phase 9 — Falco DEV → TEST → PROD | Nach CrowdSec | 1 Tag DEV + je 2-3h |
| 7 | Trivy in TEST + PROD ausrollen | Block 4 (Zot in PROD verfuegbar) | je 2-3h |
| 8 | Helm Chart Update Review (alle Charts) | Phase 9 fertig | ~1 Tag Recherche |
| 9 | ADR-002 Branch-per-Environment Migration | Optional, wann passt | 0,5-1 Tag |
| 10 | ArgoCD Self-Management via Helm-Chart | Vorbereitend fuer ArgoCD-Upgrades | 1-2 Tage |

### 🟢 Niedrige Prioritaet / Reaktiv

- i-doit PROD Setup-Wizard (falls noch nicht durch — Memory-Erinnerung)
- 24-48h Compactor-Beobachtung TEST + PROD (passive)
- Dokumentation `docs/phases/README.md` aktualisieren (Stand 25.02.2026, sehr veraltet)

---

## 3. Vorgeschlagener Zeitplan

### Block 1 — HA-Improvements abschliessen (1-2 Tage)
- **07.05. mittag:** Phase 12b CoreDNS HA **PROD** (24h Burn-in TEST war ab 06.05. nachmittag)
- **08.05.:** 24h Burn-in PROD verifizieren

### Block 2 — Rolling OS-Update TEST (1 Tag)
- **08.-09.05.:** Phase 11 OS-Update **TEST** (verbesserte Maintenance-Playbooks aus DEV-Vorfall)

### Block 3 — Rolling OS-Update PROD (1 Tag)
- **12.05.:** Phase 11 OS-Update **PROD** (nach TEST-Verifikation)

### Block 4 — Phase 9a Etappe B (1 Tag)
- **13.-14.05.:** PROD-Zot deployen + Warm-up + containerd-Cutover (schliesst gleichzeitig Zot HA in PROD ab)

### Block 5 — Phase 9 weiter (2-4 Tage)
- **15.05. ff:** CrowdSec DEV → Falco DEV → Verifikation → TEST/PROD-Rollouts

### Block 6 — Stabilisierung & Hygiene (1-2 Tage, optional, nach Block 5)
- Helm-Chart-Update-Review
- ADR-002 Branch-per-Environment Migration

---

## 4. Block 1 — Detail-Anweisung CoreDNS HA PROD (sofort startbar nach 24h Burn-in)

### Voraussetzungen pruefen
1. TEST laeuft seit min. 24h ohne CoreDNS- oder DNS-bezogene Alerts → frueh. **07.05.2026 mittags**
2. PROD-Cluster gesund (alle Nodes Ready, alle ArgoCD Apps Synced/Healthy)
3. CoreDNS-Image im PROD-Cache pruefen:
   ```bash
   for n in k8s-prod-21 k8s-prod-22 k8s-prod-23; do
     ssh ansible@$n "sudo k3s ctr images list | grep coredns" || echo "Pull noetig auf $n"
   done
   # Falls Pull noetig: sudo k3s ctr images pull docker.io/rancher/mirrored-coredns-coredns:1.14.1
   ```

### Kritische Race-Condition (TEST-Lesson)

**ArgoCD App-of-Apps discovered Push <60 s** und triggert Auto-Sync, bevor manueller Apply durchgehen kann.

**Vorgehen fuer PROD:**
1. `coredns-app.yaml` **OHNE** `automated:` Block deployen (kein Auto-Sync initial)
2. Wrangler-Annotations `objectset.rio.cattle.io/*` aus K3s-Default-Resources strippen **vor** Playbook
3. Addon-CR direkt deleten
4. Apply **vor** Playbook (nicht parallel/nach)
5. Nach erfolgreichem Cutover: `automated:` Block nachtraeglich aktivieren

### Detaillierter Ablauf
Siehe **`docs/phases/phase-12b-coredns-test-prod-handoff.md`** — dort ist der komplette PROD-Plan inkl. aller TEST-Lessons eingearbeitet (Stand 06.05.2026).

Vier Files zu erstellen/aendern:
1. `ansible/inventory/prod/group_vars/all.yml` — `k3s_disable: + coredns`
2. `kubernetes/environments/prod/coredns/values-override.yaml` — Corefile mit PROD NodeHosts (k8s-prod-21/22/23 + 192.168.178.x)
3. `kubernetes/environments/prod/coredns/kustomization.yaml`
4. `kubernetes/environments/prod/infrastructure/coredns-app.yaml` — ArgoCD App, **ohne** automated initial

### Verifikation nach Cutover
- 3/3 CoreDNS Pods Ready, je 1 pro Node
- ServiceAccount `coredns` (dediziert)
- Service `kube-dns` @ 10.43.0.10
- Service `coredns-metrics` @ 9153/TCP
- ServiceMonitor `coredns` mit `release: kube-prometheus-stack`
- PDB `minAvailable=2`
- DNS Cluster-intern + extern + NodeHosts funktioniert
- Alerts: nur Watchdog
- ArgoCD App `coredns`: Synced/Healthy mit `selfHeal=false`

---

## 5. Block 2 — Detail-Anweisung Phase 11 OS-Update TEST (nach Block 1)

### Voraussetzungen
- PROD CoreDNS HA seit min. 24h stabil
- TEST-Cluster gesund (alle Apps Synced/Healthy)

### Verbesserte Playbook-Tasks (aus DEV-Vorfall hervorgegangen)
- `tasks/pre_drain_prep.yml` — CNPG nodeMaintenanceWindow, Longhorn drain-policy, MariaDB Galera PDB temporaer
- `tasks/post_drain_cleanup.yml` — Reset aller Maintenance-Modes nach Verify
- Drain-Timeout 900s, korrigierte Jinja-Filter, kubectl-Plugin-Flag-Reihenfolge

### Vollstaendige Anleitung
Siehe **`docs/phases/phase-11-rolling-os-update-dev.md`** — dieses Dokument enthaelt:
- Alle Playbook-Verbesserungen aus DEV
- Lessons Learned (Zot-SPOF + CoreDNS-SPOF) — beide jetzt durch Phase 12 + 12b geloest
- Verify-Strategie

### Was anders ist gegenueber DEV
- Mehr Apps in TEST/PROD (alle Pilot-Apps deployed)
- Im Gegensatz zu DEV: PROD-Update kommt mit ggf. neuem Kernel (DEV hatte nur Userspace-Pakete)
- TEST und PROD haben CoreDNS HA ab dem Update (nicht mehr SPOF wie damals DEV)

### Sequentieller Ablauf
1. TEST komplett durchlaufen (3 Nodes nacheinander), 24h Burn-in
2. Dann PROD analog
3. **Niemals beide parallel** — wie immer

---

## 6. Block 4 — Detail-Anweisung Phase 9a Etappe B (nach Block 2/3)

### Voraussetzungen
- TEST + PROD OS-Update durch
- DEV-Zot stabil seit Wochen (ist es)
- NAS10-Bucket `k8s-prod-registry` und DNS `registry-prod.eneg.de` schon vorhanden (✅)
- PROD muss vor Cutover **alle produktiven Images** im PROD-Zot haben (Warm-up wegen OnDemand-First-Pull-Latency 6m+)

### Vollstaendige Anleitung
Siehe **`docs/guides/phase-09a-test-prod-handoff.md`**

### Schritte (Kurzfassung)
1. PROD-Zot deployen (analog DEV-Zot, aber MIT Sync-Konfiguration zu DEV-Zot)
2. Sync DEV→PROD mit Denylist-Filter (latest, main, dev, rc*, alpha*, beta*) starten und abwarten
3. Warm-up: alle aktiv genutzten Images in PROD-Zot pre-syncen
4. containerd registries.yaml auf PROD-Nodes umstellen — **ohne** Internet-Fallback
5. Verifikation: alle Pods koennen Images pullen, keine Fehler

### Bonus
Mit Etappe B ist gleichzeitig **Zot HA in PROD** abgeschlossen (3 Replicas + Anti-Affinity, analog DEV-Phase 12 Plan A).

---

## 7. Initial-Prompt fuer neuen Chat

Folgender Text kann **direkt** in einen neuen Chat kopiert werden:

```
Wir setzen das eNeG K8s Infrastructure v2 Projekt fort.

KONTEXT:
- Aktueller Stand: Roadmap-Handoff vom 06.05.2026
- Roadmap-Doku: docs/phases/roadmap-handoff-2026-05-06.md (im Repository)
- Projektplanung: K8s-GitOps-Infrastruktur-Projektplanung_v2.20.md
- Alle 3 Cluster (DEV/TEST/PROD) gesund, nur Watchdog-Alerts
- Stand 06.05.2026 nachmittag: Thanos Compactor PVC Resize TEST+PROD abgeschlossen, dokumentiert.

ALS ERSTES BITTE TUN:
1. Lies das Roadmap-Handoff-Dokument: docs/phases/roadmap-handoff-2026-05-06.md
2. Pruefe per Kubernetes MCP den aktuellen Status aller 3 Cluster
   (Nodes, ArgoCD-Apps, aktive Alerts ohne Watchdog).
3. Bestimme welcher Block ansteht:
   - Falls TEST CoreDNS HA seit min. 24h stabil → Block 1: PROD CoreDNS HA
   - Falls Block 1 fertig + 24h verifiziert → Block 2: TEST OS-Update
   - Falls Block 2 fertig → Block 3: PROD OS-Update
   - Falls Block 3 fertig → Block 4: Phase 9a Etappe B
   - Falls Block 4 fertig → Block 5: CrowdSec/Falco

DANACH:
- Mit dem entsprechenden Block-Detail aus dem Roadmap-Doc starten.
- Workflow-Regel beachten: sequenziell DEV → TEST → PROD, niemals parallel.
- Ich (Daniel) fuehre Git-Commits/Pushes und SSH-Befehle selbst aus, du gibst Anweisungen.

WICHTIGE BEZUGSDOKUMENTE:
- docs/phases/phase-12b-coredns-test-prod-handoff.md (CoreDNS HA PROD-Plan)
- docs/phases/phase-11-rolling-os-update-dev.md (OS-Update Lessons)
- docs/guides/phase-09a-test-prod-handoff.md (Phase 9a Etappe B)
- docs/runbooks/longhorn-volume-expansion-deadlock.md (Volume-Expansion-Deadlock-Workaround)
- docs/phases/monitoring-thanos-pvc-resize-test-prod.md (Thanos PVC-Fix vom 06.05.)

ZIEL DIESES NEUEN CHATS:
Nimm den naechsten Block aus der Roadmap und fuehre ihn durch. Erstelle am Ende
ein Abschluss-Dokument fuer den jeweiligen Block (analog zu phase-12b-test-completed.md
oder monitoring-thanos-pvc-resize-test-prod.md).
```

---

## 8. Wichtige Memories (Stand 06.05.2026)

Aktive Memory-Eintraege relevant fuer kommende Blocks:

- **Workflow-Reihenfolge:** Sequenziell DEV → TEST → PROD, niemals parallel
- **Longhorn-Expansion-Deadlock Workaround** (ggf. wieder noetig bei Block 4 PROD-Zot wenn PVCs wachsen)
- **Phase 12b CoreDNS HA TEST DONE 06.05.2026 mit 5min DNS-Outage** — PROD-Lessons sind im Handoff eingearbeitet
- **CNPG Barman Cloud Plugin** — `backups.postgresql.cnpg.io` (nicht short form)
- **Trivy Mirror Fix in DEV (22.04.2026)** — wenn Trivy auf TEST/PROD ausgerollt wird, gleiche `configFile` Struktur uebernehmen mit env-spezifischen Zot-Endpunkten

---

## 8b. Backlog-Detail #10 — ArgoCD Self-Management via Helm-Chart

**Hintergrund:** ArgoCD wurde via raw Manifests (`install.yaml`) installiert. Daraus folgen mehrere Patches die NICHT GitOps-managed sind, sondern manuell appliziert werden muessen:

- `kubernetes/base/argocd/argocd-repo-server-ksops-patch.yaml` (KSOPS Init-Container)
- `kubernetes/base/argocd/argocd-imagepullpolicy-patch.yaml` (imagePullPolicy IfNotPresent — neu 08.05.2026)
- ggf. spaeter weitere

**Re-Apply-Aufwand bei jedem ArgoCD-Versions-Upgrade:** beide Patch-Skripte pro Cluster ausfuehren (ksops manuell + `apply-argocd-imagepullpolicy.sh`).

**Vorschlag:** Migration auf das offizielle `argo-cd` Helm-Chart (`argo/argo-cd`):
- ArgoCD wuerde sich selbst syncen (Self-Management Pattern)
- KSOPS-Init-Container und imagePullPolicy als Helm-Values pflegen, statt als out-of-band Patch
- Versions-Upgrade waere reine `targetRevision`-Anpassung in der ArgoCD-App

**Vorbedingungen / offene Punkte:**
- ksops-Patch ist non-trivial — bestehende Volumes/Mounts sauber in Helm-Values uebersetzen
- Migration muss ohne Downtime moeglich sein (DEV → TEST → PROD wie immer)
- Bestehende `argocd-cm` Aenderungen via ArgoCD-Helm-Values `configs.cm.*` uebernehmen
- `argocd-cmd-params-cm` wird in argocd-Charts ebenfalls behandelt
- Self-Management-Bootstrap: Cluster-Admin muss ggf. einmalig manuell ueber `helm install`, danach uebernimmt ArgoCD sich selbst

**Risiko:** mittel — keine eilige Aenderung, sinnvoll vor naechstem ArgoCD-Major-Upgrade (>v3.4) als Vorbereitung.

**Doku-Referenz:** wird bei Umsetzung als eigene Phase im Repo angelegt.

---

## 9. Repository-Snapshot

```
docs/
├── K8s-GitOps-Infrastruktur-Projektplanung_v2.20.md   # Master-Plan
├── phases/
│   ├── roadmap-handoff-2026-05-06.md                  # DIESES DOKUMENT
│   ├── imagepullpolicy-cleanup-2026-05-08.md          # NEU 08.05. (Mini-Block)
│   ├── monitoring-thanos-pvc-resize-test-prod.md      # NEU 06.05.
│   ├── phase-12-ha-improvements-completed.md          # DEV done 06.05.
│   ├── phase-12b-coredns-test-prod-handoff.md         # PROD-Plan, 24h Burn-in laeuft
│   ├── phase-12b-test-completed.md                    # TEST done 06.05.
│   ├── phase-11-rolling-os-update-dev.md              # DEV done 30.04.
│   ├── phase-10-backup-dev.md                         # done 14.04.
│   ├── phase-09-security-dev.md                       # Kyverno+Trivy DEV done
│   ├── phase-09a-security-registries.md               # Etappe A done all envs
│   └── phase-08e-branch-migration-handoff.md          # offen
├── runbooks/
│   └── longhorn-volume-expansion-deadlock.md          # NEU 06.05. (erster Eintrag)
├── guides/
│   ├── phase-09a-test-prod-handoff.md                 # Etappe B Anleitung
│   ├── cnpg-barman-cloud-plugin-migration-v2.md
│   ├── pg-minor-upgrade-17.9-image-switch.md
│   └── ...
└── decisions/
    ├── ADR-001-kustomize-overlay-pattern.md
    └── ADR-002-branch-per-environment.md
```

---

*Dieses Dokument bleibt gueltig bis Block 1 abgeschlossen ist. Nach Abschluss eines Blocks bitte
den Status hier aktualisieren oder ein neues Roadmap-Handoff fuer den dann aktuellen Stand erstellen.*
