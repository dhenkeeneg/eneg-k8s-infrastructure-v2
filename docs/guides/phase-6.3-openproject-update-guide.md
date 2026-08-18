# Handoff: Phase 6 — OpenProject Update + Odoo Deployment

> ## ⚠️ VERALTET — nicht mehr als Anleitung verwenden
>
> Dieses Dokument beschreibt den Stand vom 26.02.2026 (OpenProject 17.1.2).
> Das Update-Verfahren hat sich am 18.08.2026 grundlegend geaendert:
>
> - Die DB-Migration laeuft **automatisch im PreSync-Hook**, nicht mehr
>   manuell per `kubectl run ... rails db:migrate` (Abschnitt
>   "OpenProject Update-Prozedur" unten ist damit ueberholt).
> - Ab 17.4.0 ist `SECRET_KEY_BASE` zwingend, ab 17.5.0 zusaetzlich eine
>   **SSRF-Allowlist** — ohne sie brechen OIDC-Login und S3-Attachments,
>   und zwar bei gruenen Pods und gruenem ArgoCD.
> - Hocuspocus ist nicht mehr `latest`, sondern auf die Core-Version gepinnt.
>
> **Aktuelle Anleitung:** `docs/guides/phase-6.3-openproject-update-guide-v2.md`
>
> Das Dokument bleibt als Historie erhalten (u. a. wegen der
> Key-Learnings aus Phase 6.2 und des Odoo-Kontexts).

**Erstellt:** 26.02.2026
**Naechster Schritt:** OpenProject Update + Odoo Deployment
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Kontext fuer neuen Chat

Kopiere den folgenden Block als Startprompt in einen neuen Chat:

---

### Startprompt (kopieren)

```
Wir arbeiten gemeinsam an diesem Projekt "eNeG K8s Infrastruktur OpenTofuAnsible".
Es gibt drei verschiedenen Arbeitsumgebungen auf denen ich die Konfigurationen
fuer die Server anpasse:
- Einen Windows-Laptop mit Windows 11
- Einen MacMini
- Ein MacBook
Auf allen drei Umgebungen ist der Desktop-Commander eingerichtet und du hast
Terminalzugriff und Dateizugriff direkt auf mein geclontes Git Repository.
Pfad bei Windows ist: "C:\Users\dhenke\git\eneg-k8s-infrastructure-v2"
Der Pfad bei MacBook und MacMini ist jeweils:
"/Users/danielhenke/git/eneg-k8s-infrastructure-v2"
Erstelle noetige Dateien und Aenderungen eigenstaendig ueber Desktop-Commander
aber in Absprache mit mir.

Wir arbeiten an der DEV Umgebung mit den folgenden Servern:
k8s-dev-21, k8s-dev-22, k8s-dev-23

Du hast keinen direkten SSH Zugriff auf die Server. Dafuer arbeiten wir per
DevOps ueber GitHub und das lokale Repository.
Du fuehrst keine Commit und Push Befehle selbst aus.
Du fuehrst keine Befehle auf dem Management-Server
(k8s-mgmt-10 - 192.168.180.10) selbst aus.
Der Pfad zum Repository auf dem Managementserver ist:
"~/git/eneg-k8s-infrastructure-v2"
Im Repository gibt es den /docs-Pfad mit der gesamten Dokumentation.

Wir setzen Phase 6 fort. Bitte lies zuerst folgende Dokumente:
1. docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.3.md
2. docs/phases/phase-06-pilot-apps.md
3. docs/guides/phase-6-openproject-update-guide.md

Dann arbeite die folgenden Aufgaben der Reihe nach ab:

AUFGABE 1: OpenProject Update
- Es gibt ein neues Update fuer OpenProject
- Recherchiere die aktuelle stable Version
- Aktualisiere das Deployment (Image-Tag in deployment.yaml)
- Pruefe ob eine DB-Migration noetig ist
- Teste nach dem Update die Funktionalitaet (Web, Worker, Hocuspocus)

AUFGABE 2: Odoo Deployment (Phase 6.3) — falls Zeit
- Odoo Community Edition deployen
- Datenbank: Noch abstimmen ob MariaDB Galera Cluster oder postgres-erp (beide bereits vorhanden)
- DNS: odoo-dev-v2.eneg.de (CNAME auf traefik-dev.eneg.de)
- Deployment-Pattern: Raw Kubernetes Manifests (wie OpenProject)
- Secrets: SOPS-verschluesselt
- Vor der Implementierung Version und Architektur absprechen
```

---

## Aktueller Infrastruktur-Stand

### Laufende Komponenten

| Komponente | Version | Namespace | Status |
|---|---|---|---|
| K3s | v1.35.1+k3s1 | - | 3 Nodes Running |
| ArgoCD | v3.3.0 | argocd | Synced + Healthy |
| MetalLB | v0.15.3 | metallb-system | Active |
| Traefik | v3.6.7 | traefik | Active (192.168.180.100) |
| Cert-Manager | v1.17.2 | cert-manager | Ready |
| Longhorn | v1.9.2 | longhorn-system | 3x ~380GB |
| CNPG Operator | 1.28.1 | databases | Running |
| PostgreSQL (cnpg-shared) | 17 | databases | 3 Instanzen |
| PostgreSQL (cnpg-erp) | 17 | databases | 3 Instanzen |
| MariaDB Galera | 11.8.6 | databases | 3 Nodes |
| Garage S3 | v2.2.0 | garage | 3 Nodes, ~30GB eff. |
| Garage WebUI | 1.1.0 | garage | Running |
| n8n | 2.8.4 | n8n | Running |
| OpenProject | 17.1.2-slim | openproject | Running |
| Hocuspocus | latest | openproject | Running |
| Memcached | 1.6.40-alpine | openproject | Running |

