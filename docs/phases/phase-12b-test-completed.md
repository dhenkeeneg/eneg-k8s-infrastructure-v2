# Phase 12b — CoreDNS HA Rollout TEST — Completed

**Datum:** 06.05.2026
**Status:** ✅ ABGESCHLOSSEN
**Owner:** Daniel Henke
**Cluster:** k8s-test-21/22/23 (192.168.179.21-23, K3s v1.35.1+k3s1)
**Voraussetzung:** Phase 12 DEV abgeschlossen 06.05.2026 (siehe `phase-12-ha-improvements-completed.md`)
**Resultat:** CoreDNS HA mit 3 Replicas auf 3 Nodes; K3s `--disable=coredns` persistent; alle 56 ArgoCD-Apps Synced/Healthy

## Zusammenfassung

Plan B (CoreDNS HA via eigenem Helm-Chart) wurde auf TEST ausgerollt analog DEV. Plan A (Zot HA) entfaellt in TEST, weil TEST keinen eigenen Zot hat — Topologie-Variante 2 aus Phase 9a (TEST pullt aus DEV-Zot mit Internet-Fallback).

Der Cutover war **technisch erfolgreich**, hatte aber einen **DNS-Outage von ~5 Minuten** durch eine Race-Condition mit ArgoCD Auto-Sync, die in DEV nicht aufgetreten war. Die DEV-Erfahrung war "alles ueber k8s-mgmt-10" gemacht — in TEST hat das ArgoCD-App-of-Apps-Setup den Push schneller discovered als erwartet (<60s), und die `coredns`-App hat mit Auto-Sync angefangen, bevor der Bypass-Apply auf k8s-mgmt-10 ausgefuehrt werden konnte.

Recovery erfolgte vorwaerts ohne Cluster-Wiederherstellung — durch manuelle Pod-Label-Ergaenzung, Service-Selector-Reparatur und anschliessendem sauberen Cutover gemaess (angepassten) Plan.

## Endzustand TEST

| Aspekt | Zustand |
|---|---|
| CoreDNS Pods | 3/3 Running, 1+1+1 auf k8s-test-21/22/23, AntiAffinity wirksam, RESTARTS=0 |
| Service `kube-dns` | ClusterIP 10.43.0.10, 9 Endpoints (3 Pods × UDP-53/TCP-53/TCP-9153) |
| K3s-Config `--disable=coredns` | Persistent in `/etc/rancher/k3s/config.yaml` aller 3 Nodes |
| Addon-CR `coredns` | Entfernt, kommt nicht zurueck |
| ArgoCD App `coredns` | Synced/Healthy, Auto-Sync aktiv (prune:false, selfHeal:false) |
| ArgoCD App `monitoring` | Synced/Healthy, kube-prometheus-stack-coredns Cleanup durch |
| Globaler ArgoCD-Stand | Alle 56 Apps Synced/Healthy |
| End-to-End DNS | cluster, service, extern, nodehost short+fqdn alle gruen |

## Verlauf der heutigen Session

### Phase 1 — Vorbereitung (planmaessig)

- 4 Files committed/gepusht:
  - `ansible/inventory/test/group_vars/all.yml` — `coredns` zu `k3s_disable` ergaenzt
  - `kubernetes/environments/test/coredns/values-override.yaml` — NEU mit TEST-IPs
  - `kubernetes/environments/test/infrastructure/coredns-app.yaml` — NEU
  - `kubernetes/environments/test/monitoring/values-override.yaml` — `coreDns.enabled: false` ergaenzt
- Commit `c58f2b9` auf main
- Plan A (Zot HA) verworfen fuer TEST: kein Zot in TEST (Phase 9a Variante 2)
- Image-Pre-Warming: alle 3 Nodes bekamen `rancher/mirrored-coredns-coredns:1.14.1` aus DEV-Zot via Mirror

### Phase 2 — Race-Condition mit ArgoCD Auto-Sync (DNS-OUTAGE)

