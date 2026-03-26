# Phase 8b-continued: TEST-Umgebung Apps — Handoff-Dokument

**Erstellt:** 16.03.2026
**Aktualisiert:** 26.03.2026
**Status:** ✅ ABGESCHLOSSEN (inkl. Post-Deployment Konfiguration)

---

## Ergebnis

Alle 6 Pilot-Apps sind erfolgreich auf Environment-Overlays umgestellt und auf dem
TEST-Cluster deployed. ArgoCD TEST zeigt alle Apps Synced + Healthy.
Post-Deployment Konfiguration (Garage S3, Keycloak AD/OIDC, SMTP, LDAP) abgeschlossen.

## Abgeschlossene Arbeiten

### Schritt 1-6 (vorherige Sessions)
- CNPG Operator, MariaDB Operator + CRDs: TEST ArgoCD App-Definitionen
- CNPG/MariaDB Secrets: SOPS-verschluesselt fuer TEST
- CNPG Cluster + Backups: Refactoring auf Environment-Overlays (DEV + TEST)
- MariaDB Galera Cluster + Backup: Refactoring auf Environment-Overlays
- Garage S3: Refactoring (Node-IDs, Ingress, Backup-Buckets)

### Schritt 7 (26.03.2026, fruehe Session)
- i-doit TEST deployment.yaml fertiggestellt (Probes + Volumes)
- i-doit TEST Secrets erstellt (idoit-secrets + ghcr-pull-secret)
- it-info-versand DEV + TEST komplett (Manifeste + Secrets inkl. ghcr-pull-secret)
- OpenProject DEV + TEST komplett (Web, Worker, Seeder, Memcached, Hocuspocus + Secrets)
- Odoo DEV + TEST komplett (Manifeste + ConfigMap + Backup CronJob + Secrets)
- n8n + Keycloak: DEV Secrets bleiben in base/ (Option A, keine Re-Encryption)
- .sops.yaml: Regel 1c fuer environments/*/apps/*/secrets/
- 7 DEV ArgoCD App-Pfade aktualisiert: base/apps/* -> environments/dev/apps/*
- 14 TEST ArgoCD App-Definitionen neu erstellt

### Schritt 8: Post-Deployment Konfiguration (26.03.2026, spaete Session)

**Garage TEST:**
- Node-IDs waren bereits korrekt (kein Fix noetig)
- WebUI-Passwort neu gesetzt (altes funktionierte nicht)
- Garage API Key `openproject-app` erstellt, Bucket `openproject-assets` angelegt

**Keycloak TEST:**
- Realm `eNeG` erstellt (Achtung: case-sensitive, nicht `eneg`!)
- AD/LDAP User Federation konfiguriert (dc01/dc02/dc03, READ_ONLY)
- Group Mapper: `ad-groups` (Preserve Group Inheritance: Off)
- OIDC-Client `openproject` erstellt (wird in CE nicht genutzt, LDAP stattdessen)
- OIDC-Client `it-info-versand` erstellt
- **Wichtig:** Group Membership Protocol Mapper im Client-Scope hinzugefuegt
  (Token Claim Name: `groups`, Full group path: Off, Add to ID/access/userinfo token)

**OpenProject TEST:**
- S3-Credentials (Garage Key) im Secret eingetragen
- SMTP konfiguriert (ENV-Variablen: OPENPROJECT_EMAIL__DELIVERY__METHOD, SMTP__ADDRESS, etc.)
- SMTP-Server: smtpout1.eneg.customers.hosting.zone:587 (STARTTLS, login auth)
- Absender: openproject-test@eneg.de
- SMTP-Credentials (Username/Password) im SOPS-Secret
- LDAP-Authentifizierung gegen AD direkt in OpenProject konfiguriert (CE kann kein OIDC)
- E-Mail-Versand getestet und funktioniert

**it-info-versand TEST:**
- OIDC-Client-Secret eingetragen
- Keycloak-Login funktioniert nach Hinzufuegen des Group Membership Mappers
- DNS-Eintrag: it-info-versand-test.eneg.de (CNAME auf traefik-test.eneg.de)

**Bugfix: Keycloak Realm-Name:**
- Alle OpenProject-Deployments (base, DEV, TEST) korrigiert: `realms/eneg` -> `realms/eNeG`
- Keycloak Realm-Name ist case-sensitive in URLs

### Fixes waehrend Deployment (Schritt 7)
- ghcr-pull-secret auth-Feld: Darf nur reinen Base64-String enthalten, kein Prefix
- OpenProject DB-Passwort: Sonderzeichen (/, %) in DATABASE_URL vermeiden -> Hex-only
- OpenProject: DB-Migrationen beim ersten Start manuell anstossen
- Odoo: DB-Initialisierung mit -i base manuell starten

## TEST-Cluster Gesamtstatus

Alle Apps Synced + Healthy auf ArgoCD TEST (https://argocd-test.eneg.de)

| App | URL | Status | Auth |
|-----|-----|--------|------|
| OpenProject | https://openproject-test.eneg.de | ✅ Erreichbar | LDAP (AD direkt) |
| Odoo | https://odoo-test.eneg.de | ✅ Erreichbar | Lokal |
| i-doit | https://idoit-test.eneg.de | ✅ Erreichbar | Lokal |
| IT-Info-Versand | https://it-info-versand-test.eneg.de | ✅ Erreichbar | Keycloak OIDC |
| n8n | https://n8n-test.eneg.de | ✅ Erreichbar | Lokal (CE) |
| Keycloak | https://keycloak-test.eneg.de | ✅ Erreichbar | Admin lokal |
| Garage WebUI | https://s3-gui-test.eneg.de | ✅ Erreichbar | HTTP Basic Auth |

## Naechste Schritte

### Phase 8c: PROD Rollout
- PROD-Cluster aufbauen (analog zu TEST)
- Voraussetzungen: VLAN 178, DNS, vSphere Folder

### Phase 7: Monitoring und Alerting (ausstehend)
- CNPG WAL Volume Thresholds (Warning 70%, Critical 85%)
- CronJob Backup Failure Alerts
- S3 Endpoint Availability (Blackbox Exporter)

## Learnings fuer PROD

1. **DB-Passwoerter:** Nur Hex-Zeichen verwenden (openssl rand -hex 24), keine
   base64 oder zufaellige Zeichensaetze — Sonderzeichen brechen DATABASE_URL
2. **ghcr-pull-secret:** auth-Feld ist reiner Base64-String von "username:token",
   kein Prefix, kein Label
3. **OpenProject erster Start:** DB-Migrationen manuell starten bevor Web-Pod laeuft
4. **Odoo erster Start:** DB-Initialisierung mit -i base manuell starten
5. **CNPG Managed Roles:** Nach Passwortaenderung pruefen ob PostgreSQL das neue
   Passwort tatsaechlich uebernommen hat (ALTER ROLE direkt auf Primary)
6. **Keycloak Realm-Name:** `eNeG` ist case-sensitive — in allen OIDC-URLs
   `realms/eNeG` verwenden, nicht `realms/eneg`
7. **Keycloak OIDC Group Mapper:** Clients die gruppenbasierte Autorisierung brauchen,
   benoetigen einen Group Membership Protocol Mapper im dedicated Client Scope
   (Token Claim Name: `groups`, Full group path: Off)
8. **OpenProject CE:** OIDC ist Enterprise-only — LDAP direkt gegen AD verwenden
9. **OpenProject SMTP:** Muss ueber ENV-Variablen konfiguriert werden
   (OPENPROJECT_EMAIL__DELIVERY__METHOD, OPENPROJECT_SMTP__ADDRESS, etc.),
   nicht ueber die Web-UI
10. **Garage WebUI Passwort:** bcrypt-Hash im Secret, Klartext nicht rekonstruierbar —
    Passwort sicher dokumentieren
