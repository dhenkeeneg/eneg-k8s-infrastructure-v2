# Phase 12 — HA-Improvements (DEV) — Completed

**Status:** ✅ Abgeschlossen 06.05.2026
**Environment:** DEV (VLAN 180, k8s-dev-21/22/23)
**Vorgaenger:** [phase-12-ha-improvements-handoff.md](phase-12-ha-improvements-handoff.md)
**Nachfolger (TEST/PROD):** [phase-12b-coredns-test-prod-handoff.md](phase-12b-coredns-test-prod-handoff.md)

## Ziel
Eliminierung der zwei verbliebenen SPOFs aus dem Phase-11-OS-Update-Vorfall:
- **Plan A** — Zot Container-Registry: Single-Replica → 3 Replicas mit Anti-Affinity
- **Plan B** — CoreDNS: K3s-Default Single-Replica → eigenes Helm-Chart mit 3 Replicas, Anti-Affinity, PDB

## Ergebnis

### Plan A — Zot HA
- StatefulSet `registry-zot`: 1 → 3 Replicas
- PVCs: 1x10Gi → 3x10Gi Longhorn (+20 GB)
- Pod-Verteilung 1+1+1 (-21/-22/-23)
- ArgoCD App `registry`: Synced/Healthy

### Plan B — CoreDNS HA
- Helm-Chart `coredns/coredns` v1.45.2 (Replacement fuer K3s-Auto-Deploy)
- 3 Replicas, ServiceAccount `coredns` (dediziert), PDB minAvailable=2
- Service `kube-dns` @ 10.43.0.10 (uebernommen vom K3s-Default)
- Service `coredns-metrics` @ 9153/TCP fuer Prometheus
- ServiceMonitor `coredns` @ monitoring (release: kube-prometheus-stack)
- ConfigMap mit komplettem Corefile inkl. NodeHosts inline (DEV-Cluster-IPs)
- ArgoCD App `coredns`: selfHeal=false (manuelle Kontrolle bei Cluster-DNS)

## Geaenderte Dateien (Plan B)

```
ansible/inventory/dev/group_vars/all.yml          # k3s_disable: + coredns
ansible/playbooks/09-k3s-coredns-disable.yml      # NEU — sequenziell, k3s kubectl Healthcheck
kubernetes/base/coredns/values.yaml               # NEU — Replicas, SA, PDB, Prometheus
kubernetes/environments/dev/coredns/values-override.yaml      # NEU — Corefile + NodeHosts
kubernetes/environments/dev/infrastructure/coredns-app.yaml   # NEU — ArgoCD App, prune=false, selfHeal=false
kubernetes/base/monitoring/kube-prometheus-stack/values.yaml  # Hinweis-Kommentar fuer TEST/PROD
kubernetes/environments/dev/monitoring/values-override.yaml   # coreDns.enabled=false
```

## Verlauf — Was tatsaechlich passiert ist

### Plan A (Zot HA) — straight forward
- Edit values-override → push → ArgoCD auto-sync → 3 Replicas hoch
- Pod-Template-Aenderung loeste Rolling-Update aus → Pod-0 wurde mit-rolliert
- Verteilung 1+1+1, Smoke-Test implizit ueber Pull-Funktionalitaet bestanden

### Plan B (CoreDNS HA) — mit drei nicht-trivialen Lessons
1. **HelmChart-CR-Cleanup unerwartet:** Beim ersten K3s-Restart auf -21 hat K3s nicht nur den Auto-Deploy gestoppt, sondern den HelmChart-CR `coredns` aktiv abgeraeumt — inkl. Service, Deployment, Pods, ConfigMap. Das Doc hatte angenommen, K3s laesst die Resourcen stehen. Folge: ungeplantes DNS-Outage-Fenster im Cluster. **Recovery via direktem `helm template | kubectl apply --server-side` auf k8s-mgmt-10 (Bypass des ArgoCD-DNS-Henne-Ei-Problems), DNS innerhalb ~2 Min wieder verfuegbar.**

