# Mini-Block: imagePullPolicy GitOps-konform — Abschlussdokument

**Status:** ✅ Abgeschlossen
**Datum:** 08.05.2026
**Umgebung:** DEV + TEST + PROD (alle 3 Cluster)
**Owner:** Daniel Henke
**Vorgaengerblock:** Phase 12b CoreDNS HA PROD (07.05.2026)
**Nachfolgeblock:** Phase 11 Rolling OS-Update TEST

---

## 1. Zusammenfassung

Vor dem Rolling OS-Update wurde die `imagePullPolicy` aller relevanten Workloads
von `Always` auf `IfNotPresent` umgestellt. Damit verwenden die Container beim
Re-Schedule nach Drain den lokalen containerd-Cache und sind nicht mehr von
Registry-Verfuegbarkeit + OnDemand-Sync-Latenz abhaengig.

Hintergrund: Der DEV-Vorfall am 30.04.2026 (kaskadierender Cluster-Ausfall durch
Zot+CoreDNS SPOF) hat gezeigt, dass `imagePullPolicy: Always` in Kombination mit
einem ueberlasteten Mirror einen einzelnen Pod-Reschedule zu einem
Cluster-weiten Problem skalieren kann.

---

## 2. Geaenderte Workloads

### App-Deployments (GitOps-managed via Repo + ArgoCD)

| Workload | Vorher | Nachher | Geaenderte Files |
|---|---|---|---|
| idoit (Init + Main) | `Always` | `IfNotPresent` | base + dev + test + prod |
| it-info-versand (Init + Main) | DEV: `Always` (Drift), TEST/PROD: `IfNotPresent` (live) | explizit `IfNotPresent` in allen Files | base + dev + test + prod |

Die anderen App-Deployments im Repo (n8n, Keycloak, OpenProject, Odoo, Garage, ...)
hatten weder explizites `imagePullPolicy: Always` noch live-Drift. Wenn sie ohne
explizite Angabe deployt wurden, ist Kubernetes-Default `IfNotPresent` fuer
versionsspezifische Tags wie `:1.2.3` und `Always` nur fuer `:latest` — alle
unsere Apps nutzen versionsspezifische Tags, daher ist die Default-Behandlung
bereits korrekt.

### ArgoCD-Workloads (manueller Patch, nicht GitOps-self-managed)

7 Workloads pro Cluster gepatcht (Strategic Merge Patch):

| Workload | Container | InitContainer (zusaetzlich) |
|---|---|---|
| Deployment/argocd-applicationset-controller | `argocd-applicationset-controller` | — |
| Deployment/argocd-dex-server | `dex` | `copyutil` |
| Deployment/argocd-notifications-controller | `argocd-notifications-controller` | — |
| Deployment/argocd-redis | `redis` | — |
| Deployment/argocd-repo-server | `argocd-repo-server` | — |
| Deployment/argocd-server | `argocd-server` | — |
| StatefulSet/argocd-application-controller | `argocd-application-controller` | — |

Begruendung der Out-of-Band-Patch-Methode: ArgoCD wurde via raw Manifests
installiert und kann sich nicht selbst patchen — gleiches Pattern wie der
existierende `argocd-repo-server-ksops-patch.yaml`.

---

## 3. Neue Files im Repo

| Datei | Beschreibung |
|---|---|
| `kubernetes/base/argocd/argocd-imagepullpolicy-patch.yaml` | Strategic Merge Patches fuer alle 7 ArgoCD-Workloads |
| `scripts/maintenance/apply-argocd-imagepullpolicy.sh` | Helper-Skript: liest Multi-Doc YAML, applied per kubectl, verifiziert |
| `kubernetes/base/argocd/README.md` (erweitert) | Doku zu Patch + Re-Apply-Bedingungen |

---

## 4. Vorfall waehrend Rollout: DEV it-info-versand ImagePullBackOff

### Symptom

