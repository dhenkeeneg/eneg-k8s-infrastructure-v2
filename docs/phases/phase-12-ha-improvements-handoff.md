# Phase 12 - HA Improvements Handoff: CoreDNS + Zot

> **Status:** ✅ **Abgeschlossen am 06.05.2026 (DEV)** — siehe [phase-12-ha-improvements-completed.md](phase-12-ha-improvements-completed.md) fuer den End-to-End-Bericht.
>
> TEST/PROD-Rollout: siehe [phase-12b-coredns-test-prod-handoff.md](phase-12b-coredns-test-prod-handoff.md).
>
> Dieses Doc bleibt als historische Plan-Vorlage erhalten. **Achtung:** Einige Snippets im Doc (z.B. `serviceMonitor.enabled: true`, `uri /healthz`, fehlende NodeHosts) sind durch die Praxis ueberholt — die Lessons im completed-Doc und der TEST/PROD-Handoff haben Vorrang.

**Datum erstellt:** 05.05.2026  
**Vorgaenger-Phase:** Phase 11 (Rolling OS-Update DEV)  
**Mission:** Zwei kritische Single-Points-of-Failure aufloesen, die im OS-Update-Vorfall identifiziert wurden  
**Reihenfolge:** Sequenzielles Environment-Deployment — DEV → Burn-in → TEST → Burn-in → PROD

---

## 1. Kontext und Mission

In Phase 11 wurde ein Rolling-OS-Update auf DEV durchgefuehrt. Dabei kam es zu einem kaskadierenden Cluster-Ausfall, der durch zwei verkettete Single-Points-of-Failure ausgeloest wurde. Beide werden in dieser Phase aufgeloest.

### Identifizierte SPOFs

**SPOF 1 — Zot Container Registry mit nur 1 Replica:**
- Aktueller Zustand: 1 Pod `registry-zot-0` als StatefulSet (auf k8s-dev-23)
- Problem: Beim Drain dieser Node ist der Mirror 30-60s nicht erreichbar
- Wenn gleichzeitig ein anderer Pod migriert und ein nicht-cached Image braucht, kommt es zu permanenten ImagePullBackOffs
- Backend ist S3 auf NAS10 — Multi-Replica technisch problemlos