2. **`uri /healthz` wirft 401:** Moderne K3s/K8s lehnen anonyme Health-Probe-Requests ab. Im Doc-Snippet stand `ansible.builtin.uri` mit `https://localhost:6443/healthz` — wirft 401 (Authn aktiviert). Loesung: `ansible.builtin.command: k3s kubectl get --raw=/healthz` — nutzt das interne kubeconfig.

3. **Falscher Helm-Chart-Key:** Die initiale `base/coredns/values.yaml` verwendete `serviceMonitor.enabled: true`. Der Helm-Chart kennt diesen Key nicht und ignoriert ihn still — kein Fehler, kein Warning. Korrekter Key: `prometheus.monitor.enabled: true`. Folge: kein ServiceMonitor wurde erstellt. Detected via `helm template | grep kind:`.

4. **RollingUpdate-Verteilung:** Beim Sync der ServiceAccount-Aenderung produzierte der RollingUpdate eine 1+2+0-Pod-Verteilung statt 1+1+1, weil `topologySpreadConstraints.whenUnsatisfiable: ScheduleAnyway` (soft) gewaehlt war. Korrektur: einen Pod auf der ueberlasteten Node manuell geloescht — Anti-Affinity hat den neuen Pod auf die freie Node gescheduled.

### Adoption (`kubectl apply` → ArgoCD)
- Erster ArgoCD-Sync nach manuellem `kubectl apply` brauchte `ServerSideApply=true` + `Force=true`, weil Field-Ownership beim `kubectl-client-side-apply` Field-Manager lag.
- ArgoCD hat alle 6 Resourcen sauber adoptiert — `argocd-controller` ist jetzt Co-Owner neben `kubectl`.

## Verifikation (06.05.2026 ~05:00 UTC)

| Check | Soll | Ist | Status |
|---|---|---|---|
| Nodes Ready | 3/3 | k8s-dev-21/22/23 | ✅ |
| Zot Pods | 3/3 Ready, 1/Node | ✅ | ✅ |
| CoreDNS Pods | 3/3 Ready, 1/Node | ✅ | ✅ |
| CoreDNS ServiceAccount | `coredns` (dediziert) | ✅ | ✅ |
| Service kube-dns | 10.43.0.10, 53/UDP | ✅ | ✅ |
| Service coredns-metrics | 9153/TCP | ✅ | ✅ |
| ServiceMonitor coredns | release-Label | ✅ | ✅ |
| PDB | minAvailable=2 | allowed=1 | ✅ |
| K3s coreDns disabled | alle 3 Nodes | ✅ | ✅ |
| kube-prometheus-stack-coredns | weg (DEV-Override) | ✅ | ✅ |
| DNS Cluster-intern | funktioniert | ✅ | ✅ |
| DNS extern (forward) | funktioniert | ✅ | ✅ |
| DNS NodeHosts | funktioniert | ✅ | ✅ |
| Active Alerts | nur Watchdog | ✅ | ✅ |
| ArgoCD Apps Status | Synced/Healthy | 60/60 | ✅ |

## Lessons Learned fuer TEST/PROD

1. **Direktes `helm template | kubectl apply` auf k8s-mgmt-10 vorhalten** als geplanter Cutover-Schritt — nicht als Notfall-Recovery. Vermeidet ArgoCD-DNS-Henne-Ei.
2. **Health-Check-Task gefixt** im Playbook (k3s kubectl).
3. **Helm-Chart-Werte verifiziert** durch `helm template | grep kind:` BEVOR pushen.
4. **kube-prometheus-stack-coredns Override** als fester Bestandteil im Cutover-Schritt (nicht als Nachgang).
5. **Pod-Verteilung explizit pruefen** und ggf. einen Pod loeschen-zum-reschedulen, falls 1+2+0.
6. **`selfHeal=false` fuer Cluster-DNS** — wir wollen Drift sehen, aber nicht blind reconcilen.
