# Drift-Analyse DEV -> TEST/PROD (Juli 2026)

**Erstellt:** 14.07.2026
**Charakter:** reine Bestandsaufnahme - keine Aenderungen, kein Commit, kein Rollout
**Cluster-Kontexte:** k8s-dev, k8s-test, k8s-prod (Kubernetes-MCP read-only)
**Repo-Stand:** branch `main` (lokaler Klon Windows-Laptop)

---

## 1. Einordnung

### Ausgangslage

In den letzten Monaten wurde intensiv an **k8s-dev** weiterentwickelt, waehrend
**k8s-test** und **k8s-prod** zeitweise abgeschaltet waren und daher nicht
kontinuierlich nachgezogen wurden. Ziel dieser Analyse ist eine vollstaendige,
belastbare Bestandsaufnahme des Drifts zwischen den drei Clustern als Grundlage
fuer einen spaeteren, kontrollierten Angleich (DEV -> TEST -> PROD).

**Diese Datei ist reine Analyse. Es wurde nichts ausgerollt, nichts committet
und keine Cluster-Aenderung vorgenommen.**

### Ziel

Die drei Cluster wieder moeglichst identisch machen - unter Beibehaltung der
bewusst umgebungsspezifischen Unterschiede (VLANs, IPs, Ingress-Hosts,
Ressourcen-Dimensionierung, Secrets).

### Bewusst ausgenommen

**Trivy Operator** und **Kyverno** (inkl. Kyverno-Policies) werden in diesem
Durchlauf **NICHT** nach TEST/PROD gebracht. Sie sind vollstaendig erfasst und
in Abschnitt 6 klar als "bewusst zurueckgestellt / aktuell DEV-only" markiert,
damit ein spaeterer Durchlauf sie nicht faelschlich als vergessenen Drift
aufgreift.

---

## 2. Methodik

Drift ermittelt aus drei Quellen:

1. **Repo** (`kubernetes/base/` + `kubernetes/environments/{dev,test,prod}/`):
   ArgoCD-Application-Definitionen, Helm-Chart-Versionen (`targetRevision`),
   `values-override`-Dateien, Kustomize-Overlays, fehlende/abweichende Dateien.
2. **Live-Cluster** (read-only): ArgoCD-App-Sync/Health, laufende Image-Versionen,
   Longhorn `settings.longhorn.io`, StorageClasses, CNPG-Cluster-Specs, Operatoren.
3. **docs/ + vergangene Chats**: Projektplanung v2.31, Incident-/Phasen-Docs.

---

## 3. Zentrale strukturelle Erkenntnis (WICHTIG)

**Alle drei Cluster synchronisieren aus demselben Git-Branch `main`.**

Verifiziert 14.07.2026:
- `dev-infrastructure`  -> `environments/dev/infrastructure`,  targetRevision `main`
- `test-infrastructure` -> `environments/test/infrastructure`, targetRevision `main`
- `prod-infrastructure` -> `environments/prod/infrastructure`, targetRevision `main`
- Auf `origin` existieren **keine** Branches `test` / `prod` mehr (nur `main`).

**Konsequenz fuer die Drift-Bewertung:**

- Die in ADR-002 beschriebene Branch-per-Environment-Promotion ist aktuell
  **faktisch ausser Kraft** (siehe offene Frage OF-1).
- Jede Aenderung an `kubernetes/base/**` wirkt **sofort auf alle drei Cluster**,
  sobald ArgoCD synct. Mehrere in der Projektplanung als "TEST/PROD ausstehend"
  markierte base-Aenderungen sind daher **de facto bereits ueberall aktiv**
  (CNPG-Operator 1.28.3, CNPG-Alerts `CnpgClusterNoPrimary` /
  `CnpgReplicationSlotInactive`, Loki-Compactor-Retention-Enforcement).
- **Echter nachziehbarer Drift entsteht nur noch aus environment-spezifischen
  Overlays** (`environments/{test,prod}/**`), die gegenueber `environments/dev/**`
  fehlen oder abweichen - NICHT aus `base/`.

---

## 4. Live-Zustand (Momentaufnahme 14.07.2026)

| Cluster | ArgoCD-Apps | Sync/Health |
|---------|-------------|-------------|
| DEV  | 66 | alle Synced + Healthy |
| TEST | 56 | alle Synced + Healthy |
| PROD | 56 | alle Synced + Healthy; Ausnahme `cnpg-cluster` OutOfSync (kosmetisch) |

Differenz DEV vs TEST/PROD = genau 8 App-Definitionen (Abschnitt 5.1) + der
App-of-Apps-Name. TEST und PROD haben untereinander **identische** App-Listen.

**PROD `cnpg-cluster` OutOfSync:** betrifft nur `Cluster/cnpg-erp`. Ursache:
immutables Feld `bootstrap.recovery` (cnpg-erp-v2-Recovery 08.07.). Rein
kosmetisch, Health gruen - **kein Handlungsbedarf.**
-- ERLEDIGT 14.07.2026: `bootstrap.recovery` + `externalClusters` aus Git
entfernt, App wieder `Synced/Healthy`. Zusaetzlich serverName vN (cnpg-erp-v2 +
cnpg-shared-v2) entfernt -> PROD an DEV/TEST angeglichen. Siehe
incidents/2026-07-14-nas-reboot-verifikation-cnpg-backup-cleanup.md.

---

## 5. Drift pro Komponente

Legende Spalte "Nachziehen?":
- **JA** = echter Drift, sollte nach TEST/PROD angeglichen werden
- **NEIN (env)** = umgebungsspezifisch gewollt abweichend, kein Drift
- **NEIN (DEV-only)** = bewusst nur in DEV (siehe Abschnitt 6 fuer Trivy/Kyverno)
- **ERLEDIGT** = bereits ueberall gleich (meist via geteiltem `base/`)