**Was passiert ist:**
1. Push erfolgte 09:08 UTC
2. `test-infrastructure` ArgoCD-App-of-Apps discovered den Push innerhalb **<60s** (deutlich schneller als die geplanten "~3 min Discovery-Window" aus dem urspruenglichen Handoff)
3. ArgoCD legt die `coredns`-App an — die hat `automated: { prune: false, selfHeal: false }`
4. ArgoCD-Sync wurde durch `automated:` initial getriggert
5. Sync uebernahm via `ServerSideApply`:
   - ConfigMap `coredns` (mit neuer Corefile)
   - Service `kube-dns` (mit neuem Helm-Chart-Selector `app.kubernetes.io/name: coredns, app.kubernetes.io/instance: coredns, k8s-app: coredns`)
   - ServiceAccount, ClusterRole, ClusterRoleBinding, PDB, ServiceMonitor, coredns-metrics-Service
6. Deployment-Update scheiterte: `spec.selector: field is immutable` (alter Selector hatte `k8s-app: kube-dns`)
7. **Konsequenz:** Service `kube-dns` zeigte auf `app.kubernetes.io/name: coredns` — der laufende K3s-Default-CoreDNS-Pod hatte aber nur `k8s-app: kube-dns` als Label → keine matchenden Pods → Service ohne Endpoints
8. **DNS in TEST komplett tot.**

**Recovery (vorwaerts, ohne Rollback):**
1. ArgoCD-App auf manuell stellen: `automated: null` patchen, hängende Operation kanzeln
2. Erste Recovery-Versuch: Service-Selector mit `kubectl patch --type=merge` zurueckpatchen — **fehlgeschlagen**, weil merge auf Map ist Field-Merge, nicht Replace; Selector wurde nur erweitert, nicht ersetzt
3. Zweiter Recovery-Versuch: Pod-Label des laufenden K3s-Default-CoreDNS-Pod ergaenzt (`app.kubernetes.io/instance=coredns app.kubernetes.io/name=coredns --overwrite`) — Pod-Labels sind editierbar (anders als Deployment-Selector) → Pod matchte sofort den Service-Selector → DNS innerhalb 5s zurueck

**Outage-Dauer:** ca. 5 Minuten (von 09:08 Push bis ca. 09:13 Pod-Label-Fix).

### Phase 3 — Sauberer Cutover (planmaessig)

Nach DNS-Recovery wurden die regulaeren Cutover-Schritte durchgefuehrt:

1. **Helm-Template generieren** auf k8s-mgmt-10 in `/tmp/coredns-test.yaml`, Sanity-Checks (Resourcen-Inventar, ClusterIP 10.43.0.10, replicas 3, Image, Hosts-Plugin mit TEST-IPs)
2. **Deployment delete + apply:** altes Deployment loeschen (`--cascade=background --wait=false`), Manifest mit `--server-side --force-conflicts` apply'en. 3 neue Pods kamen in 34s up, 1+1+1 verteilt
3. **Wrangler-Annotations strippen** vom Service `kube-dns`, ConfigMap `coredns`, ServiceAccount `coredns` (alle drei `objectset.rio.cattle.io/*` Annotations + Hash-Label)
4. **Addon-CR `coredns` direkt deleten** — dadurch hatte Wrangler keinen Trigger mehr, und der spaetere K3s-Restart konnte ohne Cleanup-Risiko erfolgen
5. **Ansible-Playbook 09 ausfuehren** — schreibt `disable: coredns` persistent in `/etc/rancher/k3s/config.yaml` und restartet K3s sequenziell. **Wichtige Beobachtung:** Die laufenden CoreDNS-Pods wurden **nicht** durch den K3s-Restart angetastet (RESTARTS=0 nach komplettem Playbook-Run) — containerd laeuft unabhaengig vom K3s-Service auf dem Node, Pods bleiben Running
6. **ArgoCD-Adoption:** Hard Refresh + manueller Sync mit `Force=true` → Synced/Healthy. Anschliessend Auto-Sync wieder aktiviert (prune:false, selfHeal:false — defensive bei DNS-kritischer App)
7. **monitoring-App Refresh** — der erste Sync-Versuch hing im PreSync-Hook (`kube-prometheus-stack-admission-create` Job-TTL-Issue, ArgoCD-internal-Hook-Tracker glaubte Job laeuft noch obwohl der Pod schon weg war). Workaround: Die 3 zu prunenden Resources direkt deleten, Operation canceln, hard refresh → App auf Synced/Healthy

