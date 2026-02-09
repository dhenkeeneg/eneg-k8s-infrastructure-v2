# ArgoCD Bootstrap

Dieses Verzeichnis enthält die initiale ArgoCD-Installation für das GitOps-Setup.

## Version

**ArgoCD:** v3.3.0 (aktuell stabil, Februar 2026)

## Installation

### Schritt 1: Namespace erstellen

```bash
kubectl apply -f namespace.yaml
```

### Schritt 2: ArgoCD installieren

```bash
# ArgoCD v3.3.0 installieren
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml
```

### Schritt 3: Warten bis alle Pods laufen

```bash
watch kubectl get pods -n argocd
```

Alle Pods sollten Status "Running" haben (dauert ca. 2-3 Minuten).

### Schritt 4: Admin-Passwort abrufen

```bash
# Initial Admin-Passwort
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

**Wichtig:** Speichern Sie dieses Passwort in 1Password!

### Schritt 5: ArgoCD UI Zugriff (Temporär)

```bash
# Port-Forward für lokalen Zugriff
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Dann öffnen: https://localhost:8080
- Username: `admin`
- Password: (aus Schritt 4)

**Hinweis:** In Phase 4 wird ArgoCD mit Ingress + Let's Encrypt SSL ausgestattet.

## Komponenten

ArgoCD install.yaml enthält:
- **argocd-server** - Web UI und API Server
- **argocd-repo-server** - Git Repository Management
- **argocd-application-controller** - Application Management
- **argocd-dex-server** - SSO/OIDC (optional)
- **argocd-redis** - Cache
- **argocd-applicationset-controller** - ApplicationSets

## Nächste Schritte

Nach erfolgreicher Installation:
1. ArgoCD Self-Management konfigurieren (App-of-Apps)
2. GitHub Repository als Source hinzufügen
3. SOPS + Age für Secret-Management
4. Erste Applications deployen

## Deinstallation (falls nötig)

```bash
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml
kubectl delete namespace argocd
```

## Dokumentation

- **Offizielle Docs:** https://argo-cd.readthedocs.io/en/stable/
- **Getting Started:** https://argo-cd.readthedocs.io/en/stable/getting_started/
- **Release Notes v3.3.0:** https://github.com/argoproj/argo-cd/releases/tag/v3.3.0
