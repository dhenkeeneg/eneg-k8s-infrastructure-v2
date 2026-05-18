# Phase 13: Kyverno + Longhorn Stabilisierung (DEV)

**Status:** Implementiert (DEV), Verifikation laeuft  
**Datum:** 18.05.2026  
**Umgebung:** DEV (k8s-dev-21/22/23)  
**Verwandte Dokumente:**
- `docs/decisions/ADR-003-kyverno-webhook-hardening.md`
- `docs/phases/phase-09-security-dev.md` (Kyverno Original-Deployment)
- `docs/phases/phase-12-ha-improvements-completed.md`

---

## Ausgangslage

Bei der Routinepruefung der DEV-Umgebung sind drei verkettete Probleme aufgefallen:

### Symptome

1. **Longhorn UI zeigt permanent Meldungen** `Snapshot becomes not ready to use`
   - 34 Snapshots ueber 7 Tage gefunden
   - 32 mit `readyToUse: false`
   - ~80 GB belegt durch alte, eigentlich geloeschte Snapshots
2. **Kyverno meldet ClusterPolicy-Violations** im PolicyReport-Dashboard
   - `disallow-host-path` fuer `velero/velero-daily-backup-*`
   - `disallow-host-path` + `disallow-privileged-containers` fuer `longhorn-manager`
3. **longhorn-manager Pods restarten** kontinuierlich (~1x/Tag)
   - Aktueller Restart-Count auf k8s-dev-21: 75
   - Letzter Crash: 14.05.2026 16:07 mit Exit Code 1

### Cluster-Zustand (Diagnose vor Aktion)

| Check | Ergebnis |
|---|---|
| Volumes attached + healthy | OK 37/37 |
| Replicas running | OK 80/80 |
| Failed Replicas | OK 0 |
| Longhorn-Manager Pods | Running auf allen 3 Nodes |
| Kyverno ClusterPolicies | 11 Stueck, alle im Audit-Mode |

**Keine Datenintegritaet gefaehrdet** - alle Symptome sind sekundaerfolge.

---

## Root Cause

Tiefere Analyse hat ergeben, dass alle drei Symptome auf **eine gemeinsame Wurzel**
zurueckgehen: Die Kyverno-Default-Konfiguration `failurePolicy: Fail` auf dem
Pod-Security-Webhook.

```
Kyverno-Pod-Restart
       \|
kyverno-svc kurz ohne Endpoints (failurePolicy=Fail)
       \|
longhorn-manager crashed beim Webhook-Setup-API-Call (Exit 1)
       \|
DaemonSet Pod restart -> Replica-Reconnect
       \|
Auto-Balance 'best-effort' triggert Rebuilds
       \|
Snapshots 'not ready to use' als Nebenwirkung
       +
Parallel: PolicyViolations auf longhorn-manager (host-path + privileged)
Parallel: PolicyViolation auf Velero (host-path)
```

Crash-Log auszug aus longhorn-manager Previous-Container:

```
fatal msg="Error starting webhooks: Internal error occurred:
failed calling webhook 'validate.kyverno.svc-fail':
no endpoints available for service 'kyverno-svc'"
```

Details siehe `docs/decisions/ADR-003-kyverno-webhook-hardening.md`.

---

## Aenderungen

### Dateien

| # | Datei | Aktion |
|---|---|---|
| 1 | `kubernetes/environments/dev/longhorn/values-override.yaml` | NEU |
| 2 | `kubernetes/environments/dev/infrastructure/longhorn-app.yaml` | Edit (zweite valueFile) |
| 3 | `kubernetes/environments/dev/kyverno-policies/values-override.yaml` | NEU |
| 4 | `kubernetes/environments/dev/infrastructure/kyverno-policies-app.yaml` | Edit (zweite valueFile) |
| 5 | `docs/decisions/ADR-003-kyverno-webhook-hardening.md` | NEU |
| 6 | `docs/phases/phase-13-kyverno-longhorn-stabilization-dev.md` | NEU (diese Datei) |
| 7 | `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.22.md` | NEU (Version-Bump) |

### Konkrete Konfigurationen

**Longhorn DEV Override:**

```yaml
# kubernetes/environments/dev/longhorn/values-override.yaml
defaultSettings:
  replicaAutoBalance: least-effort
```

**Kyverno Policies DEV Override:**

```yaml
# kubernetes/environments/dev/kyverno-policies/values-override.yaml
failurePolicy: Ignore

policyExclude:
  disallow-host-path:
    any:
    - resources:
        kinds:
        - Pod
        namespaces:
        - longhorn-system
        - velero
        - monitoring
  disallow-privileged-containers:
    any:
    - resources:
        kinds:
        - Pod
        namespaces:
        - longhorn-system
        - velero
        - monitoring
```

---

## Implementierungs-Schritte

### Schritt 1: Code-Aenderungen (durchgefuehrt)

Alle 4 YAML-Dateien (Schritt 1-4 in der Tabelle oben) wurden mit Python-Helper-Skripten
erstellt und mit `yaml.safe_load()` validiert.

### Schritt 2: Commit & Push (durch Daniel)

```bash
cd C:\Users\dhenke\git\eneg-k8s-infrastructure-v2
git add kubernetes/environments/dev/longhorn/values-override.yaml
git add kubernetes/environments/dev/kyverno-policies/values-override.yaml
git add kubernetes/environments/dev/infrastructure/longhorn-app.yaml
git add kubernetes/environments/dev/infrastructure/kyverno-policies-app.yaml
git add docs/decisions/ADR-003-kyverno-webhook-hardening.md
git add docs/phases/phase-13-kyverno-longhorn-stabilization-dev.md
git add docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.22.md
git status
git commit -m 'feat(dev): kyverno webhook hardening + longhorn least-effort auto-balance (Phase 13)'
git push origin main
```

