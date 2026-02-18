# Phase 4: Kubernetes-Basis — Abschlussdokumentation

**Abgeschlossen am:** 18.02.2026
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Übersicht

Phase 4 hat die gesamte Kubernetes-Basis-Infrastruktur für den DEV-Cluster aufgebaut:
LoadBalancer, Ingress Controller, SSL-Zertifikatsverwaltung und das Ingress-Pattern
für alle zukünftigen Anwendungen.

## Installierte Komponenten

| Komponente | Version | Namespace | Beschreibung |
|---|---|---|---|
| MetalLB | v0.15.3 | metallb-system | L2 LoadBalancer |
| Traefik | v3.6.7 (Chart v39.0.0) | traefik | Ingress Controller, 2 Replicas |
| Cert-Manager | v1.17.2 | cert-manager | SSL-Zertifikatsverwaltung |
| IONOS Webhook | latest | cert-manager | DNS-01 Challenge Provider |
| KSOPS | v4.4.0 | argocd (repo-server) | SOPS-Entschlüsselung in ArgoCD |

## ArgoCD Applications

| Application | Typ | Source |
|---|---|---|
| metallb | Kustomize (remote) | github.com/metallb/metallb v0.15.3 |
| traefik | Helm (multi-source) | traefik/traefik Chart v39.0.0 + Git values |
| cert-manager | Helm (multi-source) | jetstack/cert-manager Chart v1.17.2 + Git values |
| cert-manager-webhook-ionos | Helm | fabmade/cert-manager-webhook-ionos |
| cert-manager-secrets | Kustomize + KSOPS | Git (SOPS-verschlüsseltes IONOS Secret) |
| cert-manager-config | Directory | Git (ClusterIssuers) |

## Netzwerk-Konfiguration

### MetalLB IP-Pool (DEV)

| Adresse | Verwendung |
|---|---|
| 192.168.180.100 | Traefik LoadBalancer (dediziert) |
| 192.168.180.151-199 | Allgemeiner Pool für weitere Services |

### DNS-Einträge (erstellt)

| Hostname | Typ | Ziel |
|---|---|---|
| traefik-dev.eneg.de | A | 192.168.180.100 |
| argocd-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de |

### SSL-Zertifikate (Let's Encrypt Production)

| Zertifikat | Namespace | DNS-Name |
|---|---|---|
| traefik-dashboard-tls | traefik | traefik-dev.eneg.de |
| argocd-server-tls | traefik | argocd-dev-v2.eneg.de |

## Architektur-Entscheidungen & Patterns

### Ingress-Pattern (Standard für alle Apps)

```
Internet/LAN
    │
    ▼
┌─────────────────────────────────┐
│  Traefik (192.168.180.100)      │
│  Namespace: traefik             │
│                                 │
│  - Certificate (cert-manager)   │
│  - IngressRoute                 │
│  - TLS-Terminierung             │
└──────────┬──────────────────────┘
           │ HTTP (port 80)
           │ cross-namespace
           ▼
┌─────────────────────────────────┐
│  Backend-App                    │
│  Namespace: <app-namespace>     │
│  - Service (ClusterIP, port 80) │
│  - Kein TLS nötig (intern)      │
└─────────────────────────────────┘
```

**Regeln:**
1. Certificate + IngressRoute immer im **traefik** Namespace
2. Backend-Service wird **cross-namespace** referenziert
3. Backend läuft auf **HTTP** (TLS wird von Traefik terminiert)
4. DNS-Einträge werden **einzeln** angelegt (kein Wildcard)

### ArgoCD Insecure Mode

ArgoCD Server läuft mit `server.insecure: true` (ConfigMap `argocd-cmd-params-cm`).
Das deaktiviert nur das interne TLS zwischen Traefik und ArgoCD.
Die externe Verbindung ist weiterhin HTTPS-verschlüsselt via Traefik + Let's Encrypt.

### Helm Chart Multi-Source Pattern

Für Helm-basierte ArgoCD Applications verwenden wir Multi-Source:
- **Source 1:** Helm Chart aus externem Repository
- **Source 2:** Values-Datei aus unserem Git Repository (ref: values)

