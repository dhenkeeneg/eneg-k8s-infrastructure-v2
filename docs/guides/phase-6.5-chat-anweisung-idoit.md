# Handoff: Phase 6.5 — i-doit Open Deployment

**Erstellt:** 04.03.2026
**Naechster Schritt:** i-doit Open deployen (MariaDB Galera als Datenbank)
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
DevOps ueber GitHub und das lokale Repository auf dem Windows-Laptop oder
den MacBook und MacMini.
Du fuehrst keine Commit und Push Befehle selbst aus. Du gibst mir die
entsprechenden Anweisungen und ich fuehre diese in einem gesonderten
Terminal dann selbst aus.

Du fuehrst keine Befehle auf dem Management-Server (k8s-mgmt-10 - 192.168.180.10)
selbst aus. Wenn noetig, gibst du mir die entsprechenden Anweisungen und ich
fuehre diese in einem gesonderten Terminal dann selbst aus.
Der Pfad zum Repository auf dem Managementserver (k8s-mgmt-10) ist:
"~/git/eneg-k8s-infrastructure-v2"

Wir setzen Phase 6 fort mit Schritt 6.5: i-doit Open Deployment.
Bitte lies zuerst folgende Dokumente:
1. docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.3.md
2. docs/phases/phase-06-pilot-apps.md
3. docs/guides/phase-6.5-chat-anweisung-idoit.md

