# Phase 12b — CoreDNS HA Rollout TEST + PROD — Handoff

**Status:** 🟢 TEST abgeschlossen 06.05.2026 / 🟡 PROD offen (24h Burn-in läuft)
**Voraussetzungen erfuellt:** DEV abgeschlossen 06.05.2026, dokumentiert, stabil
**Owner:** Daniel Henke
**Erstellt:** 06.05.2026
**TEST-Rollout:** 06.05.2026 (Cutover mit DNS-Outage von ~5min, Recovery vorwärts; siehe phase-12b-test-completed.md)
**Dokument-Update:** 06.05.2026 nach TEST-Rollout — DEV-Lessons + TEST-Lessons eingearbeitet

## Zweck dieses Dokuments
Anleitung fuer den Rollout der **Phase 12 Plan B** (CoreDNS HA via eigenem
Helm-Chart) auf TEST und PROD. Plan A (Zot HA) ist explizit **nicht**
Bestandteil dieses Handoffs — fuer TEST entfaellt es (TEST hat keinen Zot,
sondern pullt aus DEV-Zot via Topologie-Variante 2 / Phase 9a). Fuer PROD
wird Plan A separat in Phase 9a Etappe B betrachtet.

Dieses Dokument ist self-contained — Lessons aus DEV UND TEST sind
eingearbeitet, sodass beide Generationen Stolperfallen vermieden werden.

## Was bereits drin ist (DEV + TEST-Stand auf main)
- `kubernetes/base/coredns/values.yaml` — generisch, ENV-unabhaengig
- `ansible/playbooks/09-k3s-coredns-disable.yml` — fertig + getestet
- `kubernetes/base/monitoring/kube-prometheus-stack/values.yaml` — Hinweis-Kommentar drin
- `kubernetes/environments/dev/coredns/` — DEV-Overlay (Vorlage fuer PROD)
- `kubernetes/environments/dev/infrastructure/coredns-app.yaml` — DEV ArgoCD App (Vorlage)
- `kubernetes/environments/test/coredns/` — TEST-Overlay (zweite Vorlage fuer PROD)
- `kubernetes/environments/test/infrastructure/coredns-app.yaml` — TEST ArgoCD App (zweite Vorlage)

## Was zu tun ist — Reihenfolge fuer PROD

### ⚠️ KRITISCH — Race-Condition mit ArgoCD Auto-Sync vermeiden ⚠️

**TEST-Lesson (06.05.2026):** Die `test-infrastructure` App-of-Apps hat den
Push innerhalb **<60 Sekunden** discovered und die `coredns`-App mit
Auto-Sync gestartet, bevor der `helm template | kubectl apply`-Bypass
ausgefuehrt werden konnte. Der ArgoCD-Sync hat ConfigMap, Service `kube-dns`
und alle RBAC-Resources via ServerSideApply uebernommen, das Deployment
scheiterte (immutable Selector), und der Service hatte einen Selector der
nicht zum laufenden K3s-Default-CoreDNS-Pod passte → DNS-Outage von ~5 min
bis manuell repariert.

**Fuer PROD daher zwingend:** Die `coredns`-App **mit `automated: null`
erstellen** (kein Auto-Sync). Erst nach erfolgreichem Cutover Auto-Sync
aktivieren.

### Schritt 0: Voraussetzungen pruefen
- DEV laeuft seit min. 24h ohne CoreDNS- oder DNS-bezogene Alerts
- TEST laeuft seit min. 24h ohne CoreDNS- oder DNS-bezogene Alerts
- PROD-Cluster ist gesund (alle Nodes Ready, alle ArgoCD Apps Synced/Healthy)
- Zot in PROD (PROD-Zot in Phase 9a Etappe B) hat
  `rancher/mirrored-coredns-coredns:1.14.1` im Cache; bei Topologie-Variante-2
  vor Etappe-B-Cutover: PROD pullt noch ueber DEV-Zot, ebenfalls Cache pruefen
  (Sicherheitscheck — auf jeder Node `sudo k3s ctr images pull docker.io/rancher/mirrored-coredns-coredns:1.14.1`)

### Schritt 1: Repo-Aenderungen fuer PROD
Pro Env werden je 4 Files erstellt/geaendert. Vorlage ist DEV oder TEST.

