# Phase 6: Pilot-App Deployment — Planungsdokument

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

---

## App-Versionen (abgestimmt)

| App | Image | Version | Datenbank | Cluster |
|---|---|---|---|---|
| n8n | n8nio/n8n | 2.8.4 | PostgreSQL | cnpg-shared |

Weitere Apps (OpenProject, Odoo, i-doit etc.) werden nach erfolgreichem
n8n-Deployment geplant und versioniert.

---

## Deployment-Reihenfolge

| Schritt | Beschreibung | Status |
|---|---|---|
| 6.1 | Grundstruktur: App-of-Apps fuer Applications | 🔲 Offen |
| 6.2 | n8n: DB-Rolle + Database + Secrets + Deployment + Ingress | 🔲 Offen |
| 6.3 | OpenProject: DB-Rolle + Database + Deployment + Ingress | 🔲 Offen |
| 6.4 | Odoo: DB-Rolle + Database + Deployment + Ingress | 🔲 Offen |
| 6.5 | Keycloak: DB-Rolle + Database + Deployment + Ingress | 🔲 Offen |
| 6.6 | Weitere Apps nach Bedarf | 🔲 Offen |
| 6.7 | Validierung + Dokumentation | 🔲 Offen |

**Begruendung der Reihenfolge:**
- n8n zuerst: Einfachste App (Single-Container, nur PostgreSQL), etabliert
  das gesamte Pattern (DB-Rolle → Database CRD → App-Deployment → Ingress)
- OpenProject danach: Mittlere Komplexitaet, validiert Pattern auf cnpg-erp
- Odoo: Komplexeste ERP-App
- Keycloak: Identity Management, Grundlage fuer SSO spaeterer Apps

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
                    └──────────┬───────────────┘
                               │ TCP :5432 / :3306
                    ┌──────────▼───────────────┐
                    │  databases namespace      │
                    │  ├── Database CRD         │
                    │  ├── Role (managed.roles) │
                    │  └── Password Secret      │
                    └──────────────────────────┘
```

---

## n8n Deployment-Details (Schritt 6.2)

### Komponenten

| Ressource | Namespace | Beschreibung |
|---|---|---|
| Database CRD | databases | `n8n` DB auf cnpg-shared, Owner: `n8n` |
| Role (managed) | databases | User `n8n` mit passwordSecret |
| Secret (DB-Passwort) | databases | SOPS-verschluesselt, fuer CNPG Role |
| Namespace | n8n | App-Namespace |
| Secret (Encryption Key) | n8n | SOPS-verschluesselt, n8n-interne Verschluesselung |
| PVC | n8n | 5Gi Longhorn fuer /home/node/.n8n |
| Deployment | n8n | n8nio/n8n:2.8.4, 1 Replica |
| Service | n8n | ClusterIP, Port 5678 |
| Certificate | traefik | n8n-dev-v2.eneg.de (Let's Encrypt) |
| IngressRoute | traefik | HTTPS → n8n.n8n.svc:5678 |

### n8n Umgebungsvariablen

| Variable | Wert | Quelle |
|---|---|---|
| DB_TYPE | postgresdb | ConfigMap/Env |
| DB_POSTGRESDB_HOST | cnpg-shared-rw.databases.svc.cluster.local | ConfigMap/Env |
| DB_POSTGRESDB_PORT | 5432 | ConfigMap/Env |
| DB_POSTGRESDB_DATABASE | n8n | ConfigMap/Env |
| DB_POSTGRESDB_USER | n8n | ConfigMap/Env |
| DB_POSTGRESDB_PASSWORD | (aus Secret) | Secret Ref |
| N8N_ENCRYPTION_KEY | (aus Secret) | Secret Ref |
| N8N_HOST | n8n-dev-v2.eneg.de | ConfigMap/Env |
| N8N_PROTOCOL | https | ConfigMap/Env |
| N8N_PORT | 5678 | ConfigMap/Env |
| GENERIC_TIMEZONE | Europe/Berlin | ConfigMap/Env |
| TZ | Europe/Berlin | ConfigMap/Env |
| N8N_EDITOR_BASE_URL | https://n8n-dev-v2.eneg.de | ConfigMap/Env |
| WEBHOOK_URL | https://n8n-dev-v2.eneg.de | ConfigMap/Env |

### n8n Resources (DEV-Dimensionierung)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 250m | 1 |
| Memory | 256Mi | 512Mi |
| PVC | 5Gi (Longhorn) | - |

---

## DNS-Eintraege (bereits angelegt)

| Hostname | Typ | Ziel |
|---|---|---|
| n8n-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de |
| openproject-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de |
| odoo-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de |
| idoit-dev-v2.eneg.de | CNAME | traefik-dev.eneg.de |

---

## Geplante Dateistruktur

```
kubernetes/
├── base/
│   ├── cloudnative-pg/
│   │   ├── cluster/
│   │   │   ├── cnpg-shared.yaml          # + managed.roles fuer App-User
│   │   │   └── cnpg-erp.yaml             # + managed.roles fuer App-User
│   │   └── databases/
│   │       └── n8n-database.yaml          # Database CRD
│   └── apps/
│       └── n8n/
│           ├── namespace.yaml             # Namespace: n8n
│           ├── deployment.yaml            # n8n Container + PVC
│           ├── service.yaml               # ClusterIP Service
│           ├── ingress.yaml               # Certificate + IngressRoute
│           └── secrets/
│               ├── kustomization.yaml     # KSOPS Generator
│               ├── secret-generator.yaml
│               └── n8n-secrets.enc.yaml   # SOPS (Encryption Key)
└── environments/
    └── dev/
        └── infrastructure/
            ├── cnpg-db-secrets-app.yaml   # DB-Passwort Secrets (KSOPS)
            ├── cnpg-databases-app.yaml    # Database CRDs
            └── n8n-app.yaml              # n8n Application
```

### Secrets-Struktur

```
kubernetes/base/cloudnative-pg/secrets/
├── kustomization.yaml
├── secret-generator.yaml
├── s3-credentials.enc.yaml           # (bestehend, Phase 5)
└── db-credentials.enc.yaml           # NEU: App-DB-Passwoerter

kubernetes/base/apps/n8n/secrets/
├── kustomization.yaml
├── secret-generator.yaml
└── n8n-secrets.enc.yaml              # n8n Encryption Key
```

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

## Skalierung ueber Umgebungen (spaeter)

| Parameter | DEV | TEST | PROD |
|---|---|---|---|
| n8n Replicas | 1 | 1 | 1 (oder Queue Mode) |
| n8n CPU Request | 250m | 500m | 500m |
| n8n Memory Request | 256Mi | 512Mi | 512Mi |
| n8n PVC | 5Gi | 10Gi | 20Gi |

---

## Aenderungshistorie

| Datum | Aenderung |
|---|---|
| 25.02.2026 | Initiale Version (Planungsdokument) |
