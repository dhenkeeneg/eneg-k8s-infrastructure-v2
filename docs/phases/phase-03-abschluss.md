# Phase 3: GitOps-Fundament (ArgoCD) - Abschlussdokument

**Status:** ✅ Abgeschlossen  
**Abgeschlossen am:** 10.02.2026  
**Dauer:** 1 Tag  
**Umgebung:** DEV (k8s-dev-21, k8s-dev-22, k8s-dev-23)

---

## Zusammenfassung

Phase 3 wurde erfolgreich abgeschlossen. ArgoCD v3.3.0 ist installiert, mit GitHub verbunden und verwaltet sich selbst aus Git (App-of-Apps Pattern). Das GitOps-Fundament steht - alle zukünftigen Deployments werden über Git gesteuert.

---

## Erreichte Ziele

### ArgoCD Installation
- ✅ **ArgoCD v3.3.0:** Installiert via offizielle Manifests
- ✅ **Server-Side Apply:** Annotation-Limit Problem gelöst
- ✅ **Alle Pods Running:** 7 Pods (server, repo-server, controller, etc.)
- ✅ **Admin-Zugang:** Passwort gesichert, UI-Zugriff funktioniert

### GitHub Integration
- ✅ **Deploy Key:** SSH Key (ed25519) für read-only Zugriff
- ✅ **Repository Secret:** Erstellt (nicht in Git committed)
- ✅ **Connection Status:** Successful
- ✅ **Repository URL:** git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git

### GitOps-Struktur
- ✅ **Verzeichnisstruktur:** Pattern A (Environment-basiert)
- ✅ **Base Configuration:** kubernetes/base/argocd
- ✅ **Bootstrap:** kubernetes/bootstrap
- ✅ **Kustomize:** Strukturiert mit kustomization.yaml

### Self-Management
- ✅ **App-of-Apps Pattern:** ArgoCD verwaltet sich selbst
- ✅ **Auto-Sync:** Aktiviert (prune + selfHeal)
- ✅ **Git as Source of Truth:** Alle Änderungen über Git

### kubectl Integration
- ✅ **kubeconfig merged:** Windows Laptop hat Zugriff auf beide Cluster
- ✅ **Context Switching:** Zwischen k8s-dev-old und k8s-dev-k3s möglich
- ✅ **Lokale Tools:** kubectl + k9s können verwendet werden

---

## Technische Details

### ArgoCD Installation

**Version:** v3.3.0 (neueste stabile Version, Februar 2026)

**Installation:**
```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml
```

**Pods:**
```
NAME                                               READY   STATUS
argocd-application-controller-0                    1/1     Running
argocd-applicationset-controller-77475dfcf-k945d   1/1     Running
argocd-dex-server-6485c5ddf5-x24mn                 1/1     Running
argocd-notifications-controller-758f795776-pkk4c   1/1     Running
argocd-redis-6cc4bb5db5-5lj58                      1/1     Running
argocd-repo-server-c76cf57cd-hppw4                 1/1     Running
argocd-server-6f85b59c87-6hjf6                     1/1     Running
```

### Repository-Struktur

```
kubernetes/
├── bootstrap/
│   ├── README.md                    # Bootstrap-Dokumentation
│   ├── namespace.yaml               # ArgoCD Namespace
│   └── argocd-app.yaml             # ArgoCD Self-Management Application
├── base/
│   └── argocd/
│       ├── README.md                # Base Configuration Dokumentation
│       ├── kustomization.yaml       # Kustomize Einstiegspunkt
│       ├── argocd-cm.yaml          # Repository Configuration
│       └── repository-secret-template.yaml  # Template (Secret manuell)
└── environments/
    └── dev/
        └── argocd/                  # DEV-spezifische Overlays (leer)
```

### SSH Deploy Key

**Speicherort:**
- Private Key: `C:\Users\dhenke\.ssh\argocd-deploy-key` (Windows)
- Public Key: GitHub Repository → Settings → Deploy keys

**Secret im Cluster:**
```bash
kubectl get secret repo-eneg-k8s-infrastructure-v2 -n argocd
```

**Wichtig:** Private Key NICHT in Git committed!

### kubeconfig Merge

**Windows Laptop:** `C:\Users\dhenke\.kube\config`

**Verfügbare Contexts:**
- `k8s-dev-old` - Alter MicroK8s Cluster (192.168.180.11)
- `k8s-dev-k3s` - Neuer K3s Cluster (192.168.180.21-23)

