# Handoff: Phase 6.4 — Keycloak Deployment

**Erstellt:** 02.03.2026
**Naechster Schritt:** Keycloak 26.5.4 deployen
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
Die Server der Testumgebung werden dann heissen: k8s-test-21, k8s-test-22, k8s-test23
Die Server der Produktivumgebung werden dann heissen k8s-prod-21, k8s-prod-22, k8s-prod-23
Test- und Produktivumgebung werden in einer spaeteren Phase erst erstellt.

Du hast keinen direkten SSH Zugriff auf die Server. Dafuer arbeiten wir per
DevOps ueber GitHub und das lokale Repository auf dem Windows-Laptop oder
den MacBook und MacMini.
Du fuehrst keine Commit und Push Befehle selbst aus. Du gibst mir die
entsprechenden Anweisungen und ich fuehre diese in einem gesonderten
Terminal dann selbst aus.

Du fuehrst keine Befehle auf dem Management-Server (k8s-mgmt-10 - 192.168.180.10)
selbst aus. Wenn noetig, gibst du mir die entsprechenden Anweisungen und ich
fuehre diese in einem gesonderten Terminal dann selbst aus. Immer wenn es
moeglich ist sollen die Anpassungen ueber GitOps laufen und nicht direkt
auf den Servern.
Der Pfad zum Repository auf dem Managementserver (k8s-mgmt-10) ist:
"~/git/eneg-k8s-infrastructure-v2"
Im Repository gibt es den /docs-Pfad. Darin sind alle Entscheidungen,
die Projektplanung und der Projektfortschritt dokumentiert.
Lies die Dokumentation zu beginn des Chats und merke sie dir wenn moeglich
im Projektwissen.
Nach erfolgreichem Abschluss einer Phase wirst Du die Dokumentation
entsprechend anpassen und erweitern.

Wir setzen Phase 6 fort mit Schritt 6.4: Keycloak Deployment.
Bitte lies zuerst folgende Dokumente:
1. docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.3.md
2. docs/phases/phase-06-pilot-apps.md
3. docs/guides/phase-6.4-chat-anweisung-keycloak.md

Dann deploye Keycloak gemaess der unten beschriebenen Architektur.
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
| Odoo 18 CE | 18.0-20260217 | odoo | Running (Multi-Process) |

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
| 7 | n8n-secrets, openproject-secrets, odoo-secrets, odoo-backup-secrets | diverse |
| 8 | n8n, openproject, odoo | n8n, openproject, odoo |
| 9 | odoo-backup | odoo |

---

## Keycloak 26.5.4 — Geplante Architektur

### Eckdaten

| Parameter | Wert |
|---|---|
| Version | Keycloak 26.5.4 |
| Docker Image | `quay.io/keycloak/keycloak:26.5.4` |
| Datenbank | cnpg-shared Cluster (PostgreSQL 17) |
| DB-User | keycloak (neue managed.role auf cnpg-shared) |
| DB-Name | keycloak |
| Modus | Production (`start`, nicht `start-dev`) |
| Replicas | 1 (DEV), spaeter 2+ fuer HA |
| DNS | keycloak-dev-v2.eneg.de (CNAME auf traefik-dev.eneg.de) |
| Admin-User | Ueber ENV-Variablen beim ersten Start (KC_BOOTSTRAP_ADMIN_*) |
| Proxy | Edge-Modus (TLS-Terminierung durch Traefik) |
| ArgoCD Waves | 7 (Secrets), 8 (App) |
| Zweck | AD-Anbindung, SSO fuer OpenProject, Odoo, n8n, i-doit etc. |

### Warum Production-Mode

Keycloak unterscheidet zwischen `start-dev` (Entwicklung) und `start`
(Production). Im Production-Mode:
- Caching ist optimiert
- Health/Metrics Endpoints verfuegbar
- Hostname-Validation aktiv
- Keine automatische Feature-Detection

Fuer DEV nutzen wir trotzdem den Production-Mode, da wir hinter einem
Reverse-Proxy (Traefik) mit TLS laufen und die Konfiguration konsistent
mit TEST/PROD sein soll.

