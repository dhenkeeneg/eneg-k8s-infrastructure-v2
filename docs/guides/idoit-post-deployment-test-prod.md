# i-doit Open 37 — Post-Deployment TEST + PROD

**Erstellt:** 30.03.2026
**Abgeschlossen:** 30.03.2026
**Status:** ✅ Abgeschlossen (TEST + PROD)
**Referenz:** `docs/guides/phase-6.5-handoff-idoit.md` (DEV-Setup-Doku)

---

## Ausgangslage

i-doit Open 37 ist auf DEV seit 10.03.2026 produktiv eingerichtet:
- URL: https://idoit-dev-v2.eneg.de
- Custom Docker Image: `ghcr.io/dhenkeeneg/idoit-open:37`
- MariaDB Galera (idoit_system + idoit_data, User: idoit)
- Init-Container fuer config.inc.php Persistenz
- ghcr-pull-secret fuer privates Container Image

Die Kubernetes-Manifeste, SOPS-Secrets und ArgoCD App-Definitionen fuer
TEST und PROD wurden in Phase 8b-continued bzw. 8c bereits erstellt.
Die Pods laufen auf TEST und PROD. Es fehlt nur noch die manuelle
Erstkonfiguration ueber den i-doit Setup-Wizard.

---

## Infrastruktur-Status (bereits deployed)

### Dateien (alle vorhanden)

**TEST:**
- `kubernetes/environments/test/apps/idoit/` — deployment, service, ingress, pvc, namespace
- `kubernetes/environments/test/apps/idoit/secrets/` — idoit-secrets.enc.yaml, ghcr-pull-secret.enc.yaml
- `kubernetes/environments/test/infrastructure/idoit-app.yaml` + `idoit-secrets-app.yaml`

**PROD:**
- `kubernetes/environments/prod/apps/idoit/` — deployment, service, ingress, pvc, namespace
- `kubernetes/environments/prod/apps/idoit/secrets/` — idoit-secrets.enc.yaml, ghcr-pull-secret.enc.yaml
- `kubernetes/environments/prod/infrastructure/idoit-app.yaml` + `idoit-secrets-app.yaml`

### URLs

| Umgebung | URL | ArgoCD App |
|----------|-----|------------|
| DEV | https://idoit-dev-v2.eneg.de | ✅ Laeuft seit 10.03.2026 |
| TEST | https://idoit-test.eneg.de | ✅ Setup abgeschlossen 30.03.2026 |
| PROD | https://idoit.eneg.de | ✅ Setup abgeschlossen 30.03.2026 |

### Datenbank-Konfiguration

MariaDB Galera laeuft auf allen 3 Clustern. DB-User und Grants sind via
MariaDB Operator CRDs deployed (ArgoCD App: mariadb-idoit-databases).

| Umgebung | DB-Host | User | Datenbanken |
|----------|---------|------|-------------|
| DEV | mariadb-galera-primary.databases.svc.cluster.local:3306 | idoit | idoit_system, idoit_data |
| TEST | mariadb-galera-primary.databases.svc.cluster.local:3306 | idoit | idoit_system, idoit_data |
| PROD | mariadb-galera-primary.databases.svc.cluster.local:3306 | idoit | idoit_system, idoit_data |

DB-Passwoerter sind in den SOPS-Secrets pro Umgebung verschluesselt.

### Docker Image

Eigenes Image: `ghcr.io/dhenkeeneg/idoit-open:37`
- Basis: php:8.3-apache (Debian Bookworm)
- Gebaut auf k8s-mgmt-10
- Dockerfile: `docker/idoit/Dockerfile`
- Registry: ghcr.io (privat, ghcr-pull-secret noetig)

---

## Post-Deployment-Anleitung (pro Umgebung)

Reihenfolge: Erst TEST komplett, dann PROD.

### Schritt 1: Pruefen ob Pods laufen

```bash
# Auf k8s-mgmt-10:
kubectl config use-context k8s-test  # oder k8s-prod
kubectl get pods -n idoit
kubectl get pvc -n idoit
```

Erwartung: 1x idoit Pod Running, 1x idoit-data PVC Bound.

### Schritt 2: Vorbereitungen vor dem Setup-Wizard

**2a: Upload-Verzeichnisse anlegen (auf k8s-mgmt-10):**

```bash
kubectl exec -it $(kubectl get pod -n idoit -o jsonpath='{.items[0].metadata.name}') -n idoit -- bash -c \
  "mkdir -p /var/www/html/i-doit/upload/files /var/www/html/i-doit/upload/images && \
   chown -R www-data:www-data /var/www/html/i-doit/upload"
```

**2b: Globale DB-Rechte temporaer setzen (auf k8s-mgmt-10):**