**Context wechseln:**
```bash
kubectl config use-context k8s-dev-k3s
```

---

## Wichtige Learnings

### 1. ArgoCD v3.x Annotation Limit

**Problem:** CRDs überschreiten kubectl client-side apply Limit
```
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Lösung:** Server-side apply mit force-conflicts
```bash
kubectl apply --server-side --force-conflicts -f ...
```

**Dokumentation:** https://kubernetes.io/docs/reference/using-api/server-side-apply/

### 2. kubeconfig Merge Best Practice

**Strategie:** Alle Cluster in einer config mit eindeutigen Namen
- Cluster: `k8s-dev-old`, `k8s-dev-k3s`
- User: `k8s-dev-old-admin`, `k8s-dev-k3s-admin`
- Context: Gleicher Name wie Cluster

**Vorteile:**
- Einfaches Switching mit `kubectl config use-context`
- Alle kubeconfig-basierten Tools (k9s, Lens) funktionieren
- Konsistent über alle Workstations (Windows, Mac)

### 3. Deploy Keys vs Personal Access Tokens

**Entscheidung:** Deploy Keys (SSH) statt Personal Access Tokens (HTTPS)

**Vorteile:**
- ✅ Repository-spezifisch (nur ein Repo, nicht alle)
- ✅ Read-only möglich
- ✅ Kein User-Account benötigt
- ✅ Keine Expiration

**Setup:**
```bash
ssh-keygen -t ed25519 -C "argocd-deploy@k8s-dev" -f argocd-deploy-key -N ''
```

### 4. Secrets nicht in Git (noch)

**Aktueller Status:** Repository Secret manuell erstellt

**Später (Phase 3b):** SOPS + Age für verschlüsselte Secrets in Git

**Warum jetzt noch nicht:**
- Phase 3 funktional komplett
- SOPS erst bei echtem Bedarf (Phase 4: Ingress-Secrets)
- Besseres Timing für Lernkurve

### 5. App-of-Apps Pattern

**Konzept:** ArgoCD Application verwaltet ArgoCD selbst

**Vorteile:**
- ✅ Vollständig GitOps-konform
- ✅ Änderungen über Git → Auto-Sync
- ✅ Versioniert und nachvollziehbar
- ✅ Disaster Recovery: kubectl apply bootstrap/argocd-app.yaml

**Implementation:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
spec:
  source:
    repoURL: git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git
    path: kubernetes/base/argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Troubleshooting-Erfahrungen

### Problem: ArgoCD CRD Installation scheitert

**Symptom:**
```
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Ursache:** kubectl client-side apply speichert komplette Manifest-Historie in Annotations

**Lösung:**
```bash
kubectl apply --server-side --force-conflicts -f install.yaml
```

### Problem: Repository Connection Failed

**Diagnose:**
```bash
kubectl get secret -n argocd | grep repo
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

**Häufige Ursachen:**
1. SSH Key nicht korrekt (Newlines, Permissions)
2. Deploy Key nicht in GitHub aktiviert
3. known_hosts fehlt für github.com

**Lösung:** Secret neu erstellen mit korrektem Key-Format

### Problem: Application stuck in "OutOfSync"

**Diagnose:**
```bash
kubectl get application -n argocd argocd -o yaml
```

**Häufige Ursachen:**
1. Repository URL falsch
2. Path im Repository existiert nicht
3. Kustomization.yaml fehlerhaft

**Lösung:** Application löschen und neu erstellen

---

## Verwendete Versionen

| Komponente | Version | Hinweis |
|------------|---------|---------|
| ArgoCD | v3.3.0 | Neueste stabile Version |
| Kubernetes | 1.35 | K3s v1.35.0+k3s3 |
| kubectl | 1.35.0 | Auf Management-VM & Windows |
| Git | 2.43.0 | Auf Management-VM |

---

## Nächste Schritte

### Phase 3b: SOPS + Age (Optional)

Wenn Secrets in Git gespeichert werden sollen:
- [ ] Age Key-Pair generieren
- [ ] SOPS konfigurieren (.sops.yaml)
- [ ] ArgoCD Vault Plugin oder KSOPS
- [ ] Repository Secret verschlüsseln

**Timing:** Vor Phase 4 (Ingress benötigt IONOS API Secrets)

### Phase 4: Kubernetes-Basis

Folgende Komponenten werden in Phase 4 installiert:
- [ ] MetalLB (LoadBalancer)
- [ ] Traefik (Ingress Controller)
- [ ] Cert-Manager + IONOS Webhook (SSL-Zertifikate)
- [ ] Longhorn (Distributed Storage)

**Vorbereitung:**
- ✅ ArgoCD läuft und ist einsatzbereit
- ✅ GitOps-Struktur vorhanden
- ✅ Repository verbunden

---

## Wichtige Dateien und Pfade

### Im Git Repository

**Bootstrap:**
```
kubernetes/bootstrap/
├── namespace.yaml           # ArgoCD Namespace
├── argocd-app.yaml         # Self-Management Application
└── README.md               # Bootstrap-Dokumentation
```

**Base Configuration:**
```
kubernetes/base/argocd/
├── kustomization.yaml      # Kustomize Root
├── argocd-cm.yaml         # Repository Config
└── README.md              # Dokumentation
```

### Auf Windows Laptop

**kubeconfig:**
```
C:\Users\dhenke\.kube\config
```

**SSH Keys:**
```
C:\Users\dhenke\.ssh\argocd-deploy-key       # Private Key
C:\Users\dhenke\.ssh\argocd-deploy-key.pub   # Public Key (in GitHub)
```

### Auf Management-VM

**Repository:**
```
~/git/eneg-k8s-infrastructure-v2/
```

**kubeconfig:**
```
~/git/eneg-k8s-infrastructure-v2/kubeconfig-dev.yaml
```

---

## Kommandos Cheat Sheet

### ArgoCD UI Zugriff

```bash
# Port-Forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Browser öffnen
https://localhost:8080