### 5.1 Nur in DEV vorhandene ArgoCD-Apps (fehlen in TEST + PROD)

Exakt 8 App-Definitionen existieren nur unter `environments/dev/infrastructure/`:

| App | Chart / Version | Nachziehen? | Bemerkung |
|-----|-----------------|-------------|-----------|
| `trivy-operator` | trivy-operator 0.32.1 | **NEIN (zurueckgestellt)** | siehe Abschnitt 6 |
| `kyverno` | kyverno 3.7.1 | **NEIN (zurueckgestellt)** | siehe Abschnitt 6 |
| `kyverno-policies` | kyverno-policies 3.7.1 | **NEIN (zurueckgestellt)** | siehe Abschnitt 6 |
| `registry` (Zot) | zot 0.1.104 | **NEIN (Phase 9a offen)** | Etappe B (PROD-Zot + Cutover) noch offen; DEV-Zot dient auch TEST als Pull-Quelle |
| `registry-secrets` | (SOPS) | **NEIN (Phase 9a offen)** | gehoert zu `registry` |
| `alloy-vcenter` | alloy 1.10.0 | **NEIN (DEV-only per Design)** | vCenter-Monitoring laeuft zentral aus DEV; explizit nie nach TEST/PROD |
| `alloy-vcenter-secrets` | (SOPS) | **NEIN (DEV-only per Design)** | gehoert zu `alloy-vcenter` |
| `priorityclasses` | (base/priorityclasses) | **JA** | Resilienz-Haertung 29.06.; Voraussetzung fuer `priorityClassName` an DB-Pods (Abschnitt 5.3). **Hohe Prioritaet.** |

### 5.2 Helm-Chart-Versionen (targetRevision)

Systematischer Vergleich aller gemeinsamen Apps ueber die drei Overlays:
**KEIN Chart-Versionsdrift.** Alle gemeinsam vorhandenen Apps referenzieren
identische `targetRevision`, da sie dasselbe `base/` + denselben `main`-Branch
nutzen. Live verifiziert:

| Komponente | Version (alle 3 Cluster) | Nachziehen? |
|------------|--------------------------|-------------|
| CNPG-Operator | 1.28.3 (Chart 0.27.1, image.tag-Override) | ERLEDIGT (base) |
| CNPG Barman Plugin | v0.11.0 | ERLEDIGT (base) |
| MariaDB-Operator | 25.10.4 | ERLEDIGT (base) |
| Traefik | v3.6.7 (Chart 39.0.0) | ERLEDIGT (base) |
| Longhorn | v1.9.2 | ERLEDIGT (base) |
| kube-prometheus-stack | 83.0.0 | ERLEDIGT (base) |
| Loki | 6.55.0 (App v3.6.7) | ERLEDIGT (base) |
| Thanos | 17.3.1 | ERLEDIGT (base) |
| Velero | v1.17.1 (Chart 11.3.2) | ERLEDIGT (base) |

> Der CNPG-Operator-Patch 1.28.3 (Resilienz-Haertung 29.06., CVE-2026-44477) und
> die neuen CNPG-Alerts liegen in `base/` und laufen daher bereits in allen drei
> Clustern - obwohl die Projektplanung sie als "TEST/PROD ausstehend" fuehrt.
> Die App-Kommentare in `test/prod/.../cnpg-operator-app.yaml` sagen noch
> "v1.28.1" (rein kosmetisch, Live-Stand ist 1.28.3).

### 5.3 Datenbanken - Resilienz-Haertung (CNPG + MariaDB Galera)

Aus der Resilienz-Haertung vom 29.06.2026 (DEV). Live-Werte 14.07.2026:

**CNPG-Cluster (Spec live):**

| Cluster | walStorage | max_slot_wal_keep_size | priorityClassName |
|---------|-----------|------------------------|-------------------|
| DEV cnpg-erp     | 8Gi | 6GB | eneg-stateful-critical |
| DEV cnpg-shared  | 8Gi | 6GB | eneg-stateful-critical |
| TEST cnpg-erp    | 8Gi (15.07.) | 6GB (15.07.) | eneg-stateful-critical (15.07.) |
| TEST cnpg-shared | 8Gi (15.07.) | 6GB (15.07.) | eneg-stateful-critical (15.07.) |
| PROD cnpg-erp    | 8Gi | 6GB | eneg-stateful-critical (15.07.) |
| PROD cnpg-shared | 8Gi (15.07.) | 6GB (15.07.) | eneg-stateful-critical (15.07.) |

**TEST + PROD vollstaendig gehaertet (P2 komplett erledigt 14./15.07.2026).** Alle
drei Cluster (DEV/TEST/PROD) bei der DB-Resilienz-Haertung nun identisch: WAL 8Gi,
max_slot_wal_keep_size 6GB, priorityClassName an cnpg-erp/cnpg-shared/mariadb-galera.

**MariaDB Galera (Spec live):**

| Cluster | priorityClassName |
|---------|-------------------|
| DEV  | eneg-stateful-critical |
| TEST | eneg-stateful-critical (15.07.) |
| PROD | eneg-stateful-critical (15.07.) |

**Bewertung / Nachziehen:**