**SPOF 2 — CoreDNS mit nur 1 Replica:**
- Aktueller Zustand: 1 Pod `coredns-67f6f5f49f-*` als Deployment in `kube-system`
- K3s deployt CoreDNS hardcoded mit replicas=1 (bekanntes Issue k3s-io/k3s#1606 seit 2020)
- Bei Drain → DNS-Outage → kaskadierende Service-Ausfaelle (CSI, CNPG-Plugins, etc.)

### Was diese Session NICHT macht

- TEST oder PROD anfassen (das kommt nach erfolgreichem DEV-Burn-in)
- imagePullPolicy=Always umstellen (separates kleineres Vorhaben)
- MariaDB Galera Anti-Affinity (separates Volume-Strategie-Projekt)

---

## 2. Workflow-Regeln (KRITISCH BEACHTEN)

Diese Workflow-Regeln gelten unabhaengig vom Inhalt:

1. **Sequenzielles Environment-Deployment:** Erst DEV, dann Burn-in 24h, dann TEST, dann Burn-in 24h, dann PROD. **NIEMALS** mehrere Environments in einem Schritt.
2. **Optionen vor Aktionen:** Bei Entscheidungen Optionen mit Pros/Cons vorlegen, Daniel entscheidet.
3. **Daniel macht selbst:** git commits/pushes, SSH-Befehle auf Server, SOPS-Encryption, Snapshot-Operationen.
4. **Conventional Commits in Deutsch.**
5. **Stabilitaet > Geschwindigkeit:** keine experimentellen Versionen, nur erprobte stabile Releases, Versionen vor Verwendung mit Daniel abstimmen.
6. **Schritt-fuer-Schritt:** Bei MicroK8s/K3s-Aenderungen Dateierstellung+Ausfuehrung in einer Anweisung, anschliessende Pruefungen einzeln.

---

## 3. Vorab-Recherche (bereits erledigt am 05.05.2026)

### K3s-Architektur

K3s ist Ansible-managed:
- Inventory: `ansible/inventory/dev/group_vars/all.yml` — Variable `k3s_disable`
- Aktueller Wert: `[traefik, servicelb, local-storage]`
- Config-Template: `ansible/templates/k3s-config.yaml.j2` (idempotent, wird bei jedem Run neu deployed)
- Role-Handler: `restart k3s` bei Config-Aenderung
- ⚠️ **Wichtig:** Im Default-Playbook `02-install-k3s.yml` ist KEIN `serial: 1` — alle 3 Master wuerden gleichzeitig restartet werden. Wir brauchen ein eigenes Playbook fuer CoreDNS-Migration.

### CoreDNS in K3s

CoreDNS ist KEIN Helm-Chart in K3s, sondern ein Addon-Manifest:
- Path auf Server: `/var/lib/rancher/k3s/server/manifests/coredns.yaml`
- Annotation: `objectset.rio.cattle.io/owner-gvk: k3s.cattle.io/v1, Kind=Addon`
- K3s synced das Manifest regelmaessig zurueck — `kubectl edit deployment coredns` haelt nicht
- `coredns-custom` ConfigMap erlaubt nur Corefile-Anpassungen, NICHT Replicas oder Affinity
- Einziger offizieller Weg laut K3s-Docs: `--disable=coredns`

### Zot Architektur

- Helm-Chart: `project-zot/zot v0.1.104` (App v2.1.15)
- ArgoCD Multi-Source Application: `kubernetes/environments/dev/infrastructure/registry-app.yaml`
- Base Values: `kubernetes/base/registry/values.yaml` (replicaCount: 1)
- DEV Override: `kubernetes/environments/dev/registry/values-override.yaml`
- Storage: S3 auf NAS10 (`nas10.eneg.de:8010`, Bucket `k8s-dev-registry`)
- Lokales PVC: 10Gi Longhorn (Cache + Sync-Tmp)
- Sync-Konfiguration: OnDemand fuer docker.io/quay.io/ghcr.io/registry.k8s.io + Periodic fuer ghcr.io/dhenkeeneg

---

## 4. Plan A: Zot HA — Schritt-fuer-Schritt

**Reihenfolge in dieser Session:** Zot HA zuerst (low-risk, ArgoCD-managed). Erst nach erfolgreicher Verifikation CoreDNS HA angehen.

### 4.1 Aenderung in `kubernetes/environments/dev/registry/values-override.yaml`

**Wo einfuegen:** Vor dem `env:` Block am Anfang der Datei einen neuen Block ergaenzen (nicht in `configFiles`).

**YAML-Snippet (copy-paste-ready):**

```yaml
# --- HA-Konfiguration ---
# Phase 12: 3 Replicas mit Anti-Affinity + topologySpreadConstraints,
# damit der Mirror waehrend Node-Drains immer erreichbar bleibt.
# Backend ist S3 (NAS10), daher Multi-Replica unproblematisch.
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

### 4.2 Commit + Push

```bash
git add kubernetes/environments/dev/registry/values-override.yaml
git commit -m "feat(registry): Zot HA mit 3 Replicas + Anti-Affinity (DEV)

Zot Single-Replica war SPOF im OS-Update-Vorfall (Phase 11).
Backend ist S3 (NAS10), daher Multi-Replica problemlos.

- replicaCount: 1 -> 3
- podAntiAffinity preferred ueber kubernetes.io/hostname
- topologySpreadConstraints maxSkew=1 ScheduleAnyway

Storage-Impact: +20 GB Longhorn (3x 10Gi PVC statt 1x)
Erste Replicas brauchen 5-10 Min beim Hochlaufen wegen S3-Backend-Scan."
git push
```

### 4.3 Verify-Checks

ArgoCD synced automatisch (selfHeal: true). Erwartung:

```bash
# 1. ArgoCD App-Status pruefen (sollte Synced + Healthy werden)
kubectl --context k8s-dev get application registry -n argocd

# 2. StatefulSet sollte auf 3 Replicas skalieren
kubectl --context k8s-dev get statefulset registry-zot -n registry

# 3. Pods abwarten — kann 5-10 Min dauern wegen Startup-Probe (5min Budget)
kubectl --context k8s-dev get pods -n registry -o wide -w

# 4. Pods sollten auf 3 verschiedenen Nodes verteilt sein
kubectl --context k8s-dev get pods -n registry -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'

# 5. Neue PVCs sollten erstellt sein (3x statt 1x)
kubectl --context k8s-dev get pvc -n registry

# 6. Service sollte 3 Endpoints haben
kubectl --context k8s-dev get endpoints registry-zot -n registry
```

**Erfolgs-Kriterium:** 3/3 Pods Ready, je 1 Pod pro Node, alle 3 PVCs Bound, Endpoints zeigt 3 IPs.

### 4.4 Smoke-Test

```bash
# Pull-Test ueber Mirror (von einer Cluster-Node aus)
# Ein bekanntes, kleines Image pullen — sollte aus Cache antworten
kubectl --context k8s-dev run zot-test --rm -it --image=alpine:3.21 --restart=Never -- /bin/sh -c "echo OK"
```

### 4.5 Burn-in

Nach erfolgreichem Deploy: **24 Stunden ruhen lassen**. Auf Alerts in Slack achten. Falls Probleme: Rollback (siehe Abschnitt 7).

---

## 5. Plan B: CoreDNS HA — Variante A "Bigbang"

**Voraussetzung:** Zot HA muss erfolgreich abgeschlossen UND 24h Burn-in durch sein. Sonst NICHT starten.

**Outage-Erwartung:** Ca. 30-60s DNS-Lueche waehrend des Cutovers. Pods mit aktiven Verbindungen sollten das ueberstehen, neue Service-Lookups in dem Fenster schlagen fehl.

### 5.1 Konzept

```
Aktuell:                       Ziel:
┌──────────────────┐           ┌──────────────────┐
│  K3s Addon       │           │  ArgoCD-managed  │
│  CoreDNS         │   --->    │  CoreDNS         │
│  1 Replica       │           │  3 Replicas      │
│  k8s-dev-XX      │           │  je 1 pro Node   │
└──────────────────┘           └──────────────────┘
   K3s synced zurueck             k3s_disable=coredns
                                  ArgoCD reconciled
```

### 5.2 Vorab-Klaerung im neuen Chat

Bevor irgendetwas geaendert wird — folgende Punkte recherchieren und abstimmen:

1. **CoreDNS Helm-Chart Version:** Aktuelle stable Version pruefen unter https://github.com/coredns/helm. Image-Tag muss konsistent zu K3s' eigener Version sein (aktuell `1.14.1`).
2. **Cluster-DNS Service-IP:** Bei K3s standardmaessig `10.43.0.10`. Verifizieren via `kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}'`.
3. **Image-Source:** Original `coredns/coredns:1.14.1` (von DockerHub via Zot-Mirror) ODER K3s-Mirror `rancher/mirrored-coredns-coredns:1.14.1`. Empfehlung: Original, weil Zot-Mirror das ohnehin synced. **Vor Cutover muss das Image im Zot-Cache pre-warmed sein** — sonst gleiches Problem wie in Phase 11!
4. **Service-IP-Cutover:** Service-ClusterIP ist immutable. Daher MUSS der bestehende `kube-dns` Service vor dem ArgoCD-Sync geloescht werden, damit unser Helm-Chart einen Service mit `clusterIP: 10.43.0.10` neu anlegen kann.