# Login
Username: admin
Password: kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### ArgoCD CLI (Optional)

```bash
# Application Status
kubectl get application -n argocd

# Application Details
kubectl describe application argocd -n argocd

# Sync manuell triggern
kubectl patch application argocd -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### Repository Management

```bash
# Repository Secret anzeigen
kubectl get secret repo-eneg-k8s-infrastructure-v2 -n argocd -o yaml

# Repository Secret neu erstellen
kubectl delete secret repo-eneg-k8s-infrastructure-v2 -n argocd
kubectl create secret generic repo-eneg-k8s-infrastructure-v2 \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git \
  --from-file=sshPrivateKey=~/.ssh/argocd-deploy-key
kubectl label secret repo-eneg-k8s-infrastructure-v2 -n argocd \
  argocd.argoproj.io/secret-type=repository
```

### kubectl Context Management

```bash
# Verfügbare Contexts
kubectl config get-contexts

# Context wechseln
kubectl config use-context k8s-dev-k3s

# Aktueller Context
kubectl config current-context
```

---

## Git Commits (Phase 3)

Alle Änderungen wurden sauber committed und gepusht:

1. `5d88ac0` - Phase 3: Setup GitOps structure and ArgoCD bootstrap
2. `bf9a514` - Phase 3: ArgoCD self-management setup

**Dokumentation:**
- `kubernetes/bootstrap/README.md` - Bootstrap-Prozess
- `kubernetes/base/argocd/README.md` - Base Configuration

---

## Lessons Learned Summary

**DO:**
- ✅ Server-side apply für große CRDs verwenden
- ✅ Deploy Keys statt Personal Access Tokens
- ✅ Secrets NICHT in Git (bis SOPS kommt)
- ✅ App-of-Apps Pattern von Anfang an
- ✅ kubeconfig merge für alle Cluster
- ✅ Dokumentation direkt während der Arbeit schreiben

**DON'T:**
- ❌ Private Keys in Git committen
- ❌ Client-side apply für ArgoCD v3.x CRDs
- ❌ Secrets ohne Verschlüsselung in Git
- ❌ Repository-Zugriff mit write-Rechten
- ❌ Admin-Passwort im Plaintext speichern

---

## Offene Punkte für später

### SOPS + Age (Phase 3b)
- Secret-Management mit Verschlüsselung
- Repository Secret aus Git verwalten
- IONOS API Secret für Cert-Manager

### ArgoCD Konfiguration (später)
- RBAC (argocd-rbac-cm.yaml)
- Notifications (Slack/Teams Integration)
- SSO via Keycloak (Phase 6+)
- Ingress mit SSL (Phase 4)

### Multi-Cluster (TEST & PROD)
- Cluster-Credentials für TEST
- Cluster-Credentials für PROD
- ApplicationSets für alle Umgebungen

---

**Ende Phase 3 - GitOps-Fundament steht! Bereit für Phase 4!** 🚀
