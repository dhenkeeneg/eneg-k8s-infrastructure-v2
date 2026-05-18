# ADR-003: Kyverno Webhook Hardening (failurePolicy + Per-Policy-Excludes)

**Status:** Akzeptiert (DEV), TEST/PROD stehen aus  
**Datum:** 18.05.2026  
**Entscheider:** Daniel Henke  
**Phase:** Phase 13 (Kyverno + Longhorn Stabilisierung)  
**Betrifft:** kyverno v1.17.1, kyverno-policies Helm Chart v3.7.1

---

## Kontext

In Phase 9 wurde Kyverno als Cluster-Policy-Engine deployed, mit den Pod Security Standards
(Baseline) im Audit-Modus. Die passive Triage ueber PolicyReports war gewollt, um Observability
zu gewinnen ohne Workloads zu blockieren.

In Phase 13 (18.05.2026) ist aufgefallen, dass die gewaehlte Default-Konfiguration zwei
indirekte Probleme verursacht:

### 1. longhorn-manager Crash-Loop durch Kyverno-Webhook

Der `kyverno-resource-validating-webhook-cfg` hat **per Default `failurePolicy: Fail`**
(trotz aller ClusterPolicies im Audit-Mode). Bei jedem Kyverno-Pod-Restart ist der
Service-Endpoint phasenweise nicht verfuegbar. Durch `failurePolicy: Fail` schlaegt
jede Admission-Validierung von Pods waehrend des Outages fehl.

Das trifft insbesondere den `longhorn-manager`, der seine eigenen Webhooks beim Start
per API-Call registriert. Beobachtet auf k8s-dev: **75 Restarts in 88 Tagen** (~1 Restart
pro 1.2 Tage) mit Fehlermeldung:

```
fatal msg="Error starting webhooks: Internal error occurred:
failed calling webhook 'validate.kyverno.svc-fail':
no endpoints available for service 'kyverno-svc'"
```

Die fruehere Konfiguration `admissionController.webhookConfiguration.failurePolicy: Ignore`
in der Kyverno Base greift hier **nicht**, weil die Pod-Security-Policies aus dem zweiten
Chart (`kyverno-policies`) einen separaten Webhook mit `Fail` registrieren.

### 2. Snapshot-Storm als Sekundaerfolge

Jeder longhorn-manager-Restart triggert Replica-Reconnect. In Kombination mit dem
`replicaAutoBalance: best-effort` Default werden permanent Rebuild-Operationen gestartet,
die jeweils einen `markRemoved=true` System-Snapshot vom Volume-Head erzeugen. Im
Longhorn-UI erscheinen kontinuierlich Meldungen:

```
Snapshot <uid> longhorn-system Update snapshot becomes not ready to use
```

Beobachtet auf k8s-dev: 34 Snapshots ueber ~7 Tage, davon 32 mit `readyToUse=false`,
~80 GB belegt durch alte, eigentlich geloeschte Snapshots.

### 3. Alarm-Rauschen durch unnoetige PolicyViolations

Die Policies `disallow-host-path` und `disallow-privileged-containers` erzeugen dauerhaft
PolicyReports fuer Komponenten, die hostPath bzw. privileged Mode **by-design** brauchen:

- `longhorn-manager`, `instance-manager` (hostPath: `/var/lib/longhorn`, `/dev`, `/proc`)
- `velero-daily-backup-*` (hostPath: Node-Volumes fuer Kopia fs-backup)
- `node-exporter` im `monitoring` Namespace (hostPath: `/proc`, `/sys`)

Das verursacht Alarm-Rauschen in der Kyverno-UI und Missreports im Security-Dashboard.

---

## Entscheidung

Drei Aenderungen an der `kyverno-policies`-Konfiguration, durchgefuehrt in einer
**DEV-Override-Datei (nicht in der Base)**, damit TEST/PROD getrennt gerollt werden:

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

### Begleitende Longhorn-Aenderung

Zusaetzlich in `kubernetes/environments/dev/longhorn/values-override.yaml`:

```yaml
defaultSettings:
  replicaAutoBalance: least-effort
```

Conservative Auto-Balance vermeidet permanente Rebuilds bei 1-Replica-Volumes (CNPG WAL,
Cache, einzelne Sub-Volumes), die vom `best-effort`-Modus dauerhaft als 'imbalanced'
gewertet werden.

### Begruendungen im Detail

**1. `failurePolicy: Ignore`**  
Alle Pod-Security-Policies laufen im Audit-Modus (`validationFailureAction: Audit`).
Ignore ist damit semantisch korrekt: Wir wollen nur Reports erzeugen, niemals API-Calls
blockieren. Das eliminiert den longhorn-manager Crash-Loop bei Kyverno-Pod-Restarts.