Dann deploye i-doit gemaess der unten beschriebenen Architektur.
```

---

## WICHTIG: Neue Deployment-Reihenfolge (Secrets First!)

Ab sofort gilt eine neue Reihenfolge fuer alle Deployments, um
`CreateContainerConfigError` zu vermeiden:

### Phase A: Secrets zuerst (BEVOR die App erstellt wird)

1. **Windows-Laptop:** Secret-Templates (.yaml.template) erstellen
2. **Windows-Laptop:** KSOPS secret-generator.yaml und kustomization.yaml erstellen
3. **Windows-Laptop:** ArgoCD Application fuer Secrets (Wave 7) erstellen
4. **Windows-Laptop:** git add, commit, push
5. **k8s-mgmt-10:** git pull
6. **k8s-mgmt-10:** Kennwoerter generieren und in .yaml eintragen
7. **k8s-mgmt-10:** SOPS verschluesseln -> .enc.yaml
8. **k8s-mgmt-10:** git add, commit, push
9. **ArgoCD:** Warten bis Secret-App synced + healthy

### Phase B: App deployen (Secrets sind bereits vorhanden)

10. **Windows-Laptop:** App-Manifeste erstellen (namespace, deployment, service, ingress)
11. **Windows-Laptop:** ArgoCD Application fuer App (Wave 8) erstellen
12. **Windows-Laptop:** git add, commit, push
13. **ArgoCD:** Auto-Sync, Pod startet und findet Secrets vor

---

## Aktueller Infrastruktur-Stand

### Laufende Komponenten

| Komponente | Version | Namespace | Status |
|---|---|---|---|
| K3s | v1.35.1+k3s1 | - | 3 Nodes Running |
| ArgoCD | v3.3.0 | argocd | Synced + Healthy |
| Traefik | v3.6.7 | traefik | Active (192.168.180.100) |
| Cert-Manager | v1.17.2 | cert-manager | Ready |
| Longhorn | v1.9.2 | longhorn-system | 3x ~380GB |
| CNPG Operator | 1.28.1 | databases | Running |
| PostgreSQL (cnpg-shared) | 17 | databases | 3 Instanzen |
| PostgreSQL (cnpg-erp) | 17 | databases | 3 Instanzen |
| MariaDB Galera | 11.8.6 | databases | 3 Nodes |
| Garage S3 | v2.2.0 | garage | 3 Nodes |
| n8n | 2.8.4 | n8n | Running |
| OpenProject | 17.1.2-slim | openproject | Running |
| Odoo 18 CE | 18.0-20260217 | odoo | Running |
| Keycloak | 26.5.4 | keycloak | Running |

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
| 7 | n8n-secrets, openproject-secrets, odoo-secrets, odoo-backup-secrets, keycloak-secrets | diverse |
| 8 | n8n, openproject, odoo, keycloak | diverse |
| 9 | odoo-backup | odoo |

---

## i-doit Open — Geplante Architektur

### Eckdaten

| Parameter | Wert |
|---|---|
| Version | i-doit Open 35 |
| Docker Image | migoller/idoit (zu recherchieren: aktuelle Tags) |
| Datenbank | MariaDB Galera Cluster (11.8.6, bereits laufend) |
| DB-User | idoit (neue MariaDB-Datenbank + User) |
| DB-Name | idoit_system + idoit_data (i-doit Standard) |
| Webserver | Apache 2.4 (im Container) |
| PHP | 8.3 (im Container) |
| Replicas | 1 |
| DNS | idoit-dev-v2.eneg.de (CNAME auf traefik-dev.eneg.de) |
| Admin-User | admin (Default, PW in Secret) |
| ArgoCD Waves | 7 (Secrets), 8 (App) |

### Systemanforderungen (i-doit Open 35)

- PHP 8.3 empfohlen
- MariaDB 10.6 empfohlen (unsere 11.8.6 Galera ist kompatibel)
- Apache 2.4
- PHP-Erweiterungen: bcmath, curl, gd, json, ldap, mbstring, mysqli,
  mysqlnd, pdo, pdo_mysql, session, xml, xmlwriter, zip

### Besonderheiten MariaDB Galera

i-doit wird als **erste App auf der MariaDB Galera** Datenbank laufen.
Dies erfordert ein anderes Pattern als CNPG:
- Kein managed.roles (das ist CNPG-spezifisch)
- Stattdessen: MariaDB User + Database ueber MariaDB Operator CRDs
  ODER manuelles Setup via SQL
- Verbindungs-String: mariadb-galera-primary.databases.svc.cluster.local:3306
- Der MariaDB Operator kann Database/User/Grant CRDs verarbeiten

Bitte vorher pruefen:
- Welche CRDs hat der MariaDB Operator fuer User/Database Management?
- Gibt es ein aehnliches Pattern wie CNPG managed.roles?
- Falls nicht: Einmalige manuelle DB/User-Erstellung via kubectl exec

### Architektur-Diagramm

```
Browser (https://idoit-dev-v2.eneg.de)
    |
Traefik (TLS-Terminierung)
    |
    └── /* → idoit:80 (HTTP/Apache)
                  |
                  ├── MariaDB Galera (mariadb-galera-primary:3306)
                  └── Filesystem (PVC fuer Uploads/Cache)
```

---

## Docker Image Recherche (im neuen Chat durchfuehren)

Das Docker Image `migoller/idoit` war bei der Recherche das am besten
gepflegte Community-Image. Es basiert auf phusion/baseimage mit Apache
und PHP. Moegliche Alternativen:

- `migoller/idoit` (Docker Hub, Community-gepflegt)
- Eigenes Image bauen (Dockerfile, SourceForge ZIP)

**Im neuen Chat bitte recherchieren:**
1. Aktuelle Tags des migoller/idoit Image (unterstuetzen sie v35?)
2. Falls nicht: Alternative Images oder eigenen Dockerfile-Ansatz
3. Welche ENV-Variablen das Image unterstuetzt
4. Ob ein Init-Script fuer die DB-Initialisierung noetig ist

---

## Geplante Secrets

### idoit-secrets (idoit Namespace) — Wave 7

| Key | Beschreibung | Generierung |
|---|---|---|
| db-host | MariaDB Host | mariadb-galera-primary.databases.svc.cluster.local |
| db-port | MariaDB Port | 3306 |
| db-name | System-Datenbank | idoit_system |
| db-user | MariaDB Username | idoit |
| db-password | MariaDB Passwort | `openssl rand -hex 24` |
| admin-password | i-doit Admin-Passwort | `openssl rand -hex 16` |

### MariaDB Credentials (databases Namespace) — Wave 4 oder 7

Abhaengig davon ob der MariaDB Operator User/DB CRDs hat, oder ob
das Secret direkt fuer ein manuelles SQL-Setup verwendet wird.

---

## Geplante Dateistruktur

```
kubernetes/base/apps/idoit/
  ├── namespace.yaml
  ├── deployment.yaml          # Apache+PHP Container, ENV-Konfiguration
  ├── service.yaml             # Port 80
  ├── ingress.yaml             # Certificate + IngressRoute (traefik NS)
  ├── pvc.yaml                 # Longhorn PVC fuer Uploads/Logs
  └── secrets/
      ├── kustomization.yaml
      ├── secret-generator.yaml
      ├── idoit-secrets.enc.yaml
      └── idoit-secrets.yaml.template

kubernetes/environments/dev/infrastructure/
  ├── idoit-secrets-app.yaml   # ArgoCD App (Wave 7)
  └── idoit-app.yaml           # ArgoCD App (Wave 8)
```

---

## Deployment-Schritte (Detail)

### Phase A: Secrets First

1. Auf Windows-Laptop: Secret-Template + KSOPS-Generatoren erstellen
2. ArgoCD Application `idoit-secrets` (Wave 7) erstellen
3. git add, commit, push
4. Auf k8s-mgmt-10: git pull, Kennwoerter eintragen, SOPS encrypt
5. git add, commit, push
6. Pruefen: ArgoCD zeigt idoit-secrets als Synced + Healthy

### Phase B: MariaDB Datenbank vorbereiten

7. Pruefen ob MariaDB Operator Database/User CRDs unterstuetzt
8. Falls ja: CRD-Manifeste erstellen (Database + User + Grant)
9. Falls nein: SQL-Befehle fuer manuelle Erstellung vorbereiten:
   ```sql
   CREATE DATABASE idoit_system CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE DATABASE idoit_data CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE USER 'idoit'@'%' IDENTIFIED BY '<PASSWORD>';
   GRANT ALL PRIVILEGES ON idoit_system.* TO 'idoit'@'%';
   GRANT ALL PRIVILEGES ON idoit_data.* TO 'idoit'@'%';
   FLUSH PRIVILEGES;
   ```

### Phase C: App deployen

10. App-Manifeste erstellen (Deployment, Service, PVC, Ingress)
11. ArgoCD Application `idoit` (Wave 8) erstellen
12. git add, commit, push
13. ArgoCD synct, Pod startet

### Phase D: i-doit Setup

14. Browser: https://idoit-dev-v2.eneg.de aufrufen
15. i-doit Setup-Wizard durchlaufen (DB-Verbindung, Admin-PW)
16. Optional: Keycloak SSO-Client fuer i-doit konfigurieren

---

## SOPS Verschluesselung (Referenz)

Alle Verschluesselungen auf k8s-mgmt-10:

```bash
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/base/apps/idoit/secrets

sops --encrypt \
  --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
  --encrypted-regex '^(data|stringData)$' \
  idoit-secrets.yaml > idoit-secrets.enc.yaml
rm idoit-secrets.yaml
```

---

## Key Learnings aus vorherigen Deployments (BEACHTEN!)

### Allgemein

1. **Secrets ZUERST deployen:** CreateContainerConfigError tritt auf wenn
   ein Secret referenziert wird, das noch nicht existiert. Immer Phase A
   (Secrets) VOR Phase B/C (App) abschliessen.

2. **ArgoCD Polling:** Default 3 Minuten. Falls noetig, manuell Refresh
   in ArgoCD-UI klicken. Polling wurde auf 60s reduziert via
   argocd-cmd-params-cm ConfigMap.

3. **CNPG managed.roles Duplikate:** Beim Bearbeiten von Cluster-YAML
   sorgfaeltig pruefen, dass keine doppelten Eintraege entstehen.

### Keycloak-spezifisch (relevant fuer Probes-Pattern)

4. **Health-Probes Port:** Keycloak 26+ verschob Health auf Port 9000.
   Fuer i-doit: Standard-Port 80 fuer Health-Probes verwenden.

5. **Startup-Probe grosszuegig:** Beim ersten Start braucht i-doit
   evtl. laenger (PHP-Setup, Cache-Aufbau). failureThreshold hoch setzen.

### OpenProject / Odoo (relevant fuer Web-App-Pattern)

6. **Entrypoint vs. CMD/Args:** Docker Images mit Entrypoint-Scripts
   benoetigen `args` statt `command` im Container-Spec.

7. **PVC fuer Uploads:** Web-Apps brauchen persistent storage fuer
   hochgeladene Dateien. ReadWriteOnce reicht bei 1 Replica.

8. **Ingress-Pattern:** Certificate + IngressRoute in traefik Namespace,
   Service-Referenz cross-namespace.

### Authentifizierung (Key Learnings!)

9. **OpenProject OIDC ist Enterprise-only:** Der Seeder erstellt den
   Provider in der DB, aber die OmniAuth-Middleware registriert die Route
   nicht. Log: "OmniAuth SSO strategy ... only available for Enterprise"

10. **n8n SSO ist Enterprise-only:** Community Edition hat kein OIDC/SAML.

11. **OpenProject LDAP funktioniert in CE:** Login-Attribut auf `mail`
    setzen fuer E-Mail-basierte Anmeldung. Base DN ist Pflichtfeld!

12. **Keycloak AD-Gruppen:** Flat-Import (Preserve Group Inheritance: Off)
    wegen GroupsMultipleParents-Fehler bei verschachtelten AD-Gruppen.

### MariaDB-spezifisch (NEUE Learnings fuer i-doit)

13. **MariaDB Galera vs. CNPG:** MariaDB hat KEINE managed.roles.
    User/Database-Erstellung laeuft ueber MariaDB Operator CRDs oder
    manuelles SQL. VOR dem Deployment recherchieren!

14. **MariaDB Service-Endpunkt:** `mariadb-galera-primary.databases.svc.cluster.local:3306`
    fuer Write-Zugriff (Primary Node).

---

## Etablierte Patterns (Referenz)

**Secret-Pattern:**
- .yaml.template (Klartext-Vorlage, gitignored)
- .enc.yaml (SOPS-verschluesselt, committed)
- kustomization.yaml + secret-generator.yaml (KSOPS)

**Ingress-Pattern:**
- Certificate + IngressRoute in traefik Namespace
- Service-Referenz cross-namespace zu App-Namespace

**SOPS Age Key:**
age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm

**Git Workflow (NEU — Secrets First!):**
1. Windows/Mac: Secret-Templates + KSOPS-Generatoren erstellen
2. Windows/Mac: ArgoCD Secret-App erstellen (Wave 7)
3. git add, commit, push
4. k8s-mgmt-10: git pull, Kennwoerter eintragen, SOPS encrypt
5. k8s-mgmt-10: git add, commit, push
6. ArgoCD: Secret-App synced + healthy
7. Windows/Mac: App-Manifeste erstellen
8. Windows/Mac: ArgoCD App-App erstellen (Wave 8)
9. git add, commit, push
10. ArgoCD: App synced + healthy

---

## DNS Vorbereitung

CNAME-Eintrag in IONOS (wahrscheinlich bereits vorbereitet):
- `idoit-dev-v2.eneg.de` → `traefik-dev.eneg.de`

---

## Keycloak SSO-Client (bereits erstellt, aber nicht konfiguriert)

In Keycloak Realm "eneg" gibt es noch keinen i-doit Client.
Falls gewuenscht, nach erfolgreichem Deployment einen OIDC-Client
"idoit" in Keycloak erstellen:

| Feld | Wert |
|---|---|
| Client ID | idoit |
| Client Type | OpenID Connect |
| Root URL | https://idoit-dev-v2.eneg.de |
| Valid Redirect URIs | https://idoit-dev-v2.eneg.de/* |

i-doit Pro unterstuetzt SSO/SAML nativ. Fuer i-doit Open muss geprueft
werden, ob ein OIDC/SAML-Plugin verfuegbar ist.

---

*Dieses Dokument dient als Handoff-Anleitung fuer den naechsten Chat.*
