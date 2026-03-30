# Timezone-Konfiguration: Europe/Berlin

**Erstellt:** 30.03.2026
**Status:** ✅ Abgeschlossen (DEV, TEST, PROD)

---

## Uebersicht

Alle Datenbank-Cluster und Applikationen sind auf `Europe/Berlin` konfiguriert.
Dies stellt sicher, dass Zeitstempel in Logs, Datenbanken und Anwendungs-UIs
korrekt in deutscher Lokalzeit angezeigt werden.

---

## Konfigurierte Komponenten

### Datenbank-Cluster

| Komponente | Konfiguration | Datei |
|---|---|---|
| CNPG Shared (PostgreSQL) | `timezone: "Europe/Berlin"` in postgresql.parameters | `cnpg-cluster/cnpg-shared.yaml` |
| CNPG ERP (PostgreSQL) | `timezone: "Europe/Berlin"` in postgresql.parameters | `cnpg-cluster/cnpg-erp.yaml` |
| MariaDB Galera | `default_time_zone=Europe/Berlin` in myCnf | `mariadb-cluster/mariadb-galera.yaml` |

### Applikationen

| App | ENV-Variable | Datei |
|---|---|---|
| n8n | `GENERIC_TIMEZONE` + `TZ` | `apps/n8n/deployment.yaml` |
| OpenProject | `TZ` | `apps/openproject/deployment.yaml` |
| Keycloak | `TZ` | `apps/keycloak/deployment.yaml` |
| Odoo | `TZ` | `apps/odoo/deployment.yaml` |
| i-doit | `TZ` | `apps/idoit/deployment.yaml` |
| it-info-versand | `TZ` | `apps/it-info-versand/deployment.yaml` |

### Backup-CronJobs (behalten UTC)

Die Backup-CronJob-Schedules verwenden bewusst UTC, um Probleme mit
Sommerzeit-/Winterzeit-Umstellungen zu vermeiden:

- CNPG ScheduledBackups (cnpg-shared-full, cnpg-erp-full): UTC (CNPG CRD-Standard)
- CNPG Logical Backup CronJobs: UTC im Kommentar
- MariaDB PhysicalBackup: UTC im Kommentar
- Garage Backup CronJob: `timeZone: Europe/Berlin` (Kubernetes-native)
- Odoo Backup CronJob: `timeZone: Europe/Berlin` (Kubernetes-native)

---

## Besonderheiten

### MariaDB: Timezone-Tabellen erforderlich

MariaDB kennt benannte Zeitzonen (wie `Europe/Berlin`) nur, wenn die
Timezone-Tabellen in der `mysql`-Datenbank gefuellt sind. Dies muss
**einmalig pro Node** gemacht werden, BEVOR die Config-Aenderung greift:

```bash
# Root-Passwort aus Kubernetes-Secret auslesen:
ROOT_PW=$(kubectl get secret mariadb-credentials -n databases \
  -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

# Auf allen 3 Galera-Nodes laden:
for pod in mariadb-galera-0 mariadb-galera-1 mariadb-galera-2; do
  echo "=== $pod ==="
  kubectl exec -it $pod -n databases -- bash -c \
    "mariadb-tzinfo-to-sql /usr/share/zoneinfo | mariadb -u root -p'$ROOT_PW' mysql"
done
```

**Wichtig:** Das Tool heisst `mariadb-tzinfo-to-sql` (nicht `mysql_tzinfo_to_sql`).

### PostgreSQL (CNPG): Kein manueller Schritt noetig

CNPG wendet den `timezone`-Parameter per Rolling Restart automatisch an.
Keine manuellen Schritte erforderlich.

### App-Container: TZ-Variable

Die `TZ`-Umgebungsvariable wird vom Linux-System im Container ausgewertet.
Die meisten Container-Images (Debian/Ubuntu-basiert) enthalten bereits
die Timezone-Datenbank in `/usr/share/zoneinfo/`. Kein manueller Schritt
noetig — der Pod-Restart durch ArgoCD genuegt.

---

## Pruefbefehle

```bash
# PostgreSQL:
kubectl exec -it <cnpg-pod> -n databases -- psql -U postgres -c "SHOW timezone;"
# Erwartung: Europe/Berlin

# MariaDB:
ROOT_PW=$(kubectl get secret mariadb-credentials -n databases \
  -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)
kubectl exec -it mariadb-galera-0 -n databases -- \
  mariadb -u root -p"$ROOT_PW" -e "SELECT @@global.time_zone, NOW();"
# Erwartung: Europe/Berlin, korrekte Lokalzeit

# App-Container:
kubectl exec -it <pod> -n <namespace> -- date
# Erwartung: CEST (Sommer) bzw. CET (Winter)
```

---

## Durchfuehrungsprotokoll

| Umgebung | Datum | DB-Cluster | Apps | Status |
|----------|-------|------------|------|--------|
| DEV | 30.03.2026 | CNPG + MariaDB | Alle 6 Apps | ✅ Bestaetigt |
| TEST | 30.03.2026 | CNPG + MariaDB | Alle 6 Apps | ✅ Bestaetigt |
| PROD | 30.03.2026 | CNPG + MariaDB | Alle 6 Apps | ✅ Bestaetigt |

---

*Erstellt am 30.03.2026.*
