# Phase 12b — CoreDNS HA Rollout TEST + PROD — Handoff

**Status:** 🟡 Bereit fuer Rollout
**Voraussetzungen erfuellt:** DEV abgeschlossen, dokumentiert, stabil seit 06.05.2026
**Owner:** Daniel Henke
**Erstellt:** 06.05.2026

## Zweck dieses Dokuments
Anleitung fuer den Rollout der **Phase 12 Plan B** (CoreDNS HA via eigenem
Helm-Chart) auf TEST und PROD. Plan A (Zot HA) ist explizit **nicht**
Bestandteil dieses Handoffs — fuer TEST/PROD waere ein separater Schritt
noetig (siehe Anhang).

Dieses Dokument ist self-contained — Lessons aus DEV sind eingearbeitet,
sodass die DEV-Stolperfallen vermieden werden.

## Was bereits drin ist (DEV-Stand auf main)
- `kubernetes/base/coredns/values.yaml` — generisch, ENV-unabhaengig
- `ansible/playbooks/09-k3s-coredns-disable.yml` — fertig + getestet
- `kubernetes/base/monitoring/kube-prometheus-stack/values.yaml` — Hinweis-Kommentar drin
- `kubernetes/environments/dev/coredns/` — DEV-Overlay (Vorlage fuer TEST/PROD)
- `kubernetes/environments/dev/infrastructure/coredns-app.yaml` — DEV ArgoCD App (Vorlage)

## Was zu tun ist — Reihenfolge TEST → PROD

### Schritt 0: Voraussetzungen pruefen
- DEV laeuft seit min. 24h ohne CoreDNS- oder DNS-bezogene Alerts
- TEST/PROD-Cluster sind gesund (alle Nodes Ready, alle ArgoCD Apps Synced/Healthy)
- Zot-Mirror in TEST/PROD hat `rancher/mirrored-coredns-coredns:1.14.1` im Cache
  (Sicherheitscheck — auf jeder Node `sudo k3s ctr images pull docker.io/rancher/mirrored-coredns-coredns:1.14.1`)

### Schritt 1: Repo-Aenderungen pro Environment
Pro Env (TEST und PROD) werden je 4 Files erstellt/geaendert. Vorlage ist DEV.

**Fuer TEST** (Cluster-IPs anpassen!):
1. `ansible/inventory/test/group_vars/all.yml` — `k3s_disable: + coredns` ergaenzen
2. `kubernetes/environments/test/coredns/values-override.yaml` — Corefile mit
   TEST-Node-IPs in inline hosts-Plugin:
   ```yaml
   - name: hosts
     configBlock: |-
       192.168.179.21 k8s-test-21
       192.168.179.22 k8s-test-22
       192.168.179.23 k8s-test-23
       ttl 60
       reload 15s
       fallthrough
   ```
3. `kubernetes/environments/test/infrastructure/coredns-app.yaml` —
   Pfade auf `environments/test/...` anpassen, Rest 1:1 von DEV
4. `kubernetes/environments/test/monitoring/values-override.yaml` —
   `coreDns.enabled: false` hinzufuegen (Top-Level)

**Fuer PROD analog** mit IPs `192.168.178.21-23` und `k8s-prod-*` Hostnames.

### Schritt 2: TEST commit + push, dann Cutover

**Nicht direkt ueber ArgoCD!** Aus den DEV-Lehren:
- ArgoCD braucht DNS um Helm-Chart zu pullen → Henne-Ei wenn DNS gerade weg
- Daher Cutover **direkt auf k8s-mgmt-10**

**Reihenfolge auf k8s-mgmt-10:**

```bash
cd ~/git/eneg-k8s-infrastructure-v2
git pull origin main

# Sanity-Check vor jeder Aktion:
helm template coredns coredns/coredns \
  --version 1.45.2 \
  --namespace kube-system \
  -f kubernetes/base/coredns/values.yaml \
  -f kubernetes/environments/test/coredns/values-override.yaml \
  | grep -E "^kind:|^---|name: coredns"
# Erwartung: 9 Resourcen (PDB, ServiceAccount, ConfigMap, ClusterRole,
# ClusterRoleBinding, Service kube-dns, Service coredns-metrics, Deployment, ServiceMonitor)

# Image-Pre-Warming (Sicherheits-Check)
for node in k8s-test-21 k8s-test-22 k8s-test-23; do
  echo "=== $node ==="
  ssh $node 'sudo k3s ctr images pull docker.io/rancher/mirrored-coredns-coredns:1.14.1'
done

# Ansible-Playbook (TEST-Inventory)
ansible-playbook -i ansible/inventory/test ansible/playbooks/09-k3s-coredns-disable.yml
# Wird sequenziell -21, -22, -23 durchgehen, je ~2 Min

# CRITICAL: K3s wird beim Restart von -21 den HelmChart-CR cleanup'en
#           → DNS-Outage von ~30-90s
# Sofort danach (laeuft ggf. parallel zur Playbook-Stabilisierung):
helm template coredns coredns/coredns \
  --version 1.45.2 \
  --namespace kube-system \
  --kube-context k8s-test \
  -f kubernetes/base/coredns/values.yaml \
  -f kubernetes/environments/test/coredns/values-override.yaml \
  | kubectl --context k8s-test apply --server-side --force-conflicts -f -

# Auf alle 3 Pods Ready warten
kubectl --context k8s-test -n kube-system rollout status deployment/coredns --timeout=120s
```