**Fuer PROD** (Cluster-IPs anpassen!):
1. `ansible/inventory/prod/group_vars/all.yml` — `k3s_disable: + coredns` ergaenzen
2. `kubernetes/environments/prod/coredns/values-override.yaml` — Corefile mit
   PROD-Node-IPs in inline hosts-Plugin:
   ```yaml
   - name: hosts
     configBlock: |-
       192.168.178.21 k8s-prod-21
       192.168.178.22 k8s-prod-22
       192.168.178.23 k8s-prod-23
       ttl 60
       reload 15s
       fallthrough
   ```
3. `kubernetes/environments/prod/infrastructure/coredns-app.yaml` —
   Pfade auf `environments/prod/...` anpassen, Rest 1:1 von DEV/TEST,
   **WICHTIG:** `syncPolicy.automated:` muss **leer** oder **fehlen** (kein
   Auto-Sync, sonst Race-Condition wie in TEST):
   ```yaml
   syncPolicy:
     # KEIN automated:! Wird erst nach erfolgreichem Cutover aktiviert.
     syncOptions:
       - ServerSideApply=true
   ```
4. `kubernetes/environments/prod/monitoring/values-override.yaml` —
   `coreDns.enabled: false` hinzufuegen (Top-Level)

### Schritt 2: PROD commit + push, dann Cutover

**Reihenfolge auf k8s-mgmt-10 (sequenziell, NICHT parallel):**

```bash
cd ~/git/eneg-k8s-infrastructure-v2
git pull origin main

# === Sanity-Check 1: Helm-Repo registriert ===
helm repo add coredns https://coredns.github.io/helm 2>/dev/null
helm repo update coredns

# === Sanity-Check 2: Manifest generieren + reviewen ===
helm template coredns coredns/coredns \
  --version 1.45.2 \
  --namespace kube-system \
  -f kubernetes/base/coredns/values.yaml \
  -f kubernetes/environments/prod/coredns/values-override.yaml \
  > /tmp/coredns-prod.yaml

# Resourcen-Inventar (8 Stueck inkl. 2× Service)
grep -E "^kind:" /tmp/coredns-prod.yaml | sort | uniq -c
# Erwartung: ConfigMap, ClusterRole, ClusterRoleBinding, Deployment,
#            PodDisruptionBudget, 2× Service, ServiceAccount, ServiceMonitor

# ClusterIP MUSS 10.43.0.10 sein
grep "clusterIP: 10.43.0.10" /tmp/coredns-prod.yaml

# replicaCount: 3
grep "replicas: 3" /tmp/coredns-prod.yaml

# Image im Cache
grep "rancher/mirrored-coredns-coredns:1.14.1" /tmp/coredns-prod.yaml

# Hosts-Plugin mit PROD-IPs
grep "192.168.178.2" /tmp/coredns-prod.yaml

# === Image-Pre-Warming (Sicherheits-Check) ===
for node in k8s-prod-21 k8s-prod-22 k8s-prod-23; do
  echo "=== $node ==="
  ssh $node 'sudo k3s ctr images pull docker.io/rancher/mirrored-coredns-coredns:1.14.1'
done

# === Cutover Phase 1: Apply BEVOR Playbook ===
# (DEV+TEST-Lesson: ArgoCD-App hat KEIN Auto-Sync, daher kein Race.
#  Wir sind in Kontrolle der Reihenfolge.)
# Altes Deployment loeschen (Object sofort weg, Pods cascading im Background)
kubectl --context k8s-prod -n kube-system delete deployment coredns \
  --cascade=background --wait=false

# Manifest applyen (force-conflicts uebernimmt Wrangler/K3s-Ownership)
kubectl --context k8s-prod apply --server-side --force-conflicts -f /tmp/coredns-prod.yaml

# Auf 3 Pods Ready warten (max 120s)
kubectl --context k8s-prod -n kube-system rollout status deployment coredns --timeout=120s

# Pod-Verteilung (Erwartung: 1+1+1 auf -21/-22/-23)
kubectl --context k8s-prod -n kube-system get pods -l app.kubernetes.io/name=coredns -o wide
# Falls 1+2+0 oder 2+1+0 → einen Pod auf der ueberbesetzten Node loeschen

# DNS-Test (sollte sofort ok sein)
kubectl --context k8s-prod -n argocd exec deploy/argocd-repo-server -c argocd-repo-server -- \
  sh -c "getent hosts kubernetes.default.svc.cluster.local"

# === Cutover Phase 2: Wrangler-Annotations strippen ===
# (TEST-Lesson: Wrangler-Annotations ueberleben --force-conflicts! Wenn
#  nicht entfernt, raeumt Wrangler beim K3s-Restart die Resources ab → Outage.)
for spec in \
  "service kube-dns" \
  "configmap coredns" \
  "serviceaccount coredns"; do
  set -- $spec
  kubectl --context k8s-prod -n kube-system annotate "$1" "$2" \
    objectset.rio.cattle.io/applied- \
    objectset.rio.cattle.io/id- \
    objectset.rio.cattle.io/owner-gvk- \
    objectset.rio.cattle.io/owner-name- \
    objectset.rio.cattle.io/owner-namespace- 2>&1
  kubectl --context k8s-prod -n kube-system label "$1" "$2" \
    objectset.rio.cattle.io/hash- 2>&1
done

# Verify: Service kube-dns hat keine objectset-Annotations mehr
kubectl --context k8s-prod -n kube-system get svc kube-dns -o yaml \
  | grep -E "objectset" \
  || echo "✅ keine objectset-Annotations/Labels mehr"

# === Cutover Phase 3: Addon-CR direkt loeschen ===
# (TEST-Lesson: Addon-CR direktes Delete OHNE DNS-Outage moeglich, weil
#  objectset jetzt leer ist.)
kubectl --context k8s-prod -n kube-system delete addon.k3s.cattle.io coredns

# DNS-Test (sollte weiter ok bleiben)
kubectl --context k8s-prod -n argocd exec deploy/argocd-repo-server -c argocd-repo-server -- \
  sh -c "getent hosts kubernetes.default.svc.cluster.local"

# === Cutover Phase 4: Persistente K3s-Config via Playbook ===
ansible-playbook -i ansible/inventory/prod ansible/playbooks/09-k3s-coredns-disable.yml
# Sequenziell -21, -22, -23, je ~90s pro Node, total ~4-5 min
# Pods bleiben unangetastet (RESTARTS=0), DNS bleibt durchgehend verfuegbar
# (anders als die DEV-Lesson! In DEV+TEST haben wir verifiziert: K3s-Restart
# touched die laufenden Pods nicht.)
```