**2. `policyExclude` fuer drei Namespaces**  
Die drei Cluster-Komponenten `longhorn-system`, `velero` und `monitoring` werden aus den
Policies `disallow-host-path` und `disallow-privileged-containers` explizit ausgeschlossen.
Schema folgt 1:1 dem offiziellen kyverno-policies Chart-Beispiel (`kinds: [Pod]` +
`namespaces: [...]`).

**3. Nicht in der Base**  
Die Override ist bewusst Environment-spezifisch:
- DEV ist heute der einzige Cluster mit dieser Haertung. TEST/PROD rollen spaeter.
- Grenzt das Risiko einer Fehlkonfiguration auf einen Cluster ein.
- Passt zur ADR-002 Branch-per-Environment-Strategie (noch nicht implementiert, aber
  DEV-spezifische Overrides simulieren das Verhalten).

---

## Alternativen

### A. Alle Policies auf Enforce umkonfigurieren
*Abgelehnt:* Wuerde Ship-Deployments aktiv blockieren. Zu riskant fuer DEV, und ohne tiefere
Pre-Validierung der bestehenden Workloads nicht praktikabel.

### B. Nur policyExclude, failurePolicy auf Fail belassen
*Abgelehnt:* Loest das Rausch-Problem, aber NICHT den longhorn-manager-Crash. Root-Cause der
'not ready to use'-Snapshots bleibt bestehen.

### C. Kyverno auf 3 Repliken skalieren (HA)
*Vertagt:* Loest das Problem nur teilweise (Restarts werden seltener, passieren aber weiter).
HA-Deployment wird spaeter als separate Phase fuer alle Kyverno-Controller (Admission,
Background, Reports) in der Base gemacht. Repliken = 1 bleiben fuer jetzt.

### D. Excludes nur fuer betroffene Policies, kein globales failurePolicy
*Abgelehnt:* Globales `failurePolicy: Ignore` ist semantisch konsistent mit dem Audit-Mode
aller Policies. Per-Policy-Settings waeren inkonsistent und fehleranfaelliger bei zukuenftigen
Policy-Additionen.

---

## Konsequenzen

### Positiv

- longhorn-manager Crash-Loop faellt weg (langzeitig keine Restarts mehr durch Kyverno-Outages).
- Replica-Rebuilds im Longhorn werden nicht mehr durch Crash-Recovery getriggert (keine
  unnoetigen 'snapshot not ready to use'-Meldungen mehr).
- PolicyReport-Dashboard wird aufgeraeumt von alarm-irrelevanten Violations.
- Greift auch fuer zukuenftige Komponenten im Audit-Mode.

### Negativ

- `disallow-host-path` / `disallow-privileged-containers` wird fuer 3 Namespaces bewusst
  nicht gereportet. Fuer diese Komponenten wird die Sicherheitspruefung stattdessen via
  Code-Review abgewickelt.
- `failurePolicy: Ignore` ist 'less strict by design': Kyverno-Outages werden zu Admit-all
  statt blockieren. Bei geplanter Umstellung auf Enforce (z.B. spaeter in TEST/PROD) muss
  reevaluiert werden.
- DO-NOT-PORT pauschal zu TEST/PROD ohne getrennte Review-Session: das ist warum die
  Override bewusst in DEV-spezifischen Werten bleibt.

---

## Validierung

Nach Git-Push + ArgoCD-Sync:

```bash
# 1. Kyverno Webhook aktualisiert?
kubectl --context k8s-dev get validatingwebhookconfiguration \
  kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{" "}{.failurePolicy}{"\n"}{end}'
# Erwartet: failurePolicy=Ignore fuer Pod-Security-Webhooks

# 2. ClusterPolicy hat exclude?
kubectl --context k8s-dev get clusterpolicy disallow-host-path \
  -o jsonpath='{.spec.rules[0].exclude}'
# Erwartet: namespaces fuer longhorn-system, velero, monitoring

# 3. longhorn-manager restartCount eingefroren?
kubectl --context k8s-dev -n longhorn-system get pods -l app=longhorn-manager -w
# 48h beobachten - keine Restarts mehr durch Kyverno

# 4. Longhorn Auto-Balance umgestellt?
kubectl --context k8s-dev -n longhorn-system get settings.longhorn.io \
  replica-auto-balance -o jsonpath='{.value}'
# Erwartet: 'least-effort'
```

---

## Referenzen

- `docs/phases/phase-13-kyverno-longhorn-stabilization-dev.md` (Implementierungs-Doku)
- `docs/phases/phase-09-security-dev.md` (Kyverno Original-Deployment)
- Kyverno Docs: https://kyverno.io/docs/installation/customization/
- kyverno-policies Chart values: https://github.com/kyverno/policies