**Idealer Ablauf:**
1. Playbook startet auf -21, Config geaendert, K3s neu gestartet
2. Innerhalb <60s nach Playbook-Start auf -21 das `helm template | kubectl apply` ausfuehren
3. K3s loescht den HelmChart-CR, neue Resourcen werden gleichzeitig per SSA created
4. Playbook geht weiter zu -22, -23 — die finden bereits den neuen `kube-dns` Service vor und beruehren ihn nicht (`disable: coredns`)

**Wenn DNS tatsaechlich >2 Min wackelt:** ArgoCD-Apps werden Sync-Fehler zeigen, aber sich von selbst erholen sobald `kube-dns` verfuegbar ist.

### Schritt 3: ArgoCD-Adoption
```bash
# Refresh erzwingen
kubectl --context k8s-test -n argocd patch application coredns \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Sync mit Force fuer Field-Ownership-Uebernahme
kubectl --context k8s-test -n argocd patch application coredns \
  --type merge -p '{"operation":{"sync":{"syncOptions":["ServerSideApply=true","Force=true"]}}}'

# Verifikation
kubectl --context k8s-test -n argocd get application coredns \
  -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}'
# Erwartung: "Synced / Healthy"
```

**Achtung Pod-Verteilung:** Die SA-Aenderung loest Rolling-Update aus. Nach
Sync pruefen:
```bash
kubectl --context k8s-test -n kube-system get pods -l app.kubernetes.io/name=coredns -o wide
```
Falls 1+2+0 oder 2+1+0 → einen Pod auf der ueberbesetzten Node loeschen,
Anti-Affinity wird ihn auf die freie Node reschedulen.

### Schritt 4: kube-prometheus-stack-coredns Cleanup
Tritt automatisch ein, sobald `kubernetes/environments/test/monitoring/values-override.yaml`
mit `coreDns.enabled: false` gepusht und `monitoring`-App synced ist:
```bash
kubectl --context k8s-test -n argocd patch application monitoring \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Pruefen dass weg:
kubectl --context k8s-test -n kube-system get svc kube-prometheus-stack-coredns --ignore-not-found
kubectl --context k8s-test -n monitoring get servicemonitor kube-prometheus-stack-coredns --ignore-not-found
```

### Schritt 5: End-to-End-Verify
```bash
# DNS-Test aus existierendem Pod
kubectl --context k8s-test -n argocd exec deploy/argocd-repo-server -- \
  sh -c "getent hosts kubernetes.default.svc.cluster.local; \
         getent hosts argocd-repo-server.argocd.svc.cluster.local; \
         getent hosts github.com; \
         getent hosts k8s-test-21"
```
Erwartung: alle 4 Lookups liefern Adressen.

**Burn-in:** mindestens 24h beobachten, dann analog auf PROD.

### Schritt 6: PROD-Rollout
Identisch zu TEST, aber:
- Cluster-Context: `k8s-prod`
- IPs: `192.168.178.21-23`, Hostnames `k8s-prod-*`
- Inventory: `ansible/inventory/prod`
- Verstaerkte Verifikation pre-cutover (PROD ist live)

## Bekannte Stolperfallen (vermeiden!)

1. **NICHT** das Doc-Originalsnippet `ansible.builtin.uri /healthz` verwenden — wirft 401
2. **NICHT** `serviceMonitor.enabled: true` als Helm-Wert versuchen — falscher Key, korrekter ist `prometheus.monitor.enabled: true`
3. **NICHT** `coreDns.enabled: false` in `base/monitoring/kube-prometheus-stack/values.yaml` — TEST/PROD-spezifisch, nur in env-Override!
4. **NICHT** auf K3s-API von Aussen `/healthz` probieren — Auth required
5. **NICHT** das Playbook ohne lokales `git pull` auf k8s-mgmt-10 starten — alte Version laeuft sonst durch
6. **NICHT** ArgoCD-Sync allein vertrauen — explizit Force-Sync ausloesen fuer Field-Ownership-Adoption
7. **NICHT** vergessen: nach SA-Aenderung muss Pod-Verteilung manuell kontrolliert werden

## Anhang: Plan A (Zot HA) Rollout TEST/PROD
Aktuell in DEV ausgerollt. Fuer TEST/PROD analog:
- `kubernetes/environments/test/registry/values-override.yaml` — replicaCount: 3 + Anti-Affinity Block
- Push → ArgoCD auto-sync — keine Spezialitaeten, da S3-Backend (NAS10).
Erwartete Laufzeit pro Env: ~10 Min.

**Empfehlung:** Plan A koennte gleichzeitig mit Plan B mitgenommen werden,
da beides voneinander unabhaengig ist und Plan A risikoarm.