### Proxy-Konfiguration

Keycloak laeuft hinter Traefik (TLS-Terminierung). Dafuer wird der
Proxy-Modus `edge` verwendet:
- Traefik terminiert TLS und leitet HTTP an Keycloak weiter
- Keycloak erhaelt die Original-Headers (X-Forwarded-*)
- `KC_PROXY_HEADERS=xforwarded` (Keycloak 26+ Konfiguration)
- `KC_HTTP_ENABLED=true` (HTTP innerhalb des Clusters)
- `KC_HOSTNAME=keycloak-dev-v2.eneg.de`

### Architektur-Diagramm

```
Browser (https://keycloak-dev-v2.eneg.de)
    |
Traefik (TLS-Terminierung)
    |
    └── /* → keycloak:8080 (HTTP)
                  |
                  ├── PostgreSQL (cnpg-shared-rw:5432) — Datenbank
                  └── Active Directory (spaeter: LDAPS)
```

---

## Deployment-Schritte (Reihenfolge)

### Schritt 1: Datenbank vorbereiten

1. Neue managed.role `keycloak` auf cnpg-shared Cluster hinzufuegen
2. SOPS-Secret `keycloak-db-credentials` in databases Namespace
3. Database CRD `keycloak` mit Owner `keycloak`
4. cnpg-shared.yaml anpassen (managed.roles erweitern)
5. cnpg-databases erweitern (keycloak-database.yaml)
6. CNPG-Secrets erweitern (keycloak-db-credentials)

### Schritt 2: App-Secrets erstellen

SOPS-Secret `keycloak-secrets` in keycloak Namespace:
- `db-password` (identisch mit DB-Credentials)
- `admin-password` (Bootstrap Admin-Passwort fuer ersten Login)

ArgoCD Application `keycloak-secrets` (Wave 7)

### Schritt 3: Keycloak Deployment erstellen

Dateien unter `kubernetes/base/apps/keycloak/`:
- `namespace.yaml`
- `deployment.yaml` (Production-Mode, ENV-basierte Konfiguration)
- `service.yaml` (Port 8080)
- `ingress.yaml` (Certificate + IngressRoute)

Keycloak wird komplett ueber Umgebungsvariablen konfiguriert (kein
ConfigMap/odoo.conf-Pattern noetig):

| ENV-Variable | Wert | Beschreibung |
|---|---|---|
| KC_DB | postgres | Datenbank-Typ |
| KC_DB_URL_HOST | cnpg-shared-rw.databases.svc.cluster.local | DB Host |
| KC_DB_URL_PORT | 5432 | DB Port |
| KC_DB_URL_DATABASE | keycloak | DB Name |
| KC_DB_USERNAME | keycloak | DB User |
| KC_DB_PASSWORD | (aus Secret) | DB Passwort |
| KC_PROXY_HEADERS | xforwarded | Proxy-Modus fuer Traefik |
| KC_HTTP_ENABLED | true | HTTP im Cluster |
| KC_HOSTNAME | keycloak-dev-v2.eneg.de | Externer Hostname |
| KC_HEALTH_ENABLED | true | Health-Endpoints |
| KC_METRICS_ENABLED | true | Metrics fuer Prometheus |
| KC_BOOTSTRAP_ADMIN_USERNAME | admin | Initialer Admin (nur erster Start) |
| KC_BOOTSTRAP_ADMIN_PASSWORD | (aus Secret) | Admin-Passwort |

### Schritt 4: ArgoCD Applications

- `keycloak-secrets-app.yaml` (Wave 7)
- `keycloak-app.yaml` (Wave 8)

### Schritt 5: DNS + Test