### ArgoCD Sync-Wave Reihenfolge (aktuell)

| Wave | Application | Namespace |
|---|---|---|
| 0 | argocd | argocd |
| 1 | metallb, traefik | metallb-system, traefik |
| 2 | cert-manager, ionos-webhook | cert-manager |
| 3 | longhorn, cnpg-operator, mariadb-operator | diverse |
| 4 | cnpg-secrets, garage-secrets, garage-backup-secrets | databases, garage |
| 5 | cnpg-shared, cnpg-erp, mariadb-galera, garage | databases, garage |
| 6 | cnpg-databases, garage-backup | databases, garage |
| 7 | n8n-secrets, openproject-secrets | n8n, openproject |
| 8 | n8n, openproject | n8n, openproject |

### OpenProject Architektur (aktuell)

**Images:**
- Web/Worker/Seeder: `openproject/openproject:17.1.2-slim`
- Hocuspocus: `openproject/hocuspocus:latest`
- Memcached: `memcached:1.6.40-alpine`

**Deployments:**
- openproject-web (1 Replica, Port 8080)
- openproject-worker (1 Replica, Background Jobs)
- openproject-memcached (1 Replica, Port 11211)
- openproject-hocuspocus (1 Replica, Port 1234)

**Ingress:**
- `/*` → openproject-web:8080
- `/hocuspocus*` → openproject-hocuspocus:1234 (WebSocket)

**Datenbank:**
- cnpg-erp Cluster, User: openproject, DB: openproject
- Connection: `postgres://openproject:***@cnpg-erp-rw.databases.svc.cluster.local:5432/openproject`

**S3 Storage:**
- Bucket: openproject-assets (Garage intern)
- Key: openproject-app (GK50841c65af761abbb7f9126c)

**Secrets (openproject-secrets im openproject NS):**
- secret-key-base, hocuspocus-secret, database-url, s3-access-key-id, s3-secret-access-key

### OpenProject Update-Prozedur

Beim Update von OpenProject muessen folgende Schritte beachtet werden:

1. **Image-Tags aendern** in `deployment.yaml`:
   - openproject-web, openproject-worker, openproject-seeder: Alle auf neue Version
   - Hocuspocus Image ggf. separat pruefen

2. **DB-Migration ausfuehren** (falls noetig):
   ```bash
   kubectl run openproject-migrate -n openproject --rm -it --restart=Never \
     --image=openproject/openproject:<NEUE_VERSION>-slim \
     --overrides='{
       "spec": {
         "securityContext": {"fsGroup": 1000, "runAsUser": 1000, "runAsGroup": 1000},
         "containers": [{
           "name": "migrate",
           "image": "openproject/openproject:<NEUE_VERSION>-slim",
           "command": ["bash", "-c", "RAILS_ENV=production bundle exec rails db:migrate"],
           "env": [
             {"name": "DATABASE_URL", "valueFrom": {"secretKeyRef": {"name": "openproject-secrets", "key": "database-url"}}},
             {"name": "SECRET_KEY_BASE", "valueFrom": {"secretKeyRef": {"name": "openproject-secrets", "key": "secret-key-base"}}}
           ]
         }]
       }
     }'
   ```

3. **Pods neu starten:** ArgoCD synct automatisch nach Git-Push.
   Falls nicht: `kubectl rollout restart deployment -n openproject`

4. **Funktionstest:** Web-UI, Worker (Background Jobs), Hocuspocus (Dokument-Kollaboration)

### Etablierte Patterns

**Deployment-Pattern (Raw Manifests):**
```
kubernetes/base/apps/<app>/
  ├── namespace.yaml
  ├── deployment.yaml
  ├── service.yaml
  ├── ingress.yaml          # Certificate + IngressRoute (traefik NS)
  └── secrets/
      ├── kustomization.yaml
      ├── secret-generator.yaml
      ├── <app>-secrets.enc.yaml
      └── <app>-secrets.yaml.template
```

**Zwei-Secret-Pattern:**
1. DB-Credentials in databases Namespace (fuer CNPG managed.roles)
2. App-Secrets in App-Namespace (DB-Passwort Kopie + App-Keys)

**SOPS Verschluesselung:**
- Age Key: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
- Verschluesselung immer auf k8s-mgmt-10

**Git Workflow:**
1. Windows/Mac: Dateien erstellen/aendern
2. git add, commit, push
3. k8s-mgmt-10: git pull, SOPS encrypt, commit, push (nur fuer Secrets)
4. ArgoCD: auto-sync

---

## Key Learnings aus Phase 6.2

1. **Slim-Image hat kein Hocuspocus:** Separates Image `openproject/hocuspocus:latest` noetig
2. **Hocuspocus Port 1234** (nicht 4000)
3. **WebSocket-Route in Traefik:** PathPrefix `/hocuspocus` fuer externe Erreichbarkeit
4. **DB-Passwoerter nur alphanumerisch:** `openssl rand -hex 24` (keine Sonderzeichen)
5. **DB-Migration vor erstem Start:** Manuell via `kubectl run` wenn PostSync Hook blockiert
6. **NAS10 S3 Endpoint:** http://nas10.eneg.de:8010 (HTTP, nicht HTTPS)

---

*Dieses Dokument dient als Handoff-Anleitung fuer den naechsten Chat.*