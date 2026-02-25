# Phase 6: Pilot-App Deployment

**Status:** 🔄 In Bearbeitung
**Gestartet am:** 25.02.2026
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Zusammenfassung

Phase 6 baut auf der in Phase 5 erstellten Datenbank-Infrastruktur auf und
deployt die ersten Pilot-Anwendungen in den DEV-Cluster. Jede App erhaelt
eine eigene Datenbank, einen dedizierten DB-User mit eigenem Secret und
eine vollstaendige Ingress-Konfiguration mit TLS-Zertifikat. Das Deployment
erfolgt GitOps-konform ueber ArgoCD mit Raw Kubernetes Manifests.

---

## Architektur-Entscheidungen

### Deployment-Methode: Raw Kubernetes Manifests (kein Helm)

**Entscheidung:** Alle Pilot-Apps werden als Raw Manifests deployed.

**Begruendung:**
- n8n hat kein offizielles Helm Chart; Community-Charts (8gears) nutzen
  OCI-Registry und haben Kompatibilitaetsluecken mit n8n 2.x
- Raw Manifests geben volle Kontrolle ueber alle Ressourcen
- Konsistent mit dem bestehenden Ingress/Certificate-Pattern aus Phase 4
- Einfacher zu debuggen und anzupassen als Helm-Templates
- Spaeterer Wechsel auf Helm ist jederzeit moeglich

### DB-User-Strategie: Dedizierte Rollen pro App

**Entscheidung:** Jede App erhaelt einen eigenen PostgreSQL-User bzw.
MariaDB-User mit eigenem SOPS-verschluesseltem Secret — in allen
Umgebungen (DEV, TEST, PROD).

**Begruendung:**
- Least-Privilege-Prinzip: Jede App kann nur ihre eigene Datenbank sehen
- Sicherheit: Kompromittierte App-Credentials gefaehrden nicht andere DBs
- Audit: Datenbankzugriffe sind pro App nachvollziehbar
- Konsistenz: Gleiche Architektur in DEV, TEST und PROD

**Implementierung PostgreSQL (CNPG):**
- Rollen werden deklarativ ueber `managed.roles` in der Cluster-CRD definiert
- Passwoerter werden als SOPS-verschluesselte Kubernetes Secrets gespeichert
- CNPG referenziert die Secrets ueber `passwordSecret` in der Rollen-Definition
- Database CRD setzt die Rolle als Owner der jeweiligen Datenbank

**Implementierung MariaDB (Galera):**
- `Database`, `User` und `Grant` CRDs des mariadb-operator
- Passwoerter als SOPS-verschluesselte Kubernetes Secrets

### Ingress-Pattern: Standard aus Phase 4

Alle Apps folgen dem etablierten Pattern:
- Certificate + IngressRoute im **traefik** Namespace
- Backend-Service wird **cross-namespace** referenziert
- TLS-Terminierung durch Traefik, Backend laeuft auf HTTP

### Secrets-Pattern: Zwei getrennte Secrets pro App

**Entscheidung:** Jede App benoetigt zwei SOPS-verschluesselte Secrets:

1. **DB-Credentials** (Namespace: `databases`) — fuer CNPG managed.roles
2. **App-Secrets** (Namespace: `<app>`) — DB-Passwort (Kopie) + App-spezifische Keys

**Begruendung:** Kubernetes erlaubt keine Cross-Namespace Secret-Referenzen.
Das DB-Passwort muss sowohl im `databases` Namespace (fuer CNPG Role) als
auch im App-Namespace (fuer die App-Umgebungsvariablen) vorliegen. Beide
Secrets werden getrennt mit SOPS verschluesselt und via KSOPS deployed.

---

## Deployment-Reihenfolge

| Schritt | Beschreibung | Status |
|---|---|---|
| 6.1 | n8n: DB-Rolle + Database + Secrets + Deployment + Ingress | ✅ Abgeschlossen |
| 6.2 | OpenProject: DB-Rolle + Database + Deployment + Ingress | 🔲 Offen |
| 6.3 | Odoo: DB-Rolle + Database + Deployment + Ingress | 🔲 Offen |
| 6.4 | Keycloak: DB-Rolle + Database + Deployment + Ingress | 🔲 Offen |
| 6.5 | Weitere Apps nach Bedarf | 🔲 Offen |
| 6.6 | Validierung + Dokumentation | 🔲 Offen |

---

## Architektur pro App

```
                    ┌──────────────────────────┐
                    │  traefik namespace        │
                    │  ├── Certificate          │
                    │  └── IngressRoute         │
                    │       (<app>-dev-v2.eneg.de)│
                    └──────────┬───────────────┘
                               │ cross-namespace (HTTP)
                    ┌──────────▼───────────────┐
                    │  <app> namespace          │
                    │  ├── Deployment           │
                    │  ├── Service (ClusterIP)  │
                    │  ├── PVC (Longhorn)       │
                    │  └── Secret (SOPS)        │
                    │       (db-password +      │
                    │        app-specific keys) │
                    └──────────┬───────────────┘
                               │ TCP :5432 / :3306
                    ┌──────────▼───────────────┐
                    │  databases namespace      │
                    │  ├── Database CRD         │
                    │  ├── Role (managed.roles) │
                    │  └── Password Secret      │
                    │       (SOPS, fuer CNPG)   │
                    └──────────────────────────┘
```

---

## ArgoCD Sync-Wave Reihenfolge

| Wave | Application | Beschreibung |
|---|---|---|
| 4 | cnpg-secrets | DB-Passwoerter + S3-Credentials (KSOPS) |
| 5 | cnpg-cluster | PostgreSQL Cluster + managed.roles |
| 6 | cnpg-databases | Database CRDs (n8n, etc.) |
| 7 | n8n-secrets | App-Secrets: Encryption Key + DB-Passwort (KSOPS) |
| 8 | n8n | App-Deployment: Namespace, Deployment, Service, PVC, Ingress |

---

## Abgeschlossene Deployments

### 6.1 — n8n Workflow-Automation ✅

**Abgeschlossen am:** 25.02.2026
**URL:** https://n8n-dev-v2.eneg.de
**Version:** n8nio/n8n:2.8.4 (Community Edition)

#### Installierte Komponenten