1. CNAME `keycloak-dev-v2.eneg.de` -> `traefik-dev.eneg.de` (IONOS)
2. Warten auf Certificate (Let's Encrypt)
3. Keycloak Admin-Console aufrufen
4. Login mit Bootstrap-Admin
5. Realm "eneg" erstellen

---

## Geplante Keycloak Resources (DEV)

| Parameter | Request | Limit |
|---|---|---|
| CPU | 500m | 2 |
| Memory | 512Mi | 1Gi |

### Health Probes

| Probe | Endpoint | Bemerkung |
|---|---|---|
| Startup | /health/started | Keycloak braucht laenger beim ersten Start (DB-Migration) |
| Liveness | /health/live | Standard Quarkus Health |
| Readiness | /health/ready | Erst ready wenn DB-Verbindung steht |

---

## Secrets (SOPS-verschluesselt)

### keycloak-db-credentials (databases Namespace)

| Key | Beschreibung | Generierung |
|---|---|---|
| username | PostgreSQL Username | "keycloak" |
| password | PostgreSQL Passwort | `openssl rand -hex 24` |

### keycloak-secrets (keycloak Namespace)

| Key | Beschreibung | Generierung |
|---|---|---|
| db-password | PostgreSQL Passwort (Kopie) | identisch mit keycloak-db-credentials |
| admin-password | Bootstrap Admin-Passwort | `openssl rand -hex 24` |

---

## Geplante Dateistruktur

```
kubernetes/base/apps/keycloak/
  ├── namespace.yaml
  ├── deployment.yaml          # Production-Mode, ENV-Konfiguration
  ├── service.yaml             # Port 8080
  ├── ingress.yaml             # Certificate + IngressRoute (traefik NS)
  └── secrets/
      ├── kustomization.yaml
      ├── secret-generator.yaml
      ├── keycloak-secrets.enc.yaml
      └── keycloak-secrets.yaml.template
```

---

## AD-Anbindung (nach Deployment)

Nach dem initialen Deployment wird Keycloak fuer AD-Anbindung konfiguriert:

1. **Realm "eneg" erstellen** (nicht den Default "master" Realm verwenden)
2. **User Federation** → LDAP Provider hinzufuegen:
   - Vendor: Active Directory
   - Connection URL: ldaps://ad-server.eneg.de:636 (oder ldap://:389)
   - Bind DN: Technischer AD-User (z.B. cn=svc-keycloak,ou=service,dc=eneg,dc=de)
   - Bind Credential: AD-Service-Passwort
   - User DN: OU=Users,DC=eneg,DC=de
   - Group DN: OU=Groups,DC=eneg,DC=de
3. **SSO-Clients einrichten** fuer jede App:
   - OpenProject (OIDC)
   - Odoo (OIDC ueber Community-Modul oder SAML)
   - n8n (OIDC)
   - i-doit (SAML/OIDC)

Die AD-Konfiguration erfolgt ueber die Keycloak Admin-Console (UI), nicht
ueber Kubernetes-Manifeste. Optional kann spaeter ein Realm-Export als
JSON im Git versioniert werden.

---

## Etablierte Patterns (Referenz)

**Zwei-Secret-Pattern:**
1. DB-Credentials in databases Namespace (fuer CNPG managed.roles)
2. App-Secrets in keycloak Namespace (DB-Passwort Kopie + Admin-Passwort)

**SOPS Verschluesselung:**
- Age Key: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
- Verschluesselung immer auf k8s-mgmt-10

**Git Workflow:**
1. Windows/Mac: Dateien erstellen/aendern
2. git add, commit, push
3. k8s-mgmt-10: git pull, SOPS encrypt, commit, push (nur fuer Secrets)
4. ArgoCD: auto-sync

---

## Key Learnings aus vorherigen Deployments (relevant fuer Keycloak)

1. **DB-Passwoerter nur alphanumerisch:** `openssl rand -hex 24`
2. **CNPG Managed Roles Defaults explizit:** connectionLimit, ensure, inherit
3. **ODOO_RC / Entrypoint Learnings:** Keycloak nutzt ENV-Variablen nativ,
   kein Init-Container oder spezielles Config-Mounting noetig
4. **Startup-Probes grosszuegig:** Keycloak braucht beim ersten Start laenger
   (DB-Schema-Migration). failureThreshold auf 30+ setzen.
5. **Production-Mode Command:** `start` (nicht `start-dev`), uebergeben als
   `args` im Container-Spec damit der Entrypoint erhalten bleibt

---

*Dieses Dokument dient als Handoff-Anleitung fuer den naechsten Chat.*
