# Handoff: Phase 6.5 — i-doit Open 37 Deployment (Abgeschlossen)

**Erstellt:** 10.03.2026
**Status:** ✅ Abgeschlossen
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Ergebnis

i-doit Open 37 laeuft erfolgreich als CMDB/IT-Dokumentation im DEV-Cluster.
Es ist die erste Anwendung auf der MariaDB Galera Datenbank und die erste
Anwendung mit einem selbstgebauten Docker Image auf ghcr.io.

| Parameter | Wert |
|---|---|
| URL | https://idoit-dev-v2.eneg.de |
| Version | i-doit Open 37 |
| Docker Image | ghcr.io/dhenkeeneg/idoit-open:37 |
| Basis-Image | php:8.3-apache (Debian Bookworm) |
| Datenbank | MariaDB Galera 11.8.6 (mariadb-galera-primary:3306) |
| DB-Namen | idoit_system, idoit_data |
| DB-User | idoit (via MariaDB Operator User/Grant CRDs) |
| Login | admin / admin (Passwortaenderung empfohlen) |
| Namespace | idoit |
| PVC | 10Gi Longhorn (upload, temp, log, src) |

---

## ArgoCD Applications

| Application | Sync | Health | Wave | Beschreibung |
|---|---|---|---|---|
| mariadb-idoit-databases | Synced | Healthy | 6 | User + Grant CRDs |
| idoit-secrets | Synced | Healthy | 7 | DB-PW, Admin-PW, ghcr Pull Secret |
| idoit | Synced | Healthy | 8 | Namespace, Deployment, Service, PVC, Ingress |

---

## Dateistruktur

```
docker/idoit/
  └── Dockerfile                   # php:8.3-apache + i-doit Open 37 (SourceForge)

kubernetes/base/apps/idoit/
  ├── namespace.yaml
  ├── deployment.yaml              # Init-Container (src-Persistenz) + Apache/PHP
  ├── service.yaml                 # ClusterIP:80
  ├── pvc.yaml                     # 10Gi Longhorn
  ├── ingress.yaml                 # Certificate + IngressRoute (traefik NS)
  └── secrets/
      ├── kustomization.yaml
      ├── secret-generator.yaml    # KSOPS: idoit-secrets + ghcr-pull-secret
      ├── idoit-secrets.enc.yaml
      ├── ghcr-pull-secret.enc.yaml
      ├── idoit-secrets.yaml.template
      └── ghcr-pull-secret.yaml.template

kubernetes/base/mariadb-galera/
  ├── databases/
  │   ├── idoit-user.yaml          # MariaDB Operator User CRD
  │   └── idoit-grant.yaml         # 2x Grant CRD (idoit_system + idoit_data)
  └── secrets/
      ├── secret-generator.yaml    # KSOPS (erweitert um idoit-db-credentials)
      ├── idoit-db-credentials.enc.yaml
      └── idoit-db-credentials.yaml.template

kubernetes/environments/dev/infrastructure/
  ├── mariadb-idoit-databases-app.yaml  # ArgoCD App (Wave 6)
  ├── idoit-secrets-app.yaml            # ArgoCD App (Wave 7)
  └── idoit-app.yaml                    # ArgoCD App (Wave 8)
```

---

## Infrastruktur-Besonderheiten

### Eigenes Docker Image (ghcr.io)

Es gibt kein offizielles oder gepflegtes Community-Docker-Image fuer i-doit
Open 35+. Das Image wird selbst gebaut auf k8s-mgmt-10 (Docker Engine 29.3.0):

```bash
cd ~/git/eneg-k8s-infrastructure-v2/docker/idoit
docker build -t ghcr.io/dhenkeeneg/idoit-open:37 .
echo $GHCR_TOKEN | docker login ghcr.io -u dhenkeeneg --password-stdin
docker push ghcr.io/dhenkeeneg/idoit-open:37
```

Das Image benoetigt ein imagePullSecret (`ghcr-pull-secret`) mit GitHub PAT
(read:packages). imagePullPolicy ist auf `Always` gesetzt, damit Image-Updates
nach einem Rebuild gezogen werden.

### MariaDB Operator CRDs (erste App auf Galera)

i-doit ist die erste Anwendung auf MariaDB Galera. Im Gegensatz zu CNPG
(managed.roles) werden hier MariaDB Operator CRDs verwendet:
- **User CRD:** Erstellt den DB-User `idoit` mit Passwort aus Secret
- **Grant CRDs:** ALL PRIVILEGES auf `idoit_system` und `idoit_data`
- **KEINE Database CRDs:** i-doit verwaltet seine Datenbanken selbst
  (der Setup-Wizard erstellt das Schema)