## Lessons Learned

### LL-T1 (kritisch fuer PROD): ArgoCD App-of-Apps-Discovery <60s

ArgoCDs `test-infrastructure` App hat den Push deutlich schneller discovered als das urspruengliche Handoff-Doc dachte. Der Bypass auf k8s-mgmt-10 muesste in **direkter Sekundenfolge** nach dem Push laufen, was operativ riskant ist.

**Loesung fuer PROD:** Die `coredns`-App **ohne `automated:`-Block deployen**. Der initiale Sync wird damit nicht ausgeloest, der Cluster-State bleibt unter Kontrolle des Operators. Auto-Sync wird erst nach erfolgreichem Cutover aktiviert.

```yaml
# kubernetes/environments/prod/infrastructure/coredns-app.yaml
spec:
  ...
  syncPolicy:
    # KEIN automated: Block hier!
    syncOptions:
      - ServerSideApply=true
```

Nach erfolgreichem Cutover dann ein-Liner:
```bash
kubectl --context k8s-prod -n argocd patch application coredns \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":false}}}}'
```

### LL-T2 (kritisch): Wrangler-Annotations ueberleben `--force-conflicts`

`kubectl apply --server-side --force-conflicts` uebernimmt **nur Felder, die im Manifest stehen**. Die `objectset.rio.cattle.io/*` Annotations und das `objectset.rio.cattle.io/hash` Label sind nicht im Helm-Output → bleiben unter K3s-Wrangler-Ownership.

Wenn Wrangler beim spaeteren K3s-Restart sein objectset reconcilen will und Annotations noch da sind, raeumt er den Service `kube-dns`, ConfigMap `coredns`, ServiceAccount `coredns` ab → DNS-Outage.

**Loesung:** Vor dem Ansible-Playbook 09 die Wrangler-Annotations explizit strippen + Addon-CR `coredns` direkt deletten (mit leeren objectset bewirkt das kein DNS-Outage).

### LL-T3 (technisch): kubectl `--type=merge` ist Field-Merge, nicht Replace

Beim Recovery-Versuch wurde `kubectl patch service kube-dns --type=merge -p '{"spec":{"selector":{"k8s-app":"kube-dns"}}}'` verwendet — in der Erwartung, der Selector wuerde ersetzt. Tatsaechlich macht merge-patch ein **Field-Merge auf Map-Ebene**: der `k8s-app` Key wurde gesetzt, aber `app.kubernetes.io/instance` und `app.kubernetes.io/name` blieben drin.

**Korrekt:** `--type=json` mit `op:replace`:
```bash
kubectl patch service kube-dns -n kube-system --type=json \
  -p='[{"op":"replace","path":"/spec/selector","value":{"k8s-app":"kube-dns"}}]'
```

### LL-T4 (Recovery-Werkzeug): Pod-Labels sind editierbar zur Service-Selector-Reparatur

Wenn ein Service-Selector keine Pods mehr matcht, ist die schnellste Recovery-Variante, **die Pod-Labels zu erweitern**, sodass der Pod den aktuellen Service-Selector matcht. Pod-Labels sind editierbar (`kubectl label pod ... key=value --overwrite`), Deployment-Selectors sind immutable.

```bash
# Beispiel-Recovery: Service-Selector wurde unverzichtbar geaendert
kubectl label pod coredns-XXXXX -n kube-system \
  app.kubernetes.io/instance=coredns app.kubernetes.io/name=coredns --overwrite
# DNS in <5s zurueck
```