### 5.3 Vorbereitung — Repository-Aenderungen

#### 5.3.1 Image Pre-Warming

**KRITISCH:** Bevor irgendetwas mit CoreDNS gemacht wird, muss das Ziel-Image im Zot-Cache verfuegbar sein. Nach Zot HA aus Plan A laufen 3 Replicas — pre-pullen via:

```bash
# Auf k8s-mgmt-10 — triggert Sync ueber Mirror auf alle 3 Zot-Pods
crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock pull \
  registry-dev.eneg.de/coredns/coredns:1.14.1
```

Plus auf jeder DEV-Node das Image vor-pullen, damit auch containerd lokal Cache hat.

#### 5.3.2 ArgoCD Application

Neue Datei: `kubernetes/environments/dev/infrastructure/coredns-app.yaml`

```yaml
---
# ArgoCD Application: CoreDNS HA (DEV)
# Phase 12: HA-Replacement fuer K3s-Default-CoreDNS
# Multi-Source: Helm Chart + Base Values + DEV Override
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coredns
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Vor allem anderen
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  sources:
    - repoURL: https://coredns.github.io/helm
      chart: coredns
      targetRevision: <VERSION>  # zu klaeren in 5.2.1
      helm:
        releaseName: coredns
        valueFiles:
          - $values/kubernetes/base/coredns/values.yaml
          - $values/kubernetes/environments/dev/coredns/values-override.yaml

    - repoURL: git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git
      targetRevision: main
      ref: values

  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system

  syncPolicy:
    automated:
      prune: false  # WICHTIG: nicht automatisch loeschen — sonst Cluster-Outage
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

#### 5.3.3 Base Values: `kubernetes/base/coredns/values.yaml`

```yaml
# CoreDNS Base Values — generisch fuer alle Environments
# Helm Chart: coredns/coredns
# Phase 12: HA-Replacement fuer K3s-Default-CoreDNS