Nach Repo-Push und ArgoCD-Sync ging der `it-info-versand`-Pod in DEV in
`Init:ImagePullBackOff`. Der bisherige `Always`-Mode hatte die Image-Drift auf
DEV-Nodes maskiert.

```
Failed to pull image "ghcr.io/dhenkeeneg/eneg-it-info-versand:de4d0c0":
... HEAD "https://registry-dev.eneg.de/v2/dhenkeeneg/eneg-it-info-versand/manifests/de4d0c0?ns=ghcr.io":
context canceled
```

Identische Race Condition wie beim DEV-Vorfall 30.04.: containerd cancelt nach
~30-60s, kein automatischer Internet-Fallback, weil HTTP technisch erfolgreich
ist.

### Image-Cache-Analyse (Ansible ad-hoc)

| Node | hat `eneg-it-info-versand:de4d0c0` |
|---|---|
| k8s-dev-21 | NEIN |
| k8s-dev-22 | JA |
| k8s-dev-23 | JA (sogar mehrere Tags) |

Der Pod war auf k8s-dev-21 gescheduled — die einzige Node ohne Image im Cache.

### Recovery: Pre-Warming-Pattern (mit Auth)

```bash
# 1. Token aus k8s-Secret extrahieren
DOCKER_CFG=$(kubectl --context k8s-dev get secret -n it-info-versand ghcr-pull-secret \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
GHCR_USER=$(echo "$DOCKER_CFG" | jq -r '.auths["ghcr.io"].username')
GHCR_PASS=$(echo "$DOCKER_CFG" | jq -r '.auths["ghcr.io"].password')

# 2. Image auf alle 3 Nodes pullen (sequenziell, --forks 1)
ansible k3s_servers -i ansible/inventory/dev/hosts.ini -b \
  -m shell -a "sudo k3s ctr images pull --user ${GHCR_USER}:${GHCR_PASS} ghcr.io/dhenkeeneg/eneg-it-info-versand:de4d0c0" \
  --forks 1

# 3. Auth-Variablen loeschen
unset DOCKER_CFG GHCR_USER GHCR_PASS

# 4. Pod loeschen, kubelet startet neu
kubectl --context k8s-dev delete pod -n it-info-versand \
  -l app.kubernetes.io/name=it-info-versand
```

### Wichtige Erkenntnis ueber `k3s ctr images pull`

`ctr` umgeht die K3s containerd `registries.yaml` Mirror-Konfiguration und geht
direkt zur Quell-Registry. Bei privaten Images wie GHCR `dhenkeeneg/*` muss
deshalb explizit `--user` mit Auth uebergeben werden. Das Pull-Secret aus dem
Cluster (`ghcr-pull-secret`) ist die saubere Quelle dafuer.

`crictl pull` waere die Alternative, die die Mirror-Config beachtet — nutzt aber
keine k8s-Pull-Secrets. Fuer Pre-Warming-Skripte ist `ctr` mit `--user` der
zuverlaessige Weg.

---

## 5. Verifikation final (08.05.2026)

| Cluster | ArgoCD-Workloads alle `IfNotPresent` | App-Pods Healthy | ArgoCD-Apps Synced/Healthy | Cluster sauber |
|---|---|---|---|---|
| **DEV** | ✅ 7/7 | ✅ idoit + it-info-versand auf -21 | ✅ 60/60 | ✅ |
| **TEST** | ✅ 7/7 | ✅ alle Pilot-Apps | ✅ 56/56 | ✅ |
| **PROD** | ✅ 7/7 | ✅ alle Pilot-Apps | ✅ 56/56 | ✅ |

Pod-Verteilung nach Re-Roll (nicht ideal, aber Bestandsthema — kein
Anti-Affinity bei ArgoCD-Default-Manifests konfiguriert):

| Cluster | -21 | -22 | -23 |
|---|---|---|---|
| DEV | 6 | 1 (repo-server) | 0 |
| TEST | 0 | 4 | 3 |
| PROD | 5 | 2 | 0 |