### config.inc.php Persistenz

i-doit speichert die Runtime-Konfiguration in `/var/www/html/i-doit/src/config.inc.php`.
Ohne Persistenz geht diese bei Pod-Restarts verloren. Loesung:
- Init-Container (`init-src`) kopiert den src-Ordner beim ersten Start
  aus dem Image in den PVC (`subPath: src`)
- Bei weiteren Restarts erkennt der Init-Container vorhandene Dateien
  und ueberspringt den Kopiervorgang

### MariaDB Galera Konfiguration (optimiert)

Die Galera-Konfiguration wurde fuer i-doit angepasst:
- `innodb_buffer_pool_size=1024M` (i-doit empfiehlt >= 1024M)
- `max_allowed_packet=64M` (i-doit empfiehlt >= 64M)
- `sql_mode=` (leer, i-doit benoetigt dies)
- Memory-Limit auf 2Gi erhoeht (fuer 1024M Buffer Pool)

---

## Key Learnings (fuer zukuenftige Deployments)

1. **Kein offizielles Docker Image:** Community-Images veraltet. Eigenes
   Dockerfile mit php:8.3-apache + SourceForge-ZIP ist die beste Loesung.

2. **i-doit Setup-Wizard braucht leere Datenbanken:** Vorab erstellte DBs
   (via MariaDB Operator Database CRDs) fuehren zu "EXISTS. PLEASE DROP IT".
   Loesung: Keine Database CRDs, nur User + Grant CRDs.

3. **metadata.name vs. DB-Name:** Kubernetes erlaubt keine Unterstriche in
   metadata.name. Fuer DB-Namen mit Unterstrichen `spec.name` setzen.

4. **MariaDB Operator User CRD:** `maxConnections` existiert nicht in der
   CRD-Version (Operator 25.10.4). Fuehrt zu "field not declared in schema".

5. **PHP sockets Extension:** i-doit 37 benoetigt `sockets`, nicht im
   Standard-php:8.3-apache Image. Explizit via docker-php-ext-install bauen.

6. **imagePullPolicy: Always:** Bei eigenem ghcr.io Image mit festem Tag
   noetig, damit Updates nach Rebuild gezogen werden.

7. **MariaDB 11.8.6 funktioniert:** Offiziell nur bis 11.4 gelistet,
   aber 11.8.6 Galera laeuft problemlos. Nur eine Warnung im Setup.

8. **ghcr.io Pull Secret:** Privates Image braucht imagePullSecret mit
   GitHub PAT (read:packages). Als SOPS-Secret via KSOPS deployed.

9. **config.inc.php Persistenz:** Ohne PVC-Mount fuer /src geht die
   Konfiguration bei Pod-Restart verloren. Init-Container-Pattern loest das.

---

## Secrets-Referenz

Alle Verschluesselungen auf k8s-mgmt-10:

```bash
# i-doit App-Secrets (idoit Namespace)
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/base/apps/idoit/secrets
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     idoit-secrets.yaml > idoit-secrets.enc.yaml

# ghcr.io Pull Secret (idoit Namespace)
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     ghcr-pull-secret.yaml > ghcr-pull-secret.enc.yaml

# DB-Credentials (databases Namespace)
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/base/mariadb-galera/secrets
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
     --encrypted-regex '^(data|stringData)$' \
     idoit-db-credentials.yaml > idoit-db-credentials.enc.yaml
```

Passwoerter auslesen:
```bash
sops --decrypt ~/git/eneg-k8s-infrastructure-v2/kubernetes/base/apps/idoit/secrets/idoit-secrets.enc.yaml | grep -E "db-password|admin-password"
sops --decrypt ~/git/eneg-k8s-infrastructure-v2/kubernetes/base/mariadb-galera/secrets/mariadb-credentials.enc.yaml | grep ROOT_PASSWORD
```

---

## Aktueller Infrastruktur-Stand (nach Phase 6.5)

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
| **i-doit Open** | **37** | **idoit** | **Running** |

---

## Naechste Schritte

- **i-doit Einrichtung:** Objekte, Kategorien, Benutzer konfigurieren
- **LDAP-Anbindung:** i-doit Open unterstuetzt LDAP nativ (Admin > LDAP)
- **Odoo SSO/OIDC:** Community-Modul auth_oauth (noch ausstehend)
- **Weitere Apps:** Nach Bedarf (Nextcloud, KixDesk, Papermerge)
- **Phase 7:** Monitoring-Stack (Prometheus, Grafana, Loki, AlertManager)

---

*Dieses Dokument dient als Handoff-Referenz fuer Phase 6.5.*