replicaCount: 3

image:
  repository: coredns/coredns
  tag: "1.14.1"
  pullPolicy: IfNotPresent

# Service-IP MUSS exakt der bisherige K3s Default sein,
# damit kubelet's --cluster-dns weiter funktioniert.
service:
  clusterIP: 10.43.0.10
  name: kube-dns  # bewusst gleicher Name wie alter Service

# HA-Konfiguration
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: coredns
          topologyKey: kubernetes.io/hostname

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: coredns

# PodDisruptionBudget: maximal 1 Replica darf gleichzeitig down sein
podDisruptionBudget:
  minAvailable: 2

# Default Corefile — kompatibel zu K3s-Default
servers:
  - zones:
      - zone: .
    port: 53
    plugins:
      - name: errors
      - name: health
        configBlock: |-
          lameduck 5s
      - name: ready
      - name: kubernetes
        parameters: cluster.local in-addr.arpa ip6.arpa
        configBlock: |-
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
          ttl 30
      - name: prometheus
        parameters: 0.0.0.0:9153
      - name: forward
        parameters: . /etc/resolv.conf
      - name: cache
        parameters: 30
      - name: loop
      - name: reload
      - name: loadbalance

resources:
  requests:
    cpu: 100m
    memory: 70Mi
  limits:
    cpu: 200m
    memory: 170Mi

# ServiceMonitor fuer Prometheus
serviceMonitor:
  enabled: true
  namespace: monitoring
```

#### 5.3.4 DEV Override: `kubernetes/environments/dev/coredns/values-override.yaml`

```yaml
# CoreDNS DEV Override — aktuell keine env-spezifischen Aenderungen
# Platzhalter fuer zukuenftige DNS-Forwards o.ae.
```

Plus `kustomization.yaml` falls noetig (analog zu Zot).

#### 5.3.5 Ansible-Aenderung in `ansible/inventory/dev/group_vars/all.yml`

```yaml
# Komponenten die NICHT installiert werden sollen
k3s_disable:
  - traefik
  - servicelb
  - local-storage
  - coredns  # Phase 12: replaced durch ArgoCD-managed CoreDNS HA
```

#### 5.3.6 Neues Ansible-Playbook fuer CoreDNS-Migration

Neue Datei: `ansible/playbooks/09-k3s-coredns-disable.yml`

```yaml
---
# Phase 12: CoreDNS-Migration
# Sequenzieller K3s-Restart auf allen Mastern, damit nicht alle gleichzeitig
# offline sind. Voraussetzung: k3s_disable enthaelt jetzt 'coredns'.