### Schritt 3: ArgoCD-Adoption (NACH erfolgreichem Cutover)
```bash
# Refresh erzwingen
kubectl --context k8s-prod -n argocd patch application coredns \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Manueller Sync mit Force fuer Field-Ownership-Uebernahme
kubectl --context k8s-prod -n argocd patch application coredns \
  --type merge -p '{"operation":{"sync":{"syncOptions":["ServerSideApply=true","Force=true"]}}}'

# Auf Synced/Healthy warten
for i in $(seq 1 30); do
  STATE=$(kubectl --context k8s-prod -n argocd get application coredns \
    -o jsonpath='{.status.operationState.phase}')
  SYNC=$(kubectl --context k8s-prod -n argocd get application coredns \
    -o jsonpath='{.status.sync.status}')
  echo "[$i] phase=$STATE  sync=$SYNC"
  [ "$STATE" = "Succeeded" ] && [ "$SYNC" = "Synced" ] && break
  sleep 2
done

# Auto-Sync JETZT aktivieren (prune:false, selfHeal:false — defensive bei DNS)
kubectl --context k8s-prod -n argocd patch application coredns \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":false}}}}'

# Verifikation
kubectl --context k8s-prod -n argocd get application coredns \
  -o jsonpath='{"sync="}{.status.sync.status}{"  health="}{.status.health.status}{"\n"}'
```

### Schritt 4: kube-prometheus-stack-coredns Cleanup
**TEST-Lesson:** Der monitoring-App-Sync **kann** im PreSync-Hook hängen
(`kube-prometheus-stack-admission-create` Job-TTL-Issue). Workaround
einbauen, nicht abwarten.