```yaml
sources:
  - repoURL: https://charts.example.io
    chart: app-name
    targetRevision: v1.0.0
    helm:
      releaseName: app-name
      valueFiles:
        - $values/kubernetes/base/app-name/values.yaml
  - repoURL: git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git
    targetRevision: main
    ref: values
```

## Key Learnings

### Traefik Helm Chart v39.0.0 Breaking Change

Chart v39.0.0 erzwingt Schema-Validierung. Die `redirections` und `tls` Felder
benötigen eine zusätzliche `http:`-Verschachtelung:

```yaml
# FALSCH (< v39.0.0)
ports:
  web:
    redirections:
      entryPoint:
        to: websecure

# RICHTIG (v39.0.0+)
ports:
  web:
    http:
      redirections:
        entryPoint:
          to: websecure
```

Referenz: PR traefik/traefik-helm-chart#1603

### Traefik Cross-Namespace TLS Secrets

Traefik kann Secrets nur in Namespaces lesen, auf die es RBAC-Zugriff hat.
Das Standardverhalten bei `allowCrossNamespace: true` erlaubt cross-namespace
Service-Referenzen, aber TLS-Secrets müssen im **traefik** Namespace liegen.

**Lösung:** Alle Certificates und IngressRoutes im traefik Namespace erstellen.

### KSOPS Funktionstest

Erster erfolgreicher KSOPS-Test: IONOS API-Credentials werden automatisch
von ArgoCD entschlüsselt und als Kubernetes Secret im cert-manager Namespace
deployt. Kette: Git (verschlüsselt) → ArgoCD → KSOPS → SOPS + Age → Kubernetes Secret.

### Cert-Manager DNS-01 Split-DNS

In Umgebungen mit internem DNS-Server muss cert-manager für DNS-01 Challenges
externe Nameserver verwenden:

```yaml
extraArgs:
  - --dns01-recursive-nameservers=8.8.8.8:53,1.1.1.1:53
  - --dns01-recursive-nameservers-only
```

### Helm Repos für ArgoCD

Externe Helm Repositories müssen als Secrets in ArgoCD registriert werden:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-name
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: helm
  name: repo-name
  url: https://charts.example.io
```

## Dateistruktur

```
kubernetes/
├── base/
│   ├── argocd/
│   │   ├── argocd-ingress.yaml           # ArgoCD IngressRoute + Certificate
│   │   ├── traefik-helm-repo.yaml         # Helm Repo Secret
│   │   ├── jetstack-helm-repo.yaml        # Helm Repo Secret
│   │   └── ionos-webhook-helm-repo.yaml   # Helm Repo Secret
│   ├── metallb/
│   │   ├── kustomization.yaml             # Remote Kustomize + lokale Config
│   │   ├── ipaddresspool.yaml             # IP-Pool DEV
│   │   └── l2advertisement.yaml           # L2 Advertisement
│   ├── traefik/
│   │   ├── values.yaml                    # Helm Values
│   │   └── certificate.yaml               # Dashboard TLS Certificate
│   └── cert-manager/
│       ├── values.yaml                    # Helm Values
│       ├── clusterissuer-staging.yaml     # Let's Encrypt Staging
│       ├── clusterissuer-prod.yaml        # Let's Encrypt Production
│       └── secrets/
│           ├── kustomization.yaml         # KSOPS Kustomization
│           ├── secret-generator.yaml      # KSOPS Generator
│           └── ionos-secret.enc.yaml      # Verschlüsseltes IONOS Secret
└── environments/
    └── dev/
        └── infrastructure/
            ├── metallb-app.yaml
            ├── traefik-app.yaml
            ├── cert-manager-app.yaml
            ├── cert-manager-webhook-ionos-app.yaml
            ├── cert-manager-secrets-app.yaml
            └── cert-manager-config-app.yaml
```

## Nächste Schritte

- **Phase 4.4:** Longhorn (Distributed Block Storage)
- **Phase 5:** Datenbank-Cluster (CloudNativePG, MariaDB Galera)
- **Neue Apps:** Ingress-Pattern anwenden (Certificate + IngressRoute in traefik NS)