| Einzelmassnahme | DEV | TEST | PROD | Nachziehen? | Risiko / Abhaengigkeit |
|-----------------|-----|------|------|-------------|------------------------|
| PriorityClass-Definition (`base/priorityclasses`) | vorhanden | erledigt 14.07. (App) | erledigt 15.07. (App) | **ERLEDIGT** | Muss existieren, BEVOR ein Pod sie referenziert, sonst wird der Pod nicht admittiert. **Reihenfolge-kritisch: zuerst App anlegen.** |
| `priorityClassName` an CNPG erp+shared | ja | erledigt 15.07. | erledigt 15.07. | **ERLEDIGT** | Haengt an PriorityClass-Definition |
| `priorityClassName` an MariaDB Galera | ja | erledigt 15.07. (IST, kein SST) | erledigt 15.07. (IST, kein SST) | **ERLEDIGT** | Rolling-Restart, IST/SST beobachten |
| `max_slot_wal_keep_size: 6GB` (erp+shared) | ja | erledigt 15.07. | erledigt 15.07. | **ERLEDIGT** | sighup-Reload, kein Restart |
| WAL-Volume 5Gi -> 8Gi | ja | erledigt 15.07. (Online-Resize) | erledigt 15.07. (Online-Resize) | **ERLEDIGT** | **KORREKTUR: live online-erweiterbar** (longhorn-db `allowVolumeExpansion: true`). CNPG 1.28.3 orchestriert WAL-PVC-Resize ueber `spec.walStorage.size` sequenziell. TEST+PROD 15.07. ohne Longhorn-Deadlock; Detach-Trick nicht noetig. PROD-shared-Volumes waren fast leer (~0,79 GB) -> Resize ganz ohne Eingriff. Deckel erst NACH Resize (~2Gi Puffer). |
| Alert `CnpgClusterNoPrimary` (`base/`) | ja | ja | ja | ERLEDIGT (base) | kommt automatisch mit |
| Alert `CnpgReplicationSlotInactive` (`base/`) | ja | ja | ja | ERLEDIGT (base) | kommt automatisch mit |

> **Kritische Abhaengigkeit:** `max_slot_wal_keep_size` (Deckel) und
> WAL-Volume-Groesse gehoeren zusammen. Der Deckel darf nie >= Volume-Groesse
> sein. Reihenfolge daher: erst WAL-Volume auf 8Gi (Online-Resize via
> `spec.walStorage.size`), dann 6GB-Deckel. Bei PROD-cnpg-shared (5Gi) ist der
> Resize zwingend vor dem Deckel.
>
> **KORREKTUR WAL-Resize-Methode (verifiziert TEST 15.07.2026):** Die urspruengliche
> Annahme "nur per Instanz-Recreate, NICHT live erweiterbar" stammt aus dem
> disk-full-Deadlock 29.06. (CNPG-Disk-Guard blockierte den Pod-Start). Im
> normalen (nicht-vollen) Zustand ist der Online-Resize der zuverlaessige Weg:
> `spec.walStorage.size` erhoehen, CNPG rollt die PVCs sequenziell, Longhorn
> expandiert online. In TEST liefen erp+shared ohne Deadlock durch; nur der
> jeweils letzte Node (FileSystemResizePending) brauchte einen Remount
> (Replica: Pod-Delete; Primary: Switchover). Detach-Trick (Runbook) war nicht
> noetig, bleibt aber Sicherheitsnetz.

> **Hinweis PROD cnpg-erp.yaml:** Das Manifest enthaelt `monitoring:` /
> `enablePodMonitor` doppelt (einmal true, einmal false). Kein Drift-Thema,
> aber bei Gelegenheit bereinigen (der zweite `false`-Block gewinnt).

### 5.4 Velero (echter Drift - hohe Prioritaet)  [P1 ERLEDIGT 14.07.2026]

> **Status 14.07.2026:** checksumAlgorithm-Fix + Resource-Limits auf TEST und
> PROD nachgezogen (NAS10/HTTP-Backend beibehalten, OF-2). Beide Cluster live
> verifiziert: BSL zeigt `checksumAlgorithm: ""` (`Available`), velero 2Gi /
> nodeAgent 1Gi aktiv, Test-Backup `Completed` ohne InvalidDigest (TEST 1472/1472
> in 7s, PROD 919/919 in 2s, je 0 errors/warnings). PROD hatte kein akutes
> InvalidDigest (Daily-Laeufe seit 08.07. alle Completed) - Fix dort praeventiv.
> NAS20-Migration bewusst NICHT hier, sondern gebuendelt mit P4. Doc-Ref:
> docs/phases/velero-aws-sdk-checksum-fix-dev.md (Abschnitt 8).

`environments/{dev,test,prod}/velero/values-override.yaml`:

| Aspekt | DEV | TEST | PROD | Nachziehen? |
|--------|-----|------|------|-------------|
| S3-Backend | NAS20 / HTTPS + CA-Bundle | NAS10 / HTTP skip-verify | NAS10 / HTTP skip-verify | JA (Teil 14x) |
| `checksumAlgorithm: ""` | gesetzt | gesetzt (14.07.) | gesetzt (14.07.) | ERLEDIGT |
| Resource-Limits (2Gi, OOM-Fix) | gesetzt | gesetzt (14.07.) | gesetzt (14.07.) | ERLEDIGT |
| nodeAgent-Limits | gesetzt | gesetzt (14.07.) | gesetzt (14.07.) | ERLEDIGT |
| Retention (TTL) | 120h (5d) | 336h (14d) | 336h (14d) | env-abhaengig pruefen |
| Schedule | 05:45 | 03:30 | 03:30 | NEIN (env, gestaffelt) |

**`checksumAlgorithm: ""` ist der wichtigste Punkt:** Ohne ihn schlagen Velero-
Backups gegen QNAP QuObjects mit `InvalidDigest` fehl (aws-sdk-go-v2 v1.30+
Trailing-Checksums). In DEV seit 19.05. gefixt und verifiziert, TEST+PROD offen.
Solange TEST/PROD auf NAS10/HTTP laufen, ist der Fix dort ebenso noetig (der
Bug ist backend-unabhaengig).