### LL-T5 (technisch): K3s-Restart laesst CoreDNS-Pods unangetastet

Wenn die CoreDNS-Pods bereits laufen (durch Helm-Chart, nicht mehr K3s-Default-Addon), bleibt der `kubelet`-Service-Restart auf einem Node ohne Auswirkung auf die Pods. containerd laeuft separat, der laufende Container wird nicht neugestartet. Dies wurde in TEST verifiziert: nach dem kompletten Playbook-Run (3 Node-Restarts) hatten alle 3 CoreDNS-Pods `RESTARTS=0` und die gleichen Pod-Namen wie vor dem Playbook.

→ **Konsequenz:** Wir muessen uns nicht um Pod-Verluste waehrend des Playbook-Runs sorgen, solange die Pods initial laufen.

### LL-T6 (Annoyance): kube-prometheus-stack PreSync-Hook-Hang

Der `kube-prometheus-stack-admission-create` Job hat `ttlSecondsAfterFinished` und ist nach Tagen gone. ArgoCDs interner Hook-Tracker zeigt aber noch "Running" und blockiert die Sync/Prune-Phase.

**Workaround (nicht 12b-spezifisch, generell bei kube-prometheus-stack-Pruning):**
```bash
# Die zu prunenden Resources direkt deleten
kubectl delete <resource>

# Operation cancel
kubectl patch application monitoring -n argocd --type merge -p '{"operation":null}'

# Hard refresh — App erkennt jetzt Resources weg → Synced
kubectl patch application monitoring -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Anpassungen am PROD-Cutover-Plan

Die obigen Lessons sind in `phase-12b-coredns-test-prod-handoff.md` (Stand 06.05.2026) eingearbeitet. Die wichtigsten 3 Aenderungen gegenueber dem urspruenglichen Plan:

1. **ArgoCD-App OHNE `automated:` deployen** — verhindert die Race-Condition aus LL-T1
2. **Wrangler-Annotations + Addon-CR-Delete als zwingender Pre-Playbook-Schritt** — verhindert das Risiko aus LL-T2
3. **Reihenfolge umgedreht:** Apply zuerst (vor Playbook), nicht parallel/danach — saubererer Ablauf, weil ArgoCD-App keine Auto-Sync hat und kein Race-Risiko besteht

## Pre-Existing Issues (NICHT 12b-bedingt)

Bei der finalen Cluster-Pruefung wurden 2 nicht-Phase-12b-Alarme gefunden:
- **`KubePersistentVolumeFillingUp`** (critical) — `thanos-compactor` PVC zu 99.31% voll
- **`ThanosCompactionFailed`** (warning) — 12 fehlgeschlagene Compactions/h, seit 04.05.2026 08:26 UTC

Beide haengen kausal zusammen (Compactions schlagen fehl → Daten akkumulieren → PV voll). Keine Aktion im Rahmen Phase 12b — separates Tracking.

**Status (Update 06.05.2026):** Beide Alarme behoben durch PVC-Resize 10Gi → 30Gi in TEST und PROD. Details: [monitoring-thanos-pvc-resize-test-prod.md](monitoring-thanos-pvc-resize-test-prod.md).

## Naechste Schritte

1. **24h Burn-in** auf TEST (bis 07.05.2026 mittags)
2. **PROD-Rollout** in neuer Chat-Session, basierend auf aktualisiertem Handoff-Doc und diesem Lessons-Doc — **erledigt 07.05.2026**, siehe [phase-12b-prod-completed.md](phase-12b-prod-completed.md) (Cutover ohne DNS-Outage durchgefuehrt; alle TEST-Lessons LL-T1 bis LL-T6 bestaetigt)
3. **Pre-existing Thanos-Alerts** in TEST separat untersuchen (eigener Sub-Task) — **erledigt 06.05.2026**, siehe [monitoring-thanos-pvc-resize-test-prod.md](monitoring-thanos-pvc-resize-test-prod.md)
