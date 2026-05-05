# Phase 11 - Rolling OS-Update DEV Cluster - Handoff & Lessons Learned

**Datum:** 05.05.2026  
**Cluster:** k8s-dev (DEV)  
**Status:** ⚠️ Mit Auflagen abgeschlossen — kritische Lessons Learned vor TEST/PROD umzusetzen

---

## 1. Ergebnis im Überblick

### Update-Status

| Node | OS-Update | Reboot | Verify | Anmerkung |
|------|-----------|--------|--------|-----------|
| k8s-dev-23 | ✅ erfolgreich | ✅ | ✅ | 35 Pakete aktualisiert |
| k8s-dev-22 | ✅ erfolgreich | ✅ | ✅ | 36 Pakete + curl-Security |
| k8s-dev-21 | ✅ APT durch + Reboot durch | ✅ | ❌ Verify fehlgeschlagen | 35 Pakete; **Verify failed wegen DNS-Outage**, technisch aber erfolgreich aktualisiert |

**Kernel:** Auf DEV ist KEIN neuer Kernel im Repository verfügbar — alle Nodes bleiben bei `6.8.0-71-generic`. Das ist erwartet (DEV-Sources liegen noch bei -71, TEST/PROD haben ggf. -110 ausgerollt). Aktualisiert wurden Userspace-Pakete (systemd, apparmor, snapd, open-vm-tools, netplan, curl, etc.).

### End-Zustand des Clusters

- ✅ 3/3 Nodes Ready
- ✅ CNPG cnpg-erp: 3/3 healthy, primary `cnpg-erp-4` (k8s-dev-23)
- ✅ CNPG cnpg-shared: 3/3 healthy, primary `cnpg-shared-2` (k8s-dev-22)
- ✅ MariaDB Galera: alle 3 Pods Running
- ✅ Alle ImagePull-Probleme bereinigt
- ✅ Alle Maintenance-Modes (CNPG nodeMaintenanceWindow, Longhorn drain-policy, Galera PDB) zurückgesetzt

---

## 2. Was wurde technisch implementiert

Diese Session hat das **lehrbuchkonforme Drain-Verhalten** im Ansible-Playbook implementiert. Vorher hat das Playbook beim Drain mit PDB-Konflikten geblockt (cnpg-erp-PDB + Longhorn instance-manager-PDB).

### Neue Tasks im `rolling_os_update`-Role