```bash
kubectl exec -it mariadb-galera-0 -n databases -- mariadb -u root -p \
  -e "GRANT ALL PRIVILEGES ON *.* TO 'idoit'@'%'; FLUSH PRIVILEGES;"
```

Root-Passwort auslesen:
```bash
sops --decrypt kubernetes/environments/{env}/mariadb-secrets/mariadb-credentials.enc.yaml | grep ROOT_PASSWORD
```

### Schritt 3: i-doit Setup-Wizard ausfuehren

1. Browser oeffnen: https://idoit-test.eneg.de (bzw. https://idoit.eneg.de)
2. Der Setup-Wizard sollte automatisch starten (Erstinstallation)
3. Einstellungen:
   - **Sprache:** Deutsch
   - **Datenbank-Host:** `mariadb-galera-primary.databases.svc.cluster.local`
   - **Datenbank-Port:** `3306`
   - **Datenbank-Root-User:** `root` (Connection settings oben)
   - **Datenbank-Root-Passwort:** (aus mariadb-credentials Secret)
   - **MySQL-User:** `idoit` (MySQL user settings Mitte)
   - **MySQL-User-Passwort:** (aus idoit-secrets Secret, 2x eingeben)
   - **System-Datenbank:** `idoit_system`
   - **Mandant-Datenbank:** `idoit_data`
   - **Mandant-Title:** `eNeG` (PROD) bzw. `eNeG Test` (TEST)
   - **Admin-Center-Passwort:** Sicheres Passwort setzen (notieren!)
4. Setup abschliessen

**Schritt 3a: Passwoerter auslesen (auf k8s-mgmt-10):**

```bash
cd ~/git/eneg-k8s-infrastructure-v2

# Root-Passwort (fuer Connection settings):
sops --decrypt kubernetes/environments/test/mariadb-secrets/mariadb-credentials.enc.yaml | grep ROOT_PASSWORD
# bzw. fuer PROD:
sops --decrypt kubernetes/environments/prod/mariadb-secrets/mariadb-credentials.enc.yaml | grep ROOT_PASSWORD

# idoit DB-Passwort (fuer MySQL user settings):
sops --decrypt kubernetes/environments/test/apps/idoit/secrets/idoit-secrets.enc.yaml | grep db-password
# bzw. fuer PROD:
sops --decrypt kubernetes/environments/prod/apps/idoit/secrets/idoit-secrets.enc.yaml | grep db-password
```

**WICHTIG:** Der i-doit Setup-Wizard erstellt die Datenbanken (idoit_system,
idoit_data) selbst. Die MariaDB Operator Grant CRDs geben dem User `idoit`
die noetige Berechtigung dafuer. Es duerfen KEINE Database CRDs vorhanden
sein, sonst meldet i-doit "EXISTS. PLEASE DROP IT".

### Schritt 4: Globale DB-Rechte wieder entziehen

Nach erfolgreichem Setup-Wizard muessen die temporaeren globalen Rechte
wieder entfernt werden:

```bash
kubectl exec -it mariadb-galera-0 -n databases -- mariadb -u root -p \
  -e "REVOKE ALL PRIVILEGES ON *.* FROM 'idoit'@'%'; \
      GRANT ALL PRIVILEGES ON idoit_system.* TO 'idoit'@'%'; \
      GRANT ALL PRIVILEGES ON idoit_data.* TO 'idoit'@'%'; \
      FLUSH PRIVILEGES;"
```

Kontrolle:
```bash
kubectl exec -it mariadb-galera-0 -n databases -- mariadb -u root -p \
  -e "SHOW GRANTS FOR 'idoit'@'%';"
```

Erwartung: Nur USAGE auf *.* plus ALL PRIVILEGES auf idoit_system.* und
idoit_data.* — keine globalen Rechte mehr.

### Schritt 5: Admin-Passwort aendern

Nach dem Setup-Wizard: Admin-Passwort auf ein sicheres Passwort aendern
und dokumentieren. Standard-Login nach Setup ist admin/admin.

### Schritt 6: Funktionstest

- Login mit admin-Credentials
- Objekt erstellen (z.B. Test-Server)
- Pruefe ob Upload funktioniert (Datei an Objekt anhaengen)
- Pruefe ob Log-Verzeichnis beschreibbar ist

### Schritt 7: LDAP-Anbindung (optional)

i-doit Open unterstuetzt LDAP nativ:
- Administration > Schnittstellen > LDAP
- Konfiguration analog zu DEV-Umgebung
- AD-Server: dc01.eneg.de / dc02.eneg.de / dc03.eneg.de

---

## Bekannte Besonderheiten

