# ArgoCD Base Configuration

Diese Konfiguration enthält die grundlegende ArgoCD-Installation mit SOPS-Support für verschlüsselte Secrets.

## SOPS-Integration

ArgoCD ist so konfiguriert, dass es SOPS-verschlüsselte Secrets automatisch entschlüsseln kann:

### Komponenten:
- **argocd-cm.yaml**: ArgoCD ConfigMap mit SOPS-Plugin Konfiguration
- **age-secret-sealed.yaml**: Template für Age Private Key Secret (nicht im Git!)
- **repository-secret.enc.yaml**: SOPS-verschlüsselter GitHub Deploy Key

### Age Key Setup (einmalig auf Management-VM):

```bash
# 1. Age Secret für ArgoCD erstellen
kubectl create secret generic argocd-age-key \
  --from-file=age.agekey=/home/admin-ubuntu/.age/key.txt \
  -n argocd

# 2. Verification
kubectl get secret argocd-age-key -n argocd
```

### Funktionsweise:
1. Init Container lädt SOPS und Age binaries herunter
2. Age Private Key wird als Secret gemountet
3. SOPS nutzt den Key zur Entschlüsselung von `.enc.yaml` Dateien
4. ArgoCD kann verschlüsselte Secrets aus Git deployen

### Test:
Nach dem Deployment sollte ArgoCD die verschlüsselten Repository-Credentials nutzen können:

```bash
# ArgoCD Repo Server Logs prüfen
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50
```

## Nächste Schritte:
- Phase 4: MetalLB, Traefik, Cert-Manager, Longhorn via ArgoCD deployen