Beim naechsten Drain/Reschedule (z.B. waehrend OS-Update) verteilt sich das wieder.

---

## 6. Lessons Learned fuer Phase 11 OS-Update

1. **Pre-Warming ist Pflicht-Pattern** vor jedem groesseren Drain-Event.
   Insbesondere bei privaten/Custom-Images (`ghcr.io/dhenkeeneg/*`) wo
   OnDemand-Sync-Latenz unvorhersagbar ist.
2. **Image-Cache-Inventur vor Drain.** Welche Images sind welche Nodes? Lueckenliste
   abarbeiten.
3. **`k3s ctr pull` mit `--user`** und Token aus `ghcr-pull-secret` ist das
   Standard-Pattern fuer privates Pre-Warming.
4. **`--forks 1`** bei Ansible-Pulls — sequenziell statt parallel, damit der Mirror
   nicht von 3 OnDemand-Syncs gleichzeitig erschlagen wird.
5. **Image-Inventur-Skript** waere ein sinnvolles Folge-Tool (TODO).

---

## 7. Backlog

In `docs/phases/roadmap-handoff-2026-05-06.md` neu eingetragen:

> **#10 — ArgoCD Self-Management via Helm-Chart**
> Migration vom raw-manifest-Setup auf das offizielle `argo-cd` Helm-Chart, damit
> Patches wie KSOPS und imagePullPolicy nicht mehr out-of-band sein muessen,
> sondern via Helm-Values Self-managed sind. Sinnvoll vor naechstem ArgoCD
> Major-Upgrade (>v3.4) als Vorbereitung. Aufwand 1-2 Tage. Detail-Abschnitt 8b
> in der Roadmap.

---

## 8. Re-Apply-Bedingungen fuer ArgoCD-Patches

Da ArgoCD self-management noch nicht migriert ist (siehe #10), muss der Patch
re-appliziert werden bei:

- Initialer Cluster-Bereitstellung (nach `kubectl apply -n argocd -f install.yaml`)
- Jedem ArgoCD-Versions-Upgrade (Manifests werden komplett ersetzt)
- Nach Hinzufuegen weiterer ArgoCD-Komponenten

Skript ist idempotent — Mehrfach-Apply ist unproblematisch.

```bash
./scripts/maintenance/apply-argocd-imagepullpolicy.sh k8s-dev
./scripts/maintenance/apply-argocd-imagepullpolicy.sh k8s-test
./scripts/maintenance/apply-argocd-imagepullpolicy.sh k8s-prod
```

---

## 9. Zeitlicher Ablauf 08.05.2026

| Uhrzeit (CET) | Aktion |
|---|---|
| ~07:30 | Repo-Aenderungen (8 Deployment-Files + 2 neue Files + README + Roadmap) committed + gepushed |
| ~08:06 | DEV ArgoCD-Sync triggered, idoit OK, it-info-versand `Init:ImagePullBackOff` auf k8s-dev-21 |
| ~08:10 | Image-Cache-Inventur: -22 + -23 hatten Image, -21 nicht |
| ~08:15 | Pre-Warming auf alle 3 Nodes erfolgreich (mit Token aus `ghcr-pull-secret`) |
| ~08:18 | DEV alle Apps Healthy |
| ~08:24 | Skript apply-argocd-imagepullpolicy.sh DEV — alle 7 Workloads gepatcht |
| ~08:27 | TEST analog — alle 7 Workloads gepatcht |
| ~08:29 | PROD analog — alle 7 Workloads gepatcht |
| ~08:32 | Verifikation aller 3 Cluster: alles healthy |

**Gesamtdauer:** ~1 Stunde inkl. Drift-Vorfall + Recovery + Lessons-Doku.

---

*Ende Mini-Block. Naechster Block: Phase 11 Rolling OS-Update TEST.*