- name: K3s Config Update fuer CoreDNS-Migration
  hosts: k3s_master
  serial: 1            # WICHTIG: Sequenziell, nicht parallel
  become: yes
  any_errors_fatal: true  # Bei Fehler: stop, nicht weiter zu naechstem Master

  tasks:
    - name: Deploy K3s config file (mit coredns disabled)
      template:
        src: ../templates/k3s-config.yaml.j2
        dest: /etc/rancher/k3s/config.yaml
        mode: '0644'
      notify: restart k3s

    - name: Force handler now
      meta: flush_handlers

    - name: Wait for K3s API to be reachable after restart
      uri:
        url: "https://localhost:6443/healthz"
        validate_certs: no
        status_code: 200
      register: k3s_health
      until: k3s_health.status == 200
      retries: 30
      delay: 10

    - name: Wait additional 30s for stabilization
      pause:
        seconds: 30

  handlers:
    - name: restart k3s
      systemd:
        name: k3s
        state: restarted
        daemon_reload: yes
```

### 5.4 Cutover-Ablauf (Schritt fuer Schritt)

**Kuerzeste DNS-Lueche:** 30-60s zwischen Punkt 4 und Punkt 5.

#### Schritt 1: Repository-Aenderungen committen + pushen

Alle Aenderungen aus 5.3 in einem oder mehreren Commits:

```bash
git add kubernetes/base/coredns/
git add kubernetes/environments/dev/coredns/
git add kubernetes/environments/dev/infrastructure/coredns-app.yaml
git add ansible/inventory/dev/group_vars/all.yml
git add ansible/playbooks/09-k3s-coredns-disable.yml
git commit -m "feat(coredns): HA-Setup vorbereiten (DEV) - Phase 12

ArgoCD-managed CoreDNS Helm-Chart mit 3 Replicas + Anti-Affinity.
K3s-Default-CoreDNS wird via --disable=coredns abgeloest.

NICHT direkt aktiv — Cutover erfolgt manuell in koordinierten Schritten."
git push
```

⚠️ **WICHTIG:** ArgoCD wird die `coredns` Application sehen. Stelle vorher sicher, dass `automated.prune: false` gesetzt ist UND nicht direkt synced wird. Gegebenenfalls als suspended deployen oder erst nach Service-Loeschung syncen.

#### Schritt 2: Image Pre-Warming

Auf allen 3 DEV-Nodes (per SSH von k8s-mgmt-10) das Ziel-Image vorab pullen:

```bash
# Auf jeder Node: k8s-dev-21, k8s-dev-22, k8s-dev-23
ssh k8s-dev-21 'sudo k3s ctr images pull registry-dev.eneg.de/coredns/coredns:1.14.1'
ssh k8s-dev-22 'sudo k3s ctr images pull registry-dev.eneg.de/coredns/coredns:1.14.1'
ssh k8s-dev-23 'sudo k3s ctr images pull registry-dev.eneg.de/coredns/coredns:1.14.1'
```

Verifizieren dass es laeuft auf allen 3 Nodes:

```bash
ssh k8s-dev-21 'sudo k3s ctr images ls | grep coredns'
ssh k8s-dev-22 'sudo k3s ctr images ls | grep coredns'
ssh k8s-dev-23 'sudo k3s ctr images ls | grep coredns'
```

#### Schritt 3: Ansible-Playbook ausfuehren — K3s sequenziell auf disable umstellen

Auf k8s-mgmt-10:

```bash
cd ~/git/eneg-k8s-infrastructure-v2
ansible-playbook -i ansible/inventory/dev ansible/playbooks/09-k3s-coredns-disable.yml
```

**Erwartung:** Sequenzielle K3s-Restarts auf allen 3 Mastern. Pro Node: ~1-2 Min Downtime der API auf der jeweiligen Node, aber Cluster bleibt funktional weil andere 2 noch laufen. Die bestehenden CoreDNS-Pods bleiben aktiv (K3s raeumt nicht auf, syncs nur nicht mehr nach).

**Verify nach jedem Master-Restart:**

```bash
# K3s-Service-Status
ssh k8s-dev-XX 'sudo systemctl status k3s'

