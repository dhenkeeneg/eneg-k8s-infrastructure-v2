# ArgoCD Base Configuration

## Übersicht

Dieses Verzeichnis enthält die ArgoCD-Konfiguration, die via App-of-Apps Self-Management synchronisiert wird.

## Dateien

| Datei | Beschreibung |
|-------|-------------|
| `argocd-cm.yaml` | ConfigMap mit KSOPS/Kustomize Build-Options |
| `argocd-repo-server-ksops-patch.yaml` | Strategic Merge Patch: KSOPS v4.4.0 im Repo-Server |
| `argocd-imagepullpolicy-patch.yaml` | Strategic Merge Patches: imagePullPolicy=IfNotPresent fuer alle ArgoCD-Workloads |
| `kustomization.yaml` | Kustomize Root (bindet alles zusammen) |
| `secrets/` | SOPS-verschlüsselte Secrets |

## KSOPS Integration

ArgoCD verwendet KSOPS (Kustomize-SOPS) v4.4.0, um SOPS-verschlüsselte Secrets
automatisch beim Sync zu entschlüsseln.

### Wie es funktioniert

1. Ein **Init-Container** (`viaductoss/ksops:v4.4.0`) kopiert die `ksops` und `kustomize` Binaries
2. Der **Age Private Key** wird als Kubernetes Secret (`sops-age`) im argocd Namespace bereitgestellt
3. Die **ConfigMap** (`argocd-cm`) aktiviert `--enable-alpha-plugins --enable-exec`
4. ArgoCD baut Kustomize mit KSOPS und entschlüsselt dabei automatisch

### Voraussetzung: Age-Key Secret

Das Secret `sops-age` muss **manuell** im Cluster erstellt werden (einmalig):

```bash
kubectl create secret generic sops-age \
  --from-file=keys.txt=/path/to/age/key.txt \
  -n argocd
```

### Secret-Generator Pattern

Für jede App mit SOPS-Secrets wird ein `secret-generator.yaml` erstellt:

```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: my-secret-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secrets/my-secret.enc.yaml
```

Und in der `kustomization.yaml` referenziert:

```yaml
generators:
  - secret-generator.yaml
```

## imagePullPolicy Patch

Alle ArgoCD-Workloads werden mit `imagePullPolicy: IfNotPresent` gepatcht, damit
beim Drain/Reschedule (z.B. Node-OS-Update) keine erneuten Image-Pulls erzwungen
werden. Hintergrund: DEV-OS-Update am 30.04.2026 (siehe
`docs/phases/phase-11-rolling-os-update-dev.md`) hat gezeigt, dass `Always` in
Kombination mit Registry-Latenz/Ausfall zu kaskadierten Pull-Fehlern fuehren kann.

### Pattern

Wie der KSOPS-Patch wird auch dieser Patch **NICHT** ueber ArgoCD self-sync
angewendet, sondern manuell. Quelle der Wahrheit ist
`argocd-imagepullpolicy-patch.yaml` im Repo. Die Anwendung erfolgt per
Helper-Skript:

```bash
./scripts/maintenance/apply-argocd-imagepullpolicy.sh <kube-context>
```

Beispiel:

```bash
./scripts/maintenance/apply-argocd-imagepullpolicy.sh k8s-dev
./scripts/maintenance/apply-argocd-imagepullpolicy.sh k8s-test
./scripts/maintenance/apply-argocd-imagepullpolicy.sh k8s-prod
```

### Wann re-applizieren?

- Nach jedem ArgoCD-Reinstall
- Nach jedem ArgoCD-Versions-Upgrade (wenn die Workload-Manifests neu deployed werden)
- Nach Hinzufuegen weiterer ArgoCD-Komponenten

Das Skript ist **idempotent** - Re-Apply bleibt ohne Effekt, wenn die Werte
bereits korrekt sind.