> **Wichtig (Helm-Listen-Merge):** `backupStorageLocation` ist eine YAML-Liste;
> Override ersetzt die ganze Liste. `checksumAlgorithm: ""` muss daher **im
> jeweiligen Env-Override** stehen, nicht nur in base. Ob TEST/PROD gleich auf
> NAS20 migriert werden oder erst nur den Checksum-Fix auf NAS10 bekommen, ist
> eine Freigabe-Entscheidung (siehe OF-2).

### 5.5 Monitoring (kube-prometheus-stack)

`environments/{dev,test,prod}/monitoring/values-override.yaml`:

| Aspekt | DEV | TEST | PROD | Nachziehen? |
|--------|-----|------|------|-------------|
| Prometheus PVC | 25Gi | 20Gi | 50Gi | NEIN (env-Dimensionierung) |
| Prometheus Memory-Limit 3Gi | ja | fehlt | fehlt | **JA** (TSDB-WAL-Deadlock-Schutz 21.06.) |
| retention 7d / retentionSize 12GB | ja | fehlt | fehlt | **JA** (Wert an PVC anpassen, nicht 1:1) |
| `enableRemoteWriteReceiver` | ja | nein | nein | NEIN (DEV-only, fuer alloy-vcenter) |
| eneg-s3-ca Volume + Thanos-Sidecar-Mount | ja | nein | nein | NEIN (DEV-only, NAS20; s. 5.6) |
| `KubeCPUOvercommit` disabled | ja | nein | nein | NEIN (env, 3x4 vCPU DEV) |
| `KubeJobFailed` disabled + Custom-Rule | ja | ja | ja | ERLEDIGT |
| Prometheus/Alertmanager `replicas: 1` | nein | ja | nein | NEIN (TEST-Migrations-Haertung) |
| AlertManager SMTP-from | -dev@ | -test@ | -prod@ | NEIN (env) |

**monitoring-alerts (Kustomize resources):** Alle drei ziehen
`base/monitoring/alert-rules` (dort die geteilten CNPG-/Backup-Regeln). Env-Zusatz:

| Datei | DEV | TEST | PROD | Nachziehen? |
|-------|-----|------|------|-------------|
| `prometheus-tsdb-health-*.yaml` (3 Alerts) | ja | nein | nein | **JA** (Schwellwerte an PVC anpassen; gehoert NICHT zu vcenter-Monitoring - s.u.) |
| `cnpg-podmonitors.yaml` | **nein** | ja | ja | NEIN (invertiert, gewollt: SSA-Workaround Learning #20 - DEV nutzt Operator-`enablePodMonitor`, TEST/PROD eigenstaendige PodMonitor-CRDs) |
| `kube-cpu-overcommit-dev.yaml` | ja | nein | nein | NEIN (env, Node-Groesse) |
| `backup-alerts-overdue-dev.yaml` (Patch 36h) | ja | nein | nein | GRENZFALL (DEV-Zeitfenster/idoit-Selector; ggf. env-angepasst nachziehen) |
| `vsphere-alerts-dev.yaml` + `vsphere-hosts-dashboard-cm.yaml` | ja | nein | nein | NEIN (DEV-only, gehoert zu alloy-vcenter) |
| `kube-job-failed-{env}.yaml` | ja | ja | ja | ERLEDIGT (je env) |

> **Klaerung TSDB-Health-Alerts (Frage Daniel, 14.07.):** Die drei Alerts
> `PrometheusTSDBCompactionsFailing`, `PrometheusTSDBWALCorruptions`,
> `PrometheusStorageFillingUp` gehoeren **NICHT** zum vcenter-Monitoring. Sie
> ueberwachen die Prometheus-EIGENE Datenbank (TSDB/WAL) und stammen aus dem
> TSDB-WAL-Deadlock-Vorfall 21.06.2026 (WAL-Korruption blockiert Kompaktierung
> -> PVC laeuft voll). Das kann jede Prometheus-Instanz treffen, unabhaengig von
> vcenter-Metriken. vcenter-spezifisch sind nur `enableRemoteWriteReceiver`
> (DEV-only) und `vsphere-alerts-dev.yaml` (DEV-only) - die sind hier NICHT
> gemeint. **Entscheidung: TSDB-Health-Alerts werden nach TEST + PROD nachgezogen**
> (Teil P3). `PrometheusStorageFillingUp` ist relativ (>80% PVC) und passt sich
> automatisch der jeweiligen PVC-Groesse an; die beiden anderen sind absolut und
> unkritisch portierbar.

### 5.6 Loki + Thanos - S3-Migration NAS10 -> NAS20 (Phase 14)

| Dienst | DEV | TEST | PROD | Nachziehen? |
|--------|-----|------|------|-------------|
| **Loki** S3 | NAS20/HTTPS + CA | NAS20/HTTPS + CA | NAS20/HTTPS + CA | **ERLEDIGT** (14a/b/c) |
| Loki Retention | 120h | 120h | 240h | NEIN (env gewollt) |
| Loki Compactor retention_enabled (base) | ja | ja | ja | ERLEDIGT (base) |
| **Thanos** objstore | NAS20/HTTPS + ca_file | NAS10/HTTP insecure | NAS10/HTTP insecure | **JA** (Thanos-Migration Phase 14 offen) |
| Thanos CA-Mount (compactor+storegateway) | ja | nein | nein | JA (Teil der Thanos-Migration) |

Loki ist vollstaendig auf NAS20 migriert (kein Drift mehr). **Thanos** ist der
verbliebene S3-Migrations-Rueckstand: TEST/PROD schreiben Bloecke noch auf
NAS10/insecure. Betrifft `monitoring-thanos/values-override.yaml` (CA-Mount) und
das Secret `thanos-objstore-config` (endpoint + insecure + ca_file).

### 5.7 Longhorn - Live-Settings (Nicht-GitOps-Drift)

`settings.longhorn.io` live:

| Setting | DEV | TEST | PROD | Nachziehen? |
|---------|-----|------|------|-------------|
| `replica-auto-balance` | least-effort | best-effort | best-effort | GRENZFALL (Phase-13-Haertung; laut Projektplan "nicht pauschal porten ohne Review") |
| `orphan-resource-auto-deletion` | replica-data | (leer) | (leer) | GRENZFALL (DEV raeumt Orphans automatisch) |
| Alle uebrigen (rebuild-limit=2, over-provisioning=200, priority-class, etc.) | identisch | identisch | identisch | ERLEDIGT |

Longhorn-Version v1.9.2, StorageClasses (longhorn / longhorn-db Retain /
longhorn-static) und `concurrent-replica-rebuild-per-node-limit=2` sind in allen
drei identisch. Der einzige echte Live-Unterschied ist `replica-auto-balance`
(Phase 13) - dieser liegt im DEV-Overlay `environments/dev/longhorn/values-override.yaml`
(DEV-only) und ist bewusst nicht in base, daher als eigene Review-Entscheidung
zu behandeln (Phase 13 DO-NOT-PORT-Hinweis).

---

## 6. Bewusst zurueckgestellt: Trivy + Kyverno (DEV-only)

> **Diese Komponenten sind KEIN nachzuziehender Drift. Sie sind bewusst nur in
> DEV aktiv und werden in diesem Angleich-Durchlauf ausgelassen. Ein spaeterer
> Drift-Check darf sie nicht als "vergessen" markieren.**

| Komponente | DEV-Version | TEST | PROD | Status |
|------------|-------------|------|------|--------|
| Trivy Operator | v0.30.1 (Chart trivy-operator 0.32.1) | nicht deployed | nicht deployed | bewusst DEV-only |
| Trivy Server (intern) | v0.69.3 (trivy-server-0, PVC 5Gi) | - | - | Teil von Trivy Operator |
| Kyverno | v1.17.1 (Chart kyverno 3.7.1) | nicht deployed | nicht deployed | bewusst DEV-only |
| Kyverno Policies (PSS) | Chart kyverno-policies 3.7.1 | nicht deployed | nicht deployed | bewusst DEV-only |

**Betroffene Dateien (nur DEV):**
- `environments/dev/infrastructure/trivy-operator-app.yaml`
- `environments/dev/infrastructure/kyverno-app.yaml`
- `environments/dev/infrastructure/kyverno-policies-app.yaml`
- `environments/dev/trivy-operator/values-override.yaml`
- `environments/dev/kyverno/values-override.yaml`
- `environments/dev/kyverno-policies/values-override.yaml`
- zugehoerige `base/trivy-operator/`, `base/kyverno/`, `base/kyverno-policies/`
  (in base vorhanden, aber von TEST/PROD nicht referenziert, da keine App)

**Kontext:** Phase 9 (Security) ist noch "in Arbeit". Kyverno laeuft in DEV im
Audit-Modus; Trivy Operator scannt passiv. Die Ausrollung nach TEST/PROD ist ein
eigenes, spaeter freizugebendes Vorhaben (inkl. Kyverno-Webhook-Hardening
Phase 13, das ebenfalls DEV-spezifisch ist). CrowdSec + Falco (Phase 9 Rest)
sind ueberall noch nicht vorhanden.

**Ebenfalls DEV-only, aber aus anderem Grund (nicht Security-Zurueckstellung):**
- `alloy-vcenter` (+secrets): vCenter-Monitoring laeuft **per Design** zentral
  nur aus DEV. Soll NIE nach TEST/PROD. Kein Drift.
- `registry` / Zot (+secrets): Phase 9a Etappe B (PROD-Zot + Cutover) noch offen.
  TEST pullt bewusst vom DEV-Zot mit. Eigener Rollout-Pfad, nicht Teil dieses
  Angleichs.

---

## 7. Priorisierte Nachzieh-Liste (Vorschlag)

Reihenfolge unter Beachtung DEV -> TEST -> PROD und der Abhaengigkeiten.
**Jeder Block einzeln, mit Verifikation, bevor der naechste folgt. Freigabe pro
Schritt durch Daniel.**

> **Verbindliche Reihenfolge (festgelegt Daniel, 14.07.2026) - je ein Thema pro
> Chat, jeweils neuer Chat:**
> 1. **Velero** (P1)  [ERLEDIGT 14.07.2026 - TEST + PROD, NAS10-Backend]
> 2. **DB-Resilienz-Haertung** (P2)  [ERLEDIGT 14./15.07.2026 - TEST + PROD]
> 3. **Prometheus** - Memory-Limit + Retention + TSDB-Health-Alerts (P3).
>    TSDB-Alerts gehoeren NICHT zum vcenter-Monitoring (s. Klaerung 5.6-Vorspann)
>    und werden nach TEST+PROD mitgenommen.
> 4. **Thanos** auf NAS20 umstellen (P4) - dabei pruefen, ob weitere Dienste noch
>    NAS10 -> NAS20 umzustellen sind (Backups etc., s. P4-Erweiterung).
> 5. **Longhorn `replica-auto-balance`** (P5) - erst im Anschluss diskutieren.

### Prioritaet 1 - Backup-Integritaet (hoechstes Risiko bei Nichtstun)

**P1: Velero checksumAlgorithm-Fix** (Abschnitt 5.4)  [ERLEDIGT 14.07.2026]
- Ohne Fix schlagen Velero-Backups gegen QuObjects fehl -> keine verlaesslichen
  Cluster-Backups in TEST/PROD.
- Umfang: `checksumAlgorithm: ""` + Resource-Limits in
  `environments/{test,prod}/velero/values-override.yaml`.
- Entscheidung noetig: nur Checksum-Fix auf NAS10 ODER gleich NAS20-Migration
  mitziehen (OF-2).
- **Umgesetzt 14.07.2026 (OF-2 = nur Checksum-Fix + Limits auf NAS10):** TEST +
  PROD Overrides ergaenzt, ArgoCD Hard-Refresh + rollout restart, beide live
  verifiziert (BSL `checksumAlgorithm: ""` Available, velero 2Gi/nodeAgent 1Gi,
  Test-Backup Completed ohne InvalidDigest). PROD-Cleanup: PartiallyFailed-Lauf
  07.07. (Reaktivierungs-Artefakt) entfernt. NAS20-Migration verschoben auf P4.

### Prioritaet 2 - DB-Resilienz (Schutz vor WAL-Deadlock / Verdraengung)

> **Status: P2 VOLLSTAENDIG ERLEDIGT (TEST + PROD, 14./15.07.2026).** Alle drei
> Cluster identisch gehaertet. Detaildoku:
> `docs/phases/resilienz-haertung-wal-deadlock-dev.md` (TEST- + PROD-Rollout-Abschnitt).

Reihenfolge je Umgebung zwingend:

**P2.1: PriorityClass-App anlegen** (Voraussetzung fuer alles Weitere)
- Neue Datei `environments/{test,prod}/infrastructure/priorityclasses-app.yaml`
  (analog DEV, zeigt auf `base/priorityclasses/`).
- Verifizieren: PriorityClass `eneg-stateful-critical` im Cluster vorhanden.
- **TEST erledigt 14.07.:** App `priorityclasses` Synced/Healthy, PriorityClass
  (value 900000000) im Cluster vor Workload-Referenz verifiziert.
- **PROD erledigt 15.07.:** ebenso. Hinweis: `prod-infrastructure` hat KEINEN
  Auto-Sync (manueller Sync noetig); die Child-App `priorityclasses` bringt aber
  selbst automated/selfHeal mit.

**P2.2: WAL-Volume-Resize 5Gi -> 8Gi** (wo noetig: TEST erp+shared, PROD shared)
- **KORREKTUR:** live online-erweiterbar via `spec.walStorage.size` (nicht per
  Recreate). CNPG 1.28.3 rollt die PVCs sequenziell, Longhorn expandiert online.
- **TEST erledigt 15.07.:** shared zuerst, dann erp; beide ohne Longhorn-Deadlock.
  Letzter Node je Cluster brauchte Remount (shared: Primary-Switchover; erp:
  Replica-Pod-Delete).
- **PROD erledigt 15.07.:** nur cnpg-shared (erp schon 8Gi). Volumes fast leer
  (~0,79 GB) -> alle drei PVCs ohne jeden Eingriff auf 8Gi (kein Switchover/Delete
  noetig, CNPG loeste FileSystemResizePending selbst auf).

**P2.3: `max_slot_wal_keep_size: 6GB`** (erst NACH Resize)
- In `cnpg-{erp,shared}.yaml` der Umgebung. sighup-Reload.
- **TEST erledigt 15.07.:** live in beiden Clustern (`SHOW` = 6GB), kein Restart.
- **PROD erledigt 15.07.:** shared gesetzt (`SHOW`=6GB); erp hatte 6GB schon.

**P2.4: `priorityClassName` an CNPG (erp+shared) und MariaDB Galera**
- Loest Rolling-Restart aus -> engmaschig beobachten (Galera: IST/SST).
- **TEST erledigt 15.07.:** erp+shared+galera, alle Pods priority 900000000.
  Galera per IST (kein SST), galera-1 ohne Memory-Probleme.
- **PROD erledigt 15.07.:** erp+shared+galera, alle Pods 900000000. Galera per
  IST (kein SST), galera-1 unauffaellig. CNPG via `kubectl cnpg restart` (Primary
  erp schnell, shared laenger im Terminating, loeste sich selbst).
- **Lesson:** CNPG loest bei priorityClass-Aenderung KEINEN Auto-Restart aus ->
  expliziter `kubectl cnpg restart <cluster>` noetig. Primary-Schritt kann lange
  im Terminating stehen (30-Min-Grace), loest sich aber selbst - nicht vorschnell
  force-deleten. Galera-Operator restartet dagegen automatisch
  (ReplicasFirstPrimaryLast).

> Der zugehoerige Alert `CnpgClusterNoPrimary` ist via base bereits ueberall aktiv.
> TEST+PROD-Verifikation 15.07.: beide Cluster je Umgebung mit Primary, alle
> Replication-Slots aktiv (`pg_replication_slots.active = t`) -> Alerts feuern
> nicht faelschlich.

### Prioritaet 3 - Monitoring-Resilienz

**P3.1: Prometheus Memory-Limit 3Gi + retention/retentionSize** [ERLEDIGT 15.07.]
- In `environments/{test,prod}/monitoring/values-override.yaml`.
- retentionSize an jeweilige PVC-Groesse anpassen (TEST 20Gi, PROD 50Gi), NICHT
  DEV-Wert 12GB uebernehmen.
- **Finale Werte (Freigabe Daniel 15.07., siehe OF-4):** retentionSize TEST 14GB
  (~70% von 20Gi), PROD 38GB (~76% von 50Gi). retention 15d in TEST+PROD BELASSEN
  (env-spezifisch; Thanos haelt Langzeit-Historie, retentionSize ist der harte
  Deckel). Memory einheitlich 3Gi/1Gi in allen drei Clustern.
- **TEST erledigt 15.07.:** CR live retention=15d/retentionSize=14GB/mem=3Gi/1Gi.
  Pod-Neustart sauber (3/3, 0 Restarts, kein OOMKill).
- **PROD erledigt 15.07.:** CR live retention=15d/retentionSize=38GB/mem=3Gi/1Gi.
  Pod-Neustart sauber (3/3, 0 Restarts); Mem nach WAL-Replay ~1GB, Limit 3Gi mit
  reichlich Puffer (alte Grenze 2Gi bei ~1,7GB Normallast war knapp).
- **Lesson:** retentionSize schuetzt nur persistierte Bloecke, NICHT das WAL - der
  21.06.-Deadlock (WAL-Korruption -> blockierte Kompaktierung) wird dadurch NICHT
  verhindert. Der eigentliche Frueherkennungs-Schutz sind die P3.2-Alerts;
  retentionSize deckt den anderen Fall ab (retention-getriebenes PVC-Volllaufen).
  retention/Memory-Aenderung loest Prometheus-Pod-Neustart aus (StatefulSet, kurze
  Scrape-Luecke) - Hard-Refresh der ArgoCD-App `monitoring` noetig (Helm-Sub-Map).

**P3.2: `prometheus-tsdb-health` Alerts nach TEST/PROD** (bestaetigt Daniel 14.07.) [ERLEDIGT 15.07.]
- Gehoert NICHT zu vcenter-Monitoring (s. 5.6-Vorspann) - ueberwacht die
  Prometheus-eigene TSDB. Wird nach TEST+PROD mitgenommen.
- Datei aus DEV ableiten, Schwellwert-PVC-Bezug pruefen, in
  `monitoring-alerts/kustomization.yaml` als resource ergaenzen.
- **TEST+PROD erledigt 15.07.:** `prometheus-tsdb-health-{test,prod}.yaml` aus DEV
  abgeleitet (3 Alerts: CompactionsFailing, WALCorruptions, StorageFillingUp), je
  in `monitoring-alerts/kustomization.yaml` ergaenzt. Live verifiziert: Regelgruppe
  geladen, alle Alerts `health=ok` und `state=inactive` (kein Fehlalarm).
- **Lesson:** Der PVC-Selektor `prometheus-.*` und der Job-Filter
  `job="kube-prometheus-stack-prometheus"` sind ohne Anpassung portierbar (Release-
  Name in allen drei Clustern identisch). Der Job-Filter ist ZWINGEND: die Metrik
  `prometheus_tsdb_compactions_total` existiert auch mit `job="thanos-compactor"` -
  ohne Filter wuerde der Compactor mit-alarmieren.

### Prioritaet 4 - S3-Migration Thanos + NAS10->NAS20-Gesamtpruefung (Phase 14)

**P4: Thanos objstore NAS10 -> NAS20** (TEST, dann PROD)
- `monitoring-thanos/values-override.yaml` (CA-Mount compactor+storegateway) +
  Secret `thanos-objstore-config` (endpoint nas20, insecure:false, ca_file).
- CA-Bundle-Secret `eneg-s3-ca` muss in TEST/PROD Namespace `monitoring`
  vorhanden sein (in DEV vorhanden; fuer TEST/PROD anlegen - analog Loki 14b/c).
- Analog zur bereits abgeschlossenen Loki-Migration.

**P4-Erweiterung: Welche Dienste liegen noch auf NAS10? (Bestandsaufnahme bei P4-Start)**

Frage Daniel: "pruefen ob noch andere Sachen von NAS10 zu NAS20 umgestellt werden
muessen (z.B. Backups oder weiteres)". Aktueller Stand der S3-Backends
(14.07.2026, noch NICHT final auf NAS20-Migrationsentscheidung geprueft):

| Dienst | Backend aktuell | Migrationsstatus |
|--------|-----------------|------------------|
| Loki | NAS20/HTTPS | migriert (14a/b/c) |
| Thanos | NAS10 (TEST/PROD), NAS20 (DEV) | P4 - jetzt dran |
| Registry/Zot (nas10 k8s-{env}-registry) | NAS10 | offen - an Phase 9a gekoppelt, separat |
| Velero (k8s-{env}-velero) | NAS10 (DEV bereits NAS20) | via P1/OF-2 entscheiden |
| CNPG WAL/Backup (k8s-{env}-postgres-wal/-backup) | NAS10 | NICHT Teil dieses Angleichs - eigene Bewertung |
| MariaDB Physical (k8s-{env}-mariadb-backup) | NAS10 | NICHT Teil dieses Angleichs |
| Garage-Backup, Odoo, i-doit (rclone) | NAS10 | NICHT Teil dieses Angleichs |

> **Empfehlung:** Bei P4-Start eine kurze fokussierte NAS10->NAS20-Gesamtinventur
> machen (welche Buckets/Secrets/values, welche mit CA-Bundle-Bedarf), dann pro
> Dienst entscheiden. Thanos ist der unmittelbare Drift-Punkt; die restlichen
> NAS10-Dienste sind in allen drei Clustern GLEICH auf NAS10 (also kein Drift
> zwischen den Envs, sondern eine strategische Migrationsfrage - Punkt D aus den
> NAS10-Stabilitaets-Diskussionen). Diese als eigenes Vorhaben nach dem Angleich
> behandeln, sofern nicht anders freigegeben.

### Prioritaet 5 - Grenzfaelle (nur nach expliziter Freigabe)

- **Longhorn `replica-auto-balance` least-effort** (Phase 13): laut Projektplan
  "DO-NOT-PORT pauschal ohne getrennte Review-Session". Bewusste Entscheidung.
- **backup-alerts-overdue-Patch** (36h/idoit): env-Anpassung noetig, falls
  gewuenscht.
- **Longhorn `orphan-resource-auto-deletion`**: klein, optional.

---

## 8. Offene Fragen / zu klaeren

**OF-1: Branch-Strategie.** Alle drei Cluster haengen an `main`; die Branches
`test`/`prod` existieren auf origin nicht mehr. ADR-002 (Branch-per-Environment)
ist damit faktisch ausser Kraft. Zu entscheiden: Soll das so bleiben (dann ADR-002
aktualisieren/zurueckziehen und dokumentieren, dass base-Aenderungen sofort alle
Cluster treffen) oder Branch-Strategie wiederherstellen? **Das hat direkten
Einfluss darauf, wie "Promotion" beim Nachziehen ueberhaupt funktioniert** - bei
Single-Branch wirkt jeder Push auf `environments/dev|test|prod/**` nur auf das
jeweilige Overlay, aber jede `base/`-Aenderung sofort ueberall.

**OF-2: Velero TEST/PROD - Ziel-Backend.**  [ENTSCHIEDEN + ERLEDIGT 14.07.2026]
Nur Checksum-Fix auf NAS10 (schnell,
kleiner Eingriff) ODER gleich NAS20-Migration mitnehmen (konsistenter mit
Loki/Thanos-Richtung, aber CA-Bundle-Secret + Bucket noetig)? Empfehlung:
mind. Checksum-Fix sofort (P1), NAS20 optional im Zug von P4.

**OF-3: WAL-Volume-Resize.** Recreate von cnpg-Instanzen in TEST/PROD zieht
kurzzeitigen Rebuild/Basebackup nach sich. Wartungsfenster gewuenscht? Reihenfolge
shared-zuerst-oder-erp-zuerst? (Empfehlung: das jeweils weniger kritische zuerst
als Generalprobe.)

**OF-4: retention/retentionSize-Werte** fuer Prometheus TEST (20Gi) und PROD
(50Gi) festlegen (DEV: 7d/12GB bei 25Gi). Vorschlag TEST 7d/10GB, PROD 15-20d/40GB
- final durch Daniel. -- ENTSCHIEDEN + ERLEDIGT 15.07.2026: retentionSize TEST
  14GB, PROD 38GB; retention 15d in beiden BELASSEN (nicht auf DEV-7d angeglichen -
  env-spezifisch, Thanos haelt Langzeit); Memory 3Gi/1Gi einheitlich. Siehe P3.1.

**OF-5: PROD cnpg-erp.yaml Doppel-`enablePodMonitor`** bei Gelegenheit bereinigen
(kein Drift, nur Hygiene). -- ERLEDIGT 14.07.2026: Doppel-`monitoring:`-Block in
allen vier betroffenen Dateien (test+prod, erp+shared) entfernt, `false`
beibehalten. Siehe incidents/2026-07-14-nas-reboot-verifikation-cnpg-backup-cleanup.md.

**OF-6: Longhorn Phase-13-Settings** (`replica-auto-balance` least-effort):
nach TEST/PROD portieren oder bewusst DEV-only lassen? (Projektplan-Hinweis:
getrennte Review.)

**OF-7: Doku-Kommentare** in `test/prod/.../cnpg-operator-app.yaml` ("v1.28.1")
an Live-Stand 1.28.3 angleichen (Hygiene, kein Funktionsdrift).

---

## 9. Zusammenfassung der wichtigsten Drift-Punkte

**Struktur:** Ein Branch (`main`) fuer alle drei Cluster. base-Aenderungen sind
ueberall sofort wirksam; echter Drift steckt nur in den env-Overlays.

**Kein Versionsdrift** bei Helm-Charts/Operatoren - alles ueber base identisch.

**Echter, nachzuziehender Drift (priorisiert):**
1. **Velero** checksumAlgorithm-Fix + Resource-Limits fehlen in TEST+PROD (Backup-Integritaet, hoch). [ERLEDIGT 14.07.]
2. **DB-Resilienz-Haertung** (29.06.): PriorityClass-App + priorityClassName
   (CNPG+Galera), max_slot_wal_keep_size, WAL-Volume 8Gi. [ERLEDIGT 14./15.07. -
   TEST+PROD; alle drei Cluster identisch. WAL-Resize erwies sich als online
   moeglich (Korrektur der "nur Recreate"-Annahme).]
3. **Prometheus** Memory-Limit 3Gi + retention und die TSDB-Health-Alerts nur in DEV.
   [ERLEDIGT 15.07. - TEST+PROD: retentionSize 14GB/38GB ergaenzt, retention 15d
   belassen, Memory 3Gi/1Gi einheitlich, TSDB-Health-Alerts portiert und live
   verifiziert (inactive/health=ok).]
4. **Thanos** S3 noch NAS10/insecure in TEST/PROD (Loki bereits auf NAS20 - erledigt).
5. Grenzfaelle: Longhorn `replica-auto-balance` (Phase 13), backup-overdue-Patch.

**Bewusst ausgenommen (kein Drift):** Trivy, Kyverno, Kyverno-Policies
(zurueckgestellt); alloy-vcenter (DEV-only per Design); Registry/Zot (Phase 9a
Etappe B offen).

**Naechster Schritt:** Daniel legt Reihenfolge + Freigaben fest. Umsetzung dann
je Schritt DEV-Stand -> TEST -> PROD nach etabliertem Workflow (Claude: Dateien
via Desktop-Commander; Daniel: git commit/push, ArgoCD-Sync, Server-Zugriffe).

---

*Analyse-Datei, urspruenglicher Stand 14.07.2026. Fortlaufend aktualisiert bei
Umsetzung der Nachzieh-Schritte: P1 (Velero) erledigt 14.07.; P2 (DB-Resilienz)
erledigt 14./15.07.; P3 (Monitoring-Resilienz) erledigt 15.07. Offen: P4 (Thanos
NAS20), P5 (Grenzfaelle).*