# CoreDNS Pods sollten weiter laufen (alte K3s-managed Version)
kubectl --context k8s-dev get pods -n kube-system -l k8s-app=kube-dns
```

#### Schritt 4: Cutover (kurze Outage)

⚠️ **Hier beginnt das DNS-Outage-Fenster (~30-60s).**

```bash
# 1. Bestehende kube-dns Service loeschen — ClusterIP wird frei fuer ArgoCD-CoreDNS
kubectl --context k8s-dev delete service kube-dns -n kube-system

# 2. Bestehendes coredns Deployment loeschen
kubectl --context k8s-dev delete deployment coredns -n kube-system

# 3. ConfigMap und ServiceAccount loeschen (oder bleiben lassen — ArgoCD haendelt das)
kubectl --context k8s-dev delete configmap coredns -n kube-system
kubectl --context k8s-dev delete serviceaccount coredns -n kube-system

# 4. ArgoCD App syncen — eigenes CoreDNS hochziehen
argocd app sync coredns
# ODER ueber UI

# 5. Auf Pods warten
kubectl --context k8s-dev get pods -n kube-system -l app.kubernetes.io/name=coredns -w
```

#### Schritt 5: Verify-Checks

```bash
# 1. Service hat richtige ClusterIP
kubectl --context k8s-dev get svc kube-dns -n kube-system
# Erwartung: ClusterIP = 10.43.0.10

# 2. 3 Pods laufen, je 1 pro Node
kubectl --context k8s-dev get pods -n kube-system -l app.kubernetes.io/name=coredns -o wide

# 3. Endpoints zeigt 3 IPs
kubectl --context k8s-dev get endpoints kube-dns -n kube-system

# 4. DNS-Resolution-Test aus Cluster
kubectl --context k8s-dev run dns-test --rm -it --image=alpine:3.21 --restart=Never -- nslookup kubernetes.default.svc.cluster.local
# Erwartung: Server: 10.43.0.10, Antwort mit Cluster-Service-IP

# 5. ServiceMonitor ist auf
kubectl --context k8s-dev get servicemonitor coredns -n monitoring

# 6. K3s syncs nicht mehr zurueck — verifizieren durch warten
sleep 60
kubectl --context k8s-dev get pods -n kube-system -l k8s-app=kube-dns
# Erwartung: KEIN alter K3s-CoreDNS-Pod mehr da
```

### 5.5 Burn-in

**24 Stunden ruhen lassen.** Beobachtungspunkte:
- DNS-Lookups in Apps (Slack-Alerts pruefen)
- CoreDNS-Pod-Restarts
- Memory/CPU-Verbrauch
- ServiceMonitor-Scrapes erfolgreich

Wenn alles ruhig: bereit fuer TEST-Rollout.

---

## 6. Rollback-Strategien

### Rollback Zot HA

```bash
# values-override.yaml: replicaCount zurueck auf 1, Anti-Affinity-Bloecke entfernen
# Commit + Push + ArgoCD-Sync
# StatefulSet wird auf 1 Replica skaliert
# 2 ueberzaehlige PVCs muessen manuell aufgeraeumt werden:
kubectl --context k8s-dev delete pvc registry-pvc-registry-zot-1 -n registry
kubectl --context k8s-dev delete pvc registry-pvc-registry-zot-2 -n registry
```

### Rollback CoreDNS HA

⚠️ Hier ist Rollback komplexer wegen K3s-Addon-Verhalten.

```bash
# 1. ArgoCD coredns App suspendieren oder loeschen
# 2. Aus k3s_disable die Zeile 'coredns' entfernen, commit, push
# 3. Ansible-Playbook 09-... erneut ausfuehren — K3s deployt CoreDNS-Addon wieder
# 4. K3s-Default-CoreDNS sollte automatisch hochkommen
```

Bei kompletter Cluster-DNS-Outage als Notfall-Schnellfix:

```bash
# Aus dem K3s-Default-Manifest manuell deployen
kubectl --context k8s-dev apply -f /var/lib/rancher/k3s/server/manifests/coredns.yaml
```

---

## 7. Repository-Pfade & wichtige Befehle

### Repository

- **Mac:** `/Users/danielhenke/git/eneg-k8s-infrastructure-v2/`
- **Windows:** `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\`
- **Management-Server:** `~/git/eneg-k8s-infrastructure-v2/` auf k8s-mgmt-10
- **GitHub:** `github.com:dhenkeeneg/eneg-k8s-infrastructure-v2`

### Wichtige Pfade fuer diese Phase

```
kubernetes/
├── base/
│   ├── registry/values.yaml           # Zot Base — DARF NICHT veraendert werden in dieser Phase (DEV-Override-Pattern)
│   └── coredns/values.yaml            # NEU
├── environments/dev/
│   ├── registry/values-override.yaml  # Zot DEV — Aenderung in 4.1
│   ├── coredns/values-override.yaml   # NEU (DEV-Override)
│   └── infrastructure/
│       └── coredns-app.yaml           # NEU (ArgoCD App)
ansible/
├── inventory/dev/group_vars/all.yml   # k3s_disable erweitern
└── playbooks/
    └── 09-k3s-coredns-disable.yml     # NEU (sequenzieller K3s-Restart)