1. **Setup-Wizard vs. DB:** i-doit erstellt Datenbanken selbst — keine
   MariaDB Database CRDs verwenden (nur User + Grant CRDs)

2. **config.inc.php Persistenz:** Init-Container kopiert /src beim ersten
   Start aus dem Image ins PVC. Bei spateren Pod-Restarts wird der
   bestehende Inhalt beibehalten.

3. **MariaDB Galera sql_mode:** Muss leer sein (`sql_mode=`), sonst
   Fehler im i-doit Setup. Ist in der Galera-Config bereits gesetzt.

4. **ghcr-pull-secret:** Privates Image braucht imagePullSecret.
   Bereits als SOPS-Secret deployed.

5. **Pod-Restart nach Secret-Aenderung:** Falls Secrets aktualisiert werden,
   muessen die Pods manuell restartet werden:
   `kubectl rollout restart deployment idoit -n idoit`

6. **Upload-Verzeichnisse muessen manuell angelegt werden:** Der Setup-Wizard
   prueft `/var/www/html/i-doit/upload/files/` und `upload/images/`. Diese
   existieren nicht im PVC nach dem ersten Start. Vor dem Setup-Wizard
   muessen sie manuell erstellt werden:
   ```bash
   kubectl exec -it <pod> -n idoit -- bash -c \
     "mkdir -p /var/www/html/i-doit/upload/files /var/www/html/i-doit/upload/images && \
      chown -R www-data:www-data /var/www/html/i-doit/upload"
   ```
   Die Verzeichnisse liegen auf dem PVC (subPath: upload) und ueberleben
   Pod-Restarts.

7. **Setup-Wizard benoetigt Root-DB-Zugang:** Der Wizard muss unter
   "Connection settings" den MariaDB **root**-User und dessen Passwort
   verwenden (nicht den idoit-User). Der idoit-User wird unter
   "MySQL user settings" eingetragen. Root-Passwort:
   ```bash
   sops --decrypt kubernetes/environments/{env}/mariadb-secrets/mariadb-credentials.enc.yaml | grep ROOT_PASSWORD
   ```

8. **Globale DB-Rechte temporaer noetig:** Die MariaDB Operator Grant CRDs
   geben dem idoit-User nur DB-spezifische Rechte. Der Setup-Wizard
   benoetigt aber globale Rechte (CREATE DATABASE, GRANT). Ablauf:
   - VOR dem Wizard: `GRANT ALL PRIVILEGES ON *.* TO 'idoit'@'%';`
   - NACH dem Wizard: Globale Rechte wieder entziehen:
     ```bash
     REVOKE ALL PRIVILEGES ON *.* FROM 'idoit'@'%';
     GRANT ALL PRIVILEGES ON idoit_system.* TO 'idoit'@'%';
     GRANT ALL PRIVILEGES ON idoit_data.* TO 'idoit'@'%';
     FLUSH PRIVILEGES;
     ```
   - Kontrolle: `SHOW GRANTS FOR 'idoit'@'%';` sollte nur die
     DB-spezifischen Grants zeigen.

9. **query_cache Warnung ignorierbar:** MariaDB 11.8 zeigt eine Warnung
   fuer query_cache_size und query_cache_limit. Diese sind in 11.8
   deprecated und koennen ignoriert werden.

10. **MariaDB 11.8.6 Versionswarnung ignorierbar:** i-doit zeigt eine
    Warnung, dass MariaDB 11.8 nicht offiziell unterstuetzt wird.
    Funktioniert aber problemlos (bestaetigt auf DEV, TEST, PROD).

---

## Arbeitsumgebungen

- **Windows-Laptop:** `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2`
- **MacMini/MacBook:** `/Users/danielhenke/git/eneg-k8s-infrastructure-v2`
- **k8s-mgmt-10 (192.168.180.10):** `~/git/eneg-k8s-infrastructure-v2`

## Cluster-Zugaenge

| Cluster | Context | ArgoCD URL |
|---------|---------|------------|
| DEV | k8s-dev | https://argocd-dev-v2.eneg.de |
| TEST | k8s-test | https://argocd-test.eneg.de |
| PROD | k8s-prod | https://argocd-prod.eneg.de |

---

## Durchfuehrungsprotokoll

| Umgebung | Datum | Status | Mandant-Title | Bemerkungen |
|----------|-------|--------|---------------|-------------|
| TEST | 30.03.2026 | ✅ Abgeschlossen | eNeG Test | Upload-Dirs + globale Grants vor Wizard noetig |
| PROD | 30.03.2026 | ✅ Abgeschlossen | eNeG | Gleicher Ablauf, keine Probleme |

---

*Erstellt am 30.03.2026. Post-Deployment abgeschlossen am 30.03.2026.*