| Ressource | Namespace | Name | Status |
|---|---|---|---|
| Database CRD | databases | n8n | ✅ Erstellt |
| Managed Role | databases | n8n (auf cnpg-shared) | ✅ Login aktiv |
| Secret (DB) | databases | n8n-db-credentials | ✅ SOPS/KSOPS |
| Namespace | n8n | n8n | ✅ Erstellt |
| Secret (App) | n8n | n8n-secrets | ✅ SOPS/KSOPS |
| PVC | n8n | n8n-data (5Gi Longhorn) | ✅ Bound |
| Deployment | n8n | n8n (1 Replica) | ✅ Running |
| Service | n8n | n8n (ClusterIP:5678) | ✅ Active |
| Certificate | traefik | n8n-tls | ✅ Ready (Let's Encrypt) |
| IngressRoute | traefik | n8n | ✅ Active |

#### ArgoCD Applications

| Application | Sync | Health | Wave |
|---|---|---|---|
| cnpg-databases | Synced | Healthy | 6 |
| n8n-secrets | Synced | Healthy | 7 |
| n8n | Synced | Healthy | 8 |

#### n8n Umgebungsvariablen

| Variable | Wert | Quelle |
|---|---|---|
| DB_TYPE | postgresdb | Env |
| DB_POSTGRESDB_HOST | cnpg-shared-rw.databases.svc.cluster.local | Env |
| DB_POSTGRESDB_PORT | 5432 | Env |
| DB_POSTGRESDB_DATABASE | n8n | Env |
| DB_POSTGRESDB_USER | n8n | Env |
| DB_POSTGRESDB_PASSWORD | (verschluesselt) | Secret: n8n-secrets/db-password |
| N8N_ENCRYPTION_KEY | (verschluesselt) | Secret: n8n-secrets/encryption-key |
| N8N_HOST | n8n-dev-v2.eneg.de | Env |
| N8N_PROTOCOL | https | Env |
| N8N_PORT | 5678 | Env |
| N8N_EDITOR_BASE_URL | https://n8n-dev-v2.eneg.de | Env |
| WEBHOOK_URL | https://n8n-dev-v2.eneg.de | Env |
| GENERIC_TIMEZONE | Europe/Berlin | Env |
| TZ | Europe/Berlin | Env |

#### n8n Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 250m | 1 |
| Memory | 256Mi | 512Mi |
| PVC | 5Gi (Longhorn) | - |

#### n8n Hinweise

- **Community Edition:** Nur ein User (Owner) moeglich, keine Team-Features
- **securityContext:** Erforderlich wegen n8n User `node` (UID/GID 1000),
  Longhorn Volumes werden standardmaessig als root gemountet
- **Deployment-Strategie:** `Recreate` (nicht RollingUpdate) da PVC
  mit ReadWriteOnce nur von einem Pod gleichzeitig gemountet werden kann

---

## DNS-Eintraege

| Hostname | Typ | Ziel | App | Status |
|---|---|---|---|---|
| n8n-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | n8n | ✅ Aktiv |
| openproject-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | OpenProject | 🔲 Vorbereitet |
| odoo-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | Odoo | 🔲 Vorbereitet |
| idoit-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de | i-doit | 🔲 Vorbereitet |

---

## Backup-Abdeckung

Alle neuen Datenbanken sind automatisch durch die bestehende Backup-Strategie
aus Phase 5 abgedeckt:

| Backup-Typ | Abdeckung | Begruendung |
|---|---|---|
| WAL-Archivierung | ✅ Automatisch | Laeuft auf Cluster-Ebene |
| Physical Backup (Barman) | ✅ Automatisch | ScheduledBackup auf Cluster-Ebene |
| Logical Backup (pg_dumpall) | ✅ Automatisch | Dumpt alle DBs inkl. neuer |

**Keine Konfigurationsaenderung an den Backups noetig.**

---

## Key Learnings

### 1. Longhorn Volumes und Non-Root Container

Longhorn Volumes werden standardmaessig mit Root-Ownership gemountet.
Apps die als Non-Root User laufen (z.B. n8n als UID 1000) erhalten
`EACCES: permission denied`. **Loesung:** `securityContext` im Pod-Spec:

```yaml
spec:
  securityContext:
    fsGroup: 1000
    runAsUser: 1000
    runAsGroup: 1000
```

### 2. Cross-Namespace Secrets nicht moeglich

Kubernetes erlaubt keine Secret-Referenzen ueber Namespace-Grenzen.
Wenn eine DB-Rolle (databases NS) und eine App (eigener NS) dasselbe
Passwort brauchen, muss das Secret in beiden Namespaces existieren.
Pattern: Zwei getrennte SOPS-Secrets mit identischem Passwort.

### 3. CNPG Managed Roles — Defaults explizit angeben

CNPG ergaenzt Default-Werte (`connectionLimit: -1`, `ensure: present`,
`inherit: true`) automatisch. Bei ServerSideApply fuehrt das zu einem
permanenten OutOfSync in ArgoCD. **Loesung:** Defaults explizit in
der Cluster-CRD angeben.

### 4. ServerSideApply und --force sind inkompatibel

ArgoCD mit `ServerSideApply=true` kann nicht mit `--force` gesynct werden.
Fehlermeldung: `--force cannot be used with --server-side`. Bei OutOfSync
durch Default-Werte stattdessen die Manifeste anpassen.

### 5. SOPS Age-Key Symlink auf Management-Server

SOPS sucht den Age-Key im Standard-Pfad `~/.config/sops/age/keys.txt`.
Wenn der Key an anderer Stelle liegt (z.B. im Repo unter `.age/key.txt`),
einen Symlink setzen:

```bash
mkdir -p ~/.config/sops/age/
ln -s ~/git/eneg-k8s-infrastructure-v2/.age/key.txt ~/.config/sops/age/keys.txt
```

### 6. ArgoCD Cache bei neuen KSOPS-Secrets

Wenn ein neues SOPS-verschluesseltes Secret zum Repository hinzugefuegt wird,
erkennt ArgoCD die Datei moeglicherweise nicht sofort. **Loesung:** Hard Refresh
auf der betroffenen Application erzwingen:

```bash
kubectl -n argocd patch application <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

---

## Dateistruktur (aktuell)

```
kubernetes/
├── base/
│   ├── cloudnative-pg/
│   │   ├── cluster/
│   │   │   ├── cnpg-shared.yaml          # + managed.roles: n8n
│   │   │   └── cnpg-erp.yaml
│   │   ├── databases/
│   │   │   └── n8n-database.yaml          # Database CRD
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml      # KSOPS: s3 + n8n-db
│   │       ├── s3-credentials.enc.yaml
│   │       ├── n8n-db-credentials.enc.yaml
│   │       └── *.yaml.template            # Vorlagen (nicht committet)
│   └── apps/
│       └── n8n/
│           ├── namespace.yaml
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml               # Certificate + IngressRoute
│           └── secrets/
│               ├── kustomization.yaml
│               ├── secret-generator.yaml
│               ├── n8n-secrets.enc.yaml
│               └── n8n-secrets.yaml.template
└── environments/
    └── dev/
        └── infrastructure/
            ├── cnpg-databases-app.yaml    # ArgoCD App (Wave 6)
            ├── n8n-secrets-app.yaml       # ArgoCD App (Wave 7)
            ├── n8n-app.yaml               # ArgoCD App (Wave 8)
            └── ... (bestehende Apps)
```

---

## Skalierung ueber Umgebungen (spaeter)

| Parameter | DEV | TEST | PROD |
|---|---|---|---|
| n8n Replicas | 1 | 1 | 1 (oder Queue Mode) |
| n8n CPU Request | 250m | 500m | 500m |
| n8n Memory Request | 256Mi | 512Mi | 512Mi |
| n8n PVC | 5Gi | 10Gi | 20Gi |

---

## Naechste Schritte

- OpenProject deployen (cnpg-erp Cluster)
- Odoo deployen (MariaDB Galera)
- Keycloak deployen (cnpg-shared)
- Weitere Apps nach Bedarf

---

## Aenderungshistorie

| Datum | Aenderung |
|---|---|
| 25.02.2026 | Initiale Version (Planungsdokument) |
| 25.02.2026 | n8n erfolgreich deployed (Schritt 6.1 abgeschlossen) |