```

### Cluster-Zugriff

- Kubectl-Contexts: `k8s-dev`, `k8s-test`, `k8s-prod`
- Kubernetes MCP Server fuer `kubectl_*`-Aufrufe verfuegbar
- ArgoCD-UI: https://argocd-dev-v2.eneg.de
- Longhorn-UI: https://longhorn-dev-v2.eneg.de

### SSH-Zugriff (durch Daniel)

- k8s-mgmt-10: 192.168.180.10 (Management-Server)
- k8s-dev-21/22/23: 192.168.180.21-23

---

## 8. Offene Klaerungspunkte fuer den neuen Chat

Diese Punkte muessen am Anfang der neuen Session geklaert werden:

1. **CoreDNS Helm-Chart Version recherchieren** — auf https://github.com/coredns/helm aktuelle stable Version pruefen, mit Daniel abstimmen.
2. **CoreDNS Image-Tag** — soll exakt `1.14.1` (gleich K3s) sein, oder etwas Neueres? Empfehlung: Erstmal gleich, spaeter Bumping ueber separaten Prozess.
3. **K3s-Image-Pinning** — In `ansible/playbooks/02-install-k3s.yml` ist die Liste `--disable=traefik --disable=servicelb --disable=local-storage` hardcoded. Bei Neu-Install muesste auch dort `--disable=coredns` hinzugefuegt werden. Fuer bestehende Installation reicht aber der `config.yaml`-Update. Daniel entscheidet ob das jetzt mit angepasst werden soll.
4. **Order-of-Operations beim Cutover** — Das Loeschen des `kube-dns` Service vor ArgoCD-Sync ist die schnellste Methode. Alternative (ohne Service-Delete) wuerde Service-Selector-Patch erfordern, der elegantere aber komplexer ist. Im Doc steht die einfache Variante.
5. **Pre-Warming sequencing** — Soll Image-Pre-Warming Teil des Ansible-Playbooks werden (als Pre-Drain-Task)? Das ist ein separates Action Item aus Phase 11, aber waere hier passend mitzunehmen.

---

## 9. Schluesselwort fuer die naechste Session

Wenn Daniel im neuen Chat startet, sagt er:

> "Bitte lies `docs/phases/phase-12-ha-improvements-handoff.md` und lass uns Plan A starten. Cluster ist gesund, Burn-in von Phase 11 ist durch."

Der Assistent soll dann:

1. Diese Doku komplett lesen
2. Den aktuellen Cluster-Status verifizieren (Zot 1 Replica, CoreDNS 1 Replica — Ausgangszustand)
3. Mit Plan A starten (4.1)
4. Bei jedem Schritt zwischendurch verifizieren, **niemals** Plan B (CoreDNS) starten ohne erfolgreiche Plan A + 24h Burn-in

---

**Ende des Handoff-Docs.**

Bei Fragen waehrend der Session: Phase 11 Doc (`phase-11-rolling-os-update-dev.md`) hat den Vorgeschichten-Kontext.