**`tasks/pre_drain_prep.yml`** (neu, ~243 Zeilen):
- CNPG: `nodeMaintenanceWindow.inProgress=true` für alle Cluster mit Pods auf der Ziel-Node (Vendor-Empfehlung: https://cloudnative-pg.io/docs/1.28/kubernetes_upgrade/). Hebt PDB temporär auf, `reusePVC=true` lässt Pods auf Node-Rückkehr warten — perfekt für strict-local Volumes.
- Longhorn: `node-drain-policy` temporär `block-if-contains-last-replica` → `allow-if-replica-is-stopped` (https://longhorn.io/docs/1.11.0/maintenance/maintenance/).
- MariaDB Galera: PDB `minAvailable` temporär auf `0`, falls 2+ Galera-Pods auf der Ziel-Node liegen (Galera hat aktuell kein Anti-Affinity).

**`tasks/post_drain_cleanup.yml`** (neu, ~132 Zeilen):
- Setzt alle drei Maintenance-Modes nach erfolgreichem Verify zurück.
- Original-Werte werden in `pre_drain_prep` als Facts gespeichert.

### Bug-Fixes (über die Session)

1. **drain.yml**: Jinja-Filter `last(5)` ist ungültig — ersetzt durch `length` + `last` (ohne Argument).
2. **cnpg_failover.yml**: `kubectl --context X cnpg promote` ist falsch — bei kubectl-Plugins müssen Flags **NACH** dem Plugin-Namen stehen: `kubectl cnpg --context X promote`.
3. **defaults/main.yml**: KUBECONFIG explizit auf Play-Ebene (`environment: KUBECONFIG: ...`) für `delegate_to: localhost` aus SSH-Plays.
4. **Drain-Timeout** auf 900s erhöht (Sicherheitsmarge).

### Drain-Zeiten mit den neuen Tasks

| Node | Drain-Dauer | Vorher (gefailt) |
|------|-------------|------------------|
| k8s-dev-23 | 22-31s | 600s Timeout |
| k8s-dev-22 | 1:32 min | - |
| k8s-dev-21 | 1:16 min | - |

→ Maintenance-Strategy funktioniert wie erwartet.

---

## 3. Der unerwartete Vorfall — kaskadierender Cluster-Ausfall

### Symptom

Während des Updates von k8s-dev-21 fiel der Cluster in einen partiellen Ausfall:
- CNPG-Operator: `Cluster cannot proceed to reconciliation due to an error while interacting with plugins`
- mariadb-galera-0 + galera-2: `Init:0/1`, Volume-Attach-Fehler
- cnpg-shared-3: `1/2 Unknown`, postgres-Container terminated
- ArgoCD: alle Apps `Sync=Unknown`
- Mehrere Pods in `ImagePullBackOff` (alertmanager, blackbox-exporter, argocd-repo-server)

### Root Cause Analyse

Die Ursache war eine **Kette von zwei Single-Points-of-Failure**:

**SPOF #1: CoreDNS hat nur 1 Replica im DEV-Cluster**

- K3s installiert CoreDNS mit `replicas: 1` als Default.
- Beim Drain von k8s-dev-22 wurde der CoreDNS-Pod auf eine andere Node verschoben, die das CoreDNS-Image (`rancher/mirrored-coredns-coredns:1.14.1`) NICHT im containerd-Cache hatte.

**SPOF #2: Zot-Mirror OnDemand-Sync hängt bei nicht-cached Images**

- Containerd ist konfiguriert, alle docker.io-Pulls über `registry-dev.eneg.de` (Zot) zu mirrorn.
- Zot OnDemand-Sync für Multi-Arch-Manifeste kann mehrere Minuten dauern (siehe Memory: alpine:3 = 6:34 min).
- Containerd cancelt nach 30-60s mit "context canceled".
- → CoreDNS Pod blieb permanent in `ImagePullBackOff` (über 1 Stunde lang).

**Folgen (die Kette):**
1. CoreDNS down → keine Service-Resolution im Cluster.
2. Longhorn CSI-Plugin kann `longhorn-backend` Service nicht auflösen → in CrashLoopBackOff (53 Restarts).
3. Volume-Attach für mariadb-galera-Pods auf k8s-dev-21 schlägt fehl: `node k8s-dev-21 not found` (Longhorn Node-CR konnte nicht synchronisieren).
4. CNPG-Operator kann `barman-cloud` Plugin-Service nicht auflösen → Reconciliation blockt.
5. cnpg-shared-3 postgres-Container terminated, kein Restart möglich (Operator macht keine Aktion ohne Plugin).
6. argocd-repo-server, alertmanager, blackbox-exporter scheitern an Image-Pull → `ImagePullBackOff`.

### Die Heilung (sanfte Reparatur, ohne Snapshot-Rollback)

1. `cnpg-shared.spec.nodeMaintenanceWindow.inProgress=false` (manuell, weil Post-Cleanup nie erreicht wurde).
2. CNPG-Operator + Plugin neu starten (`rollout restart deployment` in `cnpg-system`).
3. **CoreDNS-Pod gelöscht** → Re-Schedule auf k8s-dev-21 (Image war dort cached) → sofort 1/1 Running.
4. Longhorn CSI-Plugin auf k8s-dev-21 gelöscht (war in CrashLoopBackOff durch DNS-Outage) → frischer Start nach DNS verfügbar.
5. CNPG-Operator hat danach automatisch:
   - cnpg-shared-4 als Ersatz erstellt (3/3 wieder erreicht).
   - cnpg-shared-3 als zombie aufgeräumt (manuell mit `--force --grace-period=0`).
6. mariadb-galera-0 + galera-2 haben sich nach CSI-Plugin-Recovery automatisch Volumes re-attached.
7. argocd-repo-server, alertmanager: per delete → Re-Schedule auf Node mit cached Image.

**Recovery-Dauer:** ~30 Min  
**Datenverlust:** keiner  
**Snapshot-Rollback:** nicht erforderlich

---

## 4. Lessons Learned — KRITISCH vor TEST/PROD

### 🔥 LL #1: CoreDNS HA aufbauen (HÖCHSTE PRIORITÄT)

**Problem:** K3s-Default ist 1 CoreDNS-Replica → Single Point of Failure.

**Recherche-Ergebnis (05.05.2026):** K3s hat **keinen offiziellen Konfig-Mechanismus** für CoreDNS-Replicas — bekannter offener Issue seit 2020 (k3s-io/k3s#1606). Die `coredns-custom` ConfigMap erlaubt nur Corefile-Anpassungen, NICHT Replica-Anzahl/Affinity. Direkte Deployment-Patches werden vom K3s-Addon-Controller wieder zurückgesetzt.

**Einzige stabile Lösung — Option C2 (offiziell laut K3s-Docs):**
1. K3s mit `--disable=coredns` auf allen 3 Mastern starten (sequenziell, mit kurzen DNS-Lücken).
2. CoreDNS via ArgoCD-managed Helm-Chart deployen (3 Replicas + Anti-Affinity + topologySpreadConstraints).
3. Reihenfolge muss exakt stimmen: erst eigener CoreDNS auf, dann K3s-Addon ab.

**Aufwand:** 1-2 Stunden, in eigener konzentrierter Session.

**Vor TEST/PROD-Update zwingend!**

### 🔥 LL #1b: Zot Container Registry HA aufbauen (HÖCHSTE PRIORITÄT)

**Problem:** Zot läuft als StatefulSet mit nur 1 Replica. Beim Drain der Zot-Node (oder Reboot) ist der Mirror für 30-60s nicht erreichbar. Wenn gleichzeitig ein anderer Pod migriert und ein nicht-cached Image braucht → kaskadierender ImagePullBackOff (siehe Vorfall in Abschnitt 3).

**Backend-Architektur ermöglicht Multi-Replica:**
- Storage: S3 auf NAS10 (Bucket `k8s-{env}-registry`)
- Multi-Replica auf gleichem Bucket = unproblematisch (Image-Layer sind immutable)
- Lokale PVCs sind nur Cache + Sync-Tmp

**Maßnahme:** In `kubernetes/base/registry/values.yaml` (oder DEV-Override):
```yaml
replicaCount: 3

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: zot
              app.kubernetes.io/instance: registry
          topologyKey: kubernetes.io/hostname

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: zot
        app.kubernetes.io/instance: registry
```

**Aufwand:** ~30 Min Implementierung + 10-15 Min Wartezeit für Pod-Spinup mit S3-Backend-Scan.

**Storage-Impact:** +20 GB Longhorn pro Cluster (3× 10Gi PVC statt 1×).

### 🔥 LL #2: Zot Image Pre-Warming

**Problem:** Bei jedem Pod-Reschedule auf einer neuen Node, die ein Image nicht im Cache hat, wird über Zot gepullt. Zot OnDemand-Sync hängt bei multi-arch manifests.

**Maßnahme — Vor jedem Rolling-OS-Update:**
1. Liste aller im Cluster aktiv genutzten Images sammeln.
2. Sicherstellen, dass diese im Zot-Cache vorhanden sind (nicht nur als Sync-Konfiguration, sondern wirklich gepulled).
3. Bei Bedarf manuell pre-pullen via `s3cmd` oder anderes auf Zot-Backend.

**Alternative (kurzfristig):** In Zot `OnDemand`-Sync deaktivieren und stattdessen periodischen Sync für die wichtigen Repos einrichten.

### 🔥 LL #2b: imagePullPolicy=Always verstärkt das Zot-Problem

**Problem:** Container mit `imagePullPolicy: Always` zwingen containerd zu jedem Pod-Start einen frischen Pull über Zot, auch wenn das Image bereits im containerd-Cache liegt. Bei Zot-Hängen → sofortiger ImagePullBackOff.

**Beispiel aus dieser Session:** argocd-repo-server lief in ImagePullBackOff trotz vorhandenem Image, weil imagePullPolicy=Always. InitContainer mit gleichem Image (IfNotPresent) liefen problemlos.

**Bestandsaufnahme im DEV-Cluster — Container mit imagePullPolicy=Always:**
- argocd-application-controller (quay.io/argoproj/argocd:v3.3.0)
- argocd-applicationset-controller (quay.io/argoproj/argocd:v3.3.0)
- argocd-dex-server (ghcr.io/dexidp/dex:v2.43.0)
- argocd-notifications-controller (quay.io/argoproj/argocd:v3.3.0)
- argocd-redis (public.ecr.aws/docker/library/redis:8.2.3-alpine)
- argocd-repo-server (quay.io/argoproj/argocd:v3.3.0)
- argocd-server (quay.io/argoproj/argocd:v3.3.0)
- idoit (ghcr.io/dhenkeeneg/idoit-open:37)
- it-info-versand (ghcr.io/dhenkeeneg/eneg-it-info-versand:de4d0c0)

**Maßnahme:**
- Bei festen Tags ist `IfNotPresent` semantisch korrekt — `Always` macht nur bei mutable Tags wie `latest` Sinn.
- Helm-Values der ArgoCD-, idoit- und it-info-versand-Apps anpassen (`imagePullPolicy: IfNotPresent`).
- Im Repo unter `environments/dev/apps/.../values.yaml` und entsprechend für TEST/PROD.

**Root-Cause-Behebung:** Wenn Zot Pre-Warming (LL #2) sauber funktioniert, ist `Always` zwar weniger problematisch, aber `IfNotPresent` bleibt die richtige Wahl.

### 🔥 LL #3: Kritische Helm-Charts haben CoreDNS-Abhängigkeit

**Beobachtet:** Longhorn, CNPG, ArgoCD, Velero, Monitoring — alle brauchen DNS für interne Service-Resolution. Bei DNS-Outage kaskadiert das.

**Maßnahme:** 
- DNS-Resilience-Tests in den Pre-Checks ergänzen.
- Optional: Pod-Level DNS-Cache (NodeLocalDNS) deployen, der als zusätzliche Resilience-Schicht fungiert.

### 🔥 LL #4: MariaDB Galera Anti-Affinity einführen

**Beobachtet:** galera-0 + galera-2 lagen beide auf k8s-dev-21. PDB mit minAvailable=50% blockiert Drain wenn 2+ Pods betroffen.

**Aktuelle Lösung:** Playbook patcht PDB temporär auf 0.

**Strategische Lösung:** podAntiAffinity (preferred) für Galera-StatefulSet → Pods werden gleichmäßiger verteilt → reguläre Drain-Strategie genügt → bessere HA bei Hardware-Failures.

**Migration:** Erfordert Volume-Replan (strict-local!) — separates Projekt.

### LL #5: Pre-Drain Image-Verfügbarkeitscheck

**Idee:** Im `pre_drain_prep.yml` einen Task ergänzen, der prüft:
- Welche Pods werden durch den Drain auf welche Nodes migrieren?
- Sind die benötigten Images auf den Ziel-Nodes im containerd-Cache verfügbar?
- Falls nicht: Warnung ausgeben (nicht blockieren) und Image pre-pull triggern.

### LL #6: Verify-Phase robuster machen

**Beobachtet:** "Warten bis alle CNPG Cluster wieder healthy" wartete 30 Retries × 10s = 5 min, dann gefailt. Keine differenzierte Fehlermeldung warum.

**Maßnahme:**
- Bei Fail mehr Diagnose-Output (Pod-Status, Plugin-Pod-Status, DNS-Test).
- Optional: Differenzierter Status — `Cluster cannot proceed... plugins` ist anders als `unhealthy`. Bei Plugin-Issues evtl. Plugin neu starten als Auto-Heal.

---

## 5. Action Items

### Vor TEST-Update zwingend (Top-Priorität)

- [ ] **CoreDNS HA**: 2-3 Replicas mit Anti-Affinity. Manifest erstellen, in `base/coredns-ha-patch.yaml` (oder analog) ablegen, ArgoCD-managed.
- [ ] **Zot Image Pre-Warming**: Liste aller aktiven Images extrahieren + Pre-Sync-Skript erstellen. Vor jedem Rolling-Update ausführen.
- [ ] **imagePullPolicy auf IfNotPresent umstellen** für die 9 betroffenen Container in ArgoCD/idoit/it-info-versand. Helm-Values im Repo anpassen, alle Environments.
- [ ] **Test auf DEV**: CoreDNS HA + Zot Pre-Warm + imagePullPolicy validieren bevor TEST/PROD angefasst wird. Idempotenter Re-Run von 08-rolling-os-update auf DEV als Smoke-Test.

### Mittelfristig (kann nach TEST/PROD)

- [ ] **MariaDB Galera Anti-Affinity** einführen (separates Projekt, betrifft Volume-Strategie).
- [ ] **NodeLocalDNS** als zusätzliche DNS-Resilience-Schicht prüfen.
- [ ] **Pre-Drain Image-Verfügbarkeitscheck** ins Playbook integrieren.
- [ ] **Verify-Phase** mit differenzierten Diagnose-Outputs ausbauen.

### Bug-Fixes (gelöst, im Repo)

- [x] `drain.yml`: `last(5)` → `last` + `length`
- [x] `cnpg_failover.yml`: kubectl-Plugin-Flag-Reihenfolge
- [x] `defaults/main.yml`: KUBECONFIG-Setup
- [x] Drain-Timeout 600s → 900s
- [x] `pre_drain_prep.yml` + `post_drain_cleanup.yml` neu erstellt

### Recovery-Tools für die Toolbox

Während dieser Session als bewährte Recovery-Schritte etabliert:

```bash
# CNPG Operator + Plugin neu starten
kubectl rollout restart deployment cnpg-cloudnative-pg cnpg-barman-plugin-plugin-barman-cloud -n cnpg-system

# Maintenance-Mode für CNPG-Cluster zurücksetzen
kubectl patch cluster.postgresql.cnpg.io <name> -n databases --type=merge \
  -p '{"spec":{"nodeMaintenanceWindow":{"inProgress":false,"reusePVC":true}}}'

# Longhorn drain-policy zurücksetzen
kubectl patch settings.longhorn.io node-drain-policy -n longhorn-system --type=merge \
  -p '{"value":"block-if-contains-last-replica"}'

# Hängenden Pod hart entfernen
kubectl delete pod <name> -n <ns> --grace-period=0 --force
```

---

## 6. Snapshots (offen)

Diese Snapshots wurden während der Läufe angelegt und sind **nach manueller Verifikation zu löschen**:

| VM | Snapshot |
|----|----------|
| k8s-dev-21 | `ansible-osupdate-dev-k8s-dev-21-20260505-134323` |
| k8s-dev-22 | `ansible-osupdate-dev-k8s-dev-22-20260505-133344` |
| k8s-dev-23 | `ansible-osupdate-dev-k8s-dev-23-20260505-133115` |
| k8s-dev-22 | `ansible-osupdate-dev-k8s-dev-22-20260505-132314` (alt, fehlgeschlagen) |
| k8s-dev-23 | `ansible-osupdate-dev-k8s-dev-23-20260505-131141` (alt, fehlgeschlagen) |

```bash
# Pro Snapshot:
govc snapshot.remove -vm <vm> <snapshot-name>
```

---

## 7. Repository-Änderungen (Stand Ende der Session)

**Neue Dateien:**
- `ansible/roles/rolling_os_update/tasks/pre_drain_prep.yml`
- `ansible/roles/rolling_os_update/tasks/post_drain_cleanup.yml`
- `docs/phases/phase-11-rolling-os-update-dev.md` (dieses Dokument)

**Modifizierte Dateien:**
- `ansible/roles/rolling_os_update/defaults/main.yml` — Maintenance-Mode-Variablen + Timeout
- `ansible/roles/rolling_os_update/tasks/drain.yml` — `last`-Filter Fix
- `ansible/roles/rolling_os_update/tasks/cnpg_failover.yml` — Plugin-Flag-Reihenfolge
- `ansible/playbooks/08-rolling-os-update.yml` — Pre/Post-Drain-Tasks eingehängt

**Conventional Commits in dieser Session (deutsch):**
- `feat(ansible): lehrbuchkonforme Drain-Strategie mit Maintenance-Modes`
- `fix(ansible): drain.yml Jinja-Filter 'last(5)' war ungueltig`
- `fix(ansible): kubectl-cnpg Plugin-Flags muessen NACH Plugin-Name stehen`
- `docs(phases): Phase 11 - Rolling OS-Update DEV Lessons Learned`

---

## 8. Nächste Schritte

**Sofortige nächste Schritte:**

1. ArgoCD-Apps verifizieren (alle Synced + Healthy).
2. ~24h Burn-in beobachten (Alerts, Logs, etc.).
3. Snapshots manuell löschen (siehe Abschnitt 6).
4. **Bevor TEST**: Action Items #1-#3 aus Abschnitt 5 (CoreDNS HA + Zot Pre-Warming) umsetzen.

**TEST/PROD-Update folgt** erst nach erfolgreicher Umsetzung der HA-Maßnahmen, mit überarbeitetem Playbook.

---

**Verfasst:** 05.05.2026  
**Cluster:** k8s-dev  
**Beteiligte:** Daniel Henke, Claude (Anthropic AI Assistant)
