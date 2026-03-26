# Phase 8b-continued: TEST-Umgebung Apps — Handoff-Dokument

**Erstellt:** 16.03.2026
**Aktualisiert:** 26.03.2026
**Status:** ✅ ABGESCHLOSSEN

---

## Ergebnis

Alle 6 Pilot-Apps sind erfolgreich auf Environment-Overlays umgestellt und auf dem
TEST-Cluster deployed. ArgoCD TEST zeigt alle Apps Synced + Healthy.

## Abgeschlossene Arbeiten

### Schritt 1-6 (vorherige Sessions)
- CNPG Operator, MariaDB Operator + CRDs: TEST ArgoCD App-Definitionen
- CNPG/MariaDB Secrets: SOPS-verschluesselt fuer TEST
- CNPG Cluster + Backups: Refactoring auf Environment-Overlays (DEV + TEST)
- MariaDB Galera Cluster + Backup: Refactoring auf Environment-Overlays
- Garage S3: Refactoring (Node-IDs, Ingress, Backup-Buckets)

### Schritt 7 (diese Session, 26.03.2026)
- i-doit TEST deployment.yaml fertiggestellt (Probes + Volumes)
- i-doit TEST Secrets erstellt (idoit-secrets + ghcr-pull-secret)
- it-info-versand DEV + TEST komplett (Manifeste + Secrets inkl. ghcr-pull-secret)
- OpenProject DEV + TEST komplett (Web, Worker, Seeder, Memcached, Hocuspocus + Secrets)
- Odoo DEV + TEST komplett (Manifeste + ConfigMap + Backup CronJob + Secrets)
- n8n + Keycloak: DEV Secrets bleiben in base/ (Option A, keine Re-Encryption)
- .sops.yaml: Regel 1c fuer environments/*/apps/*/secrets/
- 7 DEV ArgoCD App-Pfade aktualisiert: base/apps/* -> environments/dev/apps/*
- 14 TEST ArgoCD App-Definitionen neu erstellt

### Fixes waehrend Deployment
- ghcr-pull-secret auth-Feld: Darf nur reinen Base64-String enthalten, kein Prefix
  wie "Auth-Base64: ..." — korrigiert fuer i-doit und it-info-versand
- OpenProject DB-Passwort: Sonderzeichen (/, %) in DATABASE_URL vermeiden
  → Hex-only Passwoerter generieren mit: openssl rand -hex 24
- OpenProject: DB-Migrationen beim ersten Start manuell anstossen:
  kubectl run openproject-migrate --image=openproject/openproject:17.1.2-slim ...
  ... bash -c "cd /app && bundle exec rails db:migrate"
- Odoo: DB-Initialisierung beim ersten Start manuell anstossen:
  kubectl run odoo-init --image=odoo:18 ...
  ... odoo -i base -d odoo --stop-after-init --no-http

## TEST-Cluster Gesamtstatus

Alle Apps Synced + Healthy auf ArgoCD TEST (https://argocd-test.eneg.de)

| App | URL | Status |
|-----|-----|--------|
| OpenProject | https://openproject-test.eneg.de | Erreichbar (Admin: admin/admin) |
| Odoo | https://odoo-test.eneg.de | Erreichbar |
| i-doit | https://idoit-test.eneg.de | Erreichbar |
| IT-Info-Versand | https://it-info-versand-test.eneg.de | Erreichbar |
| n8n | https://n8n-test.eneg.de | Erreichbar |
| Keycloak | https://keycloak-test.eneg.de | Erreichbar |

## Naechste Schritte

### Kurzfristig (offene Punkte)
- Garage TEST: Platzhalter-Node-IDs durch echte ersetzen (nach erstem Start auslesen)
- OpenProject TEST: S3-Credentials (Garage) eintragen wenn Garage TEST laeuft
- Keycloak TEST: AD-Anbindung konfigurieren, OIDC-Clients erstellen
- OpenProject/it-info-versand: OIDC-Client-Secrets von Keycloak eintragen
- OpenProject Admin-Passwort aendern (default: admin/admin)

### Phase 8c: PROD Rollout
- PROD-Cluster aufbauen (analog zu TEST, siehe Ausfuehrungsplan im alten Handoff)
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
3. **OpenProject erster Start:** DB-Migrationen manuell starten bevor Web-Pod läuft
4. **Odoo erster Start:** DB-Initialisierung mit -i base manuell starten
5. **CNPG Managed Roles:** Nach Passwortaenderung pruefen ob PostgreSQL das neue
   Passwort tatsaechlich uebernommen hat (ALTER ROLE direkt auf Primary)