### Schritt 3: ArgoCD-Sync abwarten

```bash
# Auf k8s-mgmt-10 oder per ArgoCD-UI
argocd app sync longhorn --grpc-web
argocd app sync kyverno-policies --grpc-web
argocd app wait longhorn --grpc-web --timeout 300
argocd app wait kyverno-policies --grpc-web --timeout 300
```

### Schritt 4: Verifikation (durch Claude)

```bash
# Kyverno Webhook failurePolicy
kubectl --context k8s-dev get validatingwebhookconfiguration \
  kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}: {.failurePolicy}{"\n"}{end}'

# ClusterPolicy exclude
kubectl --context k8s-dev get clusterpolicy disallow-host-path \
  -o jsonpath='{.spec.rules[0].exclude}' | python -m json.tool

# Longhorn Auto-Balance
kubectl --context k8s-dev -n longhorn-system get settings.longhorn.io \
  replica-auto-balance -o jsonpath='{.value}'
```

### Schritt 5: Snapshot-Purge (operativ, nach Verifikation)

Nach erfolgreicher Verifikation der Auto-Balance-Umstellung koennen die alten
`markRemoved=true` Snapshots gepurged werden:

```bash
# Volumes mit alten Snapshots identifizieren
kubectl --context k8s-dev -n longhorn-system get snapshots.longhorn.io \
  -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volume,READY:.status.readyToUse,REMOVED:.status.markRemoved \
  | grep -E 'false.*true'

# Pro betroffenem Volume:
kubectl --context k8s-dev -n longhorn-system patch volume.longhorn.io <VOLUME-NAME> \
  --type=merge -p '{"spec":{"snapshotPurgeRequested":true}}'
```

---

## Verifikations-Checkliste

- [ ] ArgoCD Apps `longhorn` + `kyverno-policies` sind Synced + Healthy
- [ ] `failurePolicy: Ignore` ist im ValidatingWebhook gesetzt
- [ ] ClusterPolicy `disallow-host-path` hat `exclude` mit 3 Namespaces
- [ ] ClusterPolicy `disallow-privileged-containers` hat `exclude` mit 3 Namespaces
- [ ] Longhorn `replica-auto-balance` Setting = `least-effort`
- [ ] longhorn-manager Pods keine neuen Restarts in den letzten 48h
- [ ] PolicyReports zeigen keine Violations mehr fuer Longhorn/Velero/Monitoring
- [ ] Keine neuen 'snapshot not ready to use' Meldungen
- [ ] Alte System-Snapshots gepurged

---

## Rollback-Strategie

Falls die Aenderungen unerwartete Probleme verursachen, ist Rollback unkompliziert:

```bash
cd ~/git/eneg-k8s-infrastructure-v2
git revert HEAD
git push origin main
# ArgoCD synced automatisch zurueck
```

Die Aenderungen sind reversible:
- `replicaAutoBalance: least-effort` -> zurueck zu Base-Default `best-effort` (Settings reagiert sofort)
- `failurePolicy: Ignore` -> Chart-Default `Fail` (Webhook re-deployed in <1min)
- `policyExclude: {...}` -> Chart-Default `{}` (ClusterPolicies werden re-rendered)

Bereits gepurgte Snapshots sind NICHT reversibel - aber sie waren ohnehin
`markRemoved: true` und damit nicht zur Wiederherstellung gedacht.

---

## Learnings

1. **Kyverno hat zwei separate Webhook-Konfigurationen**: Der Webhook aus dem `kyverno`
   Helm-Chart (`admissionController.webhookConfiguration.failurePolicy`) ist NICHT
   identisch mit dem Webhook aus dem `kyverno-policies` Chart (`failurePolicy` Top-Level).
   Bei der Erstkonfiguration im Phase 9 wurde nur Ersterer auf `Ignore` gesetzt.

2. **Audit-Mode schuetzt nicht vor API-Blockaden**: Eine ClusterPolicy mit
   `validationFailureAction: Audit` blockiert zwar keine Resources, aber der
   zugrundeliegende Admission-Webhook kann trotzdem den API-Call durchschalten oder
   blockieren - das wird durch `failurePolicy` gesteuert.

3. **Symptom-Verkettung war nicht offensichtlich**: Die Verbindung zwischen 'Longhorn-Snapshot
   not ready to use' und 'Kyverno Webhook failurePolicy' war erst nach Tieftauchen in die
   longhorn-manager Previous-Container-Logs sichtbar. Erste Hypothese (Auto-Balance) war
   richtig fuer den Snapshot-Storm, aber sekundaer - Root Cause war Kyverno.

4. **Per-Policy-Excludes brauchen `kinds: [Pod]` explizit**: Auch wenn die Pod-Security-
   Policies nur auf Pods matchen, muss das im exclude-Block explizit angegeben werden.
   Das offizielle Chart-Beispiel macht es so, und es ist sicherer fuer zukuenftige
   Policy-Anpassungen.

---

## Naechste Schritte (Roadmap)

- **48h-Observation auf DEV**: longhorn-manager Restart-Verhalten beobachten, PolicyReports
  pruefen. Ziel: Restart-Count waechst nicht mehr.
- **Snapshot-Purge auf DEV**: alte `markRemoved=true` Snapshots aufraeumen.
- **TEST-Rollout** (sobald TEST-Cluster wieder eingeschaltet ist): Phase 13b mit getrennter
  Validierung.
- **PROD-Rollout** (nach TEST-Burn-In): Phase 13c.
- **Spaeter**: Kyverno HA (3 Repliken) als separate Phase fuer alle Kyverno-Controller in
  der Base. Bis dahin bleibt `failurePolicy: Ignore` die richtige Schutzmassnahme.