```bash
# Hard refresh
kubectl --context k8s-prod -n argocd patch application monitoring \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Manueller Sync mit Prune
kubectl --context k8s-prod -n argocd patch application monitoring \
  --type merge -p '{"operation":{"sync":{"prune":true,"syncOptions":["ServerSideApply=true"]}}}'

# 60s warten, dann Status pruefen
sleep 60
kubectl --context k8s-prod -n argocd get application monitoring \
  -o jsonpath='{"sync="}{.status.sync.status}{"  phase="}{.status.operationState.phase}{"\n"}'

# Falls phase=Running mit message "waiting for completion of hook" haengt
# → Manueller Workaround:
kubectl --context k8s-prod -n kube-system delete svc kube-prometheus-stack-coredns --ignore-not-found
kubectl --context k8s-prod -n monitoring delete servicemonitor kube-prometheus-stack-coredns --ignore-not-found
kubectl --context k8s-prod -n monitoring delete configmap kube-prometheus-stack-k8s-coredns --ignore-not-found
kubectl --context k8s-prod -n argocd patch application monitoring --type merge -p '{"operation":null}'
kubectl --context k8s-prod -n argocd patch application monitoring \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Schritt 5: End-to-End-Verify
```bash
# DNS-Test aus existierendem Pod
kubectl --context k8s-prod -n argocd exec deploy/argocd-repo-server -c argocd-repo-server -- \
  sh -c "getent hosts kubernetes.default.svc.cluster.local; \
         getent hosts argocd-repo-server.argocd.svc.cluster.local; \
         getent hosts github.com; \
         getent hosts k8s-prod-21"
```
Erwartung: alle 4 Lookups liefern Adressen.

```bash
# Globaler ArgoCD-Status (sollten alle Apps Synced/Healthy sein)
kubectl --context k8s-prod -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  | grep -vE "Synced *Healthy"
# Erwartung: nur Header (alles gruen)

# K3s-Config persistent?
for node in k8s-prod-21 k8s-prod-22 k8s-prod-23; do
  ssh $node "sudo grep -A6 '^disable:' /etc/rancher/k3s/config.yaml"
done

# Addon-CR coredns weg und bleibt weg?
kubectl --context k8s-prod -n kube-system get addon.k3s.cattle.io coredns 2>&1
# Erwartung: NotFound
```

**Burn-in:** mindestens 24h beobachten, dann erst nach naechstem Schritt.

## Bekannte Stolperfallen (vermeiden!)

1. **NICHT** das Doc-Originalsnippet `ansible.builtin.uri /healthz` verwenden — wirft 401 (DEV-Lesson)
2. **NICHT** `serviceMonitor.enabled: true` als Helm-Wert versuchen — falscher Key, korrekter ist `prometheus.monitor.enabled: true`
3. **NICHT** `coreDns.enabled: false` in `base/monitoring/kube-prometheus-stack/values.yaml` — TEST/PROD-spezifisch, nur in env-Override!
4. **NICHT** auf K3s-API von Aussen `/healthz` probieren — Auth required
5. **NICHT** das Playbook ohne lokales `git pull` auf k8s-mgmt-10 starten — alte Version laeuft sonst durch
6. **NICHT** ArgoCD-Sync allein vertrauen — explizit Force-Sync ausloesen fuer Field-Ownership-Adoption
7. **NICHT** vergessen: nach SA-Aenderung muss Pod-Verteilung manuell kontrolliert werden
8. **NICHT** ArgoCD-App mit `automated:` erstellen — TEST-Lesson: Race-Condition mit Auto-Sync (App-of-Apps discovered <60s) verursacht DNS-Outage. App ohne `automated:` deployen, erst nach Cutover aktivieren.
9. **NICHT** vergessen: Wrangler-Annotations VOR dem Playbook strippen + Addon-CR direkt loeschen — `--force-conflicts` uebernimmt nicht die K3s-objectset-Annotations, Wrangler raeumt sonst beim K3s-Restart die Resources ab.
10. **NICHT** `kubectl patch --type=merge` auf eine Map-Property als Replace nutzen — das ist Field-Merge, nicht Replace. Verwende `--type=json` mit `op:replace`.
11. **NICHT** ueberraschen lassen vom kube-prometheus-stack PreSync-Hook-Hang — Job hat ttl, ArgoCD-Hook-Tracker veraltet → manueller Workaround (Resources direkt deleten + operation cancel + refresh).

## Anhang: Plan A (Zot HA) Rollout PROD
Aktuell in DEV ausgerollt. Fuer PROD gehoert es in Phase 9a Etappe B (PROD-Zot).
Bei Phase 9a Etappe B in PROD wird der Zot direkt mit `replicaCount: 3` +
Anti-Affinity ausgerollt (kombinierter Schritt — keine separate Phase 12).
