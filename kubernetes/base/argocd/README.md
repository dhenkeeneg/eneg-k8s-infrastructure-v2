# ArgoCD Base Configuration

Diese Konfiguration wird von ArgoCD selbst verwaltet (App-of-Apps Pattern).

## Struktur

```
base/argocd/
├── README.md                           # Diese Datei
├── kustomization.yaml                  # Kustomize Einstiegspunkt
├── argocd-cm.yaml                      # ConfigMap für Repository
├── repository-secret-template.yaml     # Template (Secret wird manuell erstellt)
└── namespace.yaml                      # ArgoCD Namespace (bereits existiert)
```

## Self-Management

ArgoCD verwaltet seine eigene Konfiguration aus diesem Git-Repository.

**Application:** `argocd` (im Namespace `argocd`)
**Source:** `kubernetes/base/argocd`
**Destination:** Cluster: `in-cluster`, Namespace: `argocd`

## Secrets

**Wichtig:** Das Repository-Secret wird NICHT in Git committed!

Manuell erstellen:
```bash
kubectl create secret generic repo-eneg-k8s-infrastructure-v2 \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git \
  --from-file=sshPrivateKey=~/.ssh/argocd-deploy-key

kubectl label secret repo-eneg-k8s-infrastructure-v2 -n argocd \
  argocd.argoproj.io/secret-type=repository
```

Später: SOPS + Age für Secret-Management
