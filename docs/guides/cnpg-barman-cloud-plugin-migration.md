# CNPG Barman Cloud Plugin Migration

**Erstellt:** 30.03.2026
**Status:** Ausstehend (vor naechstem CNPG Operator-Upgrade durchfuehren)

---

## Hintergrund

Die native (in-tree) Unterstuetzung fuer Barman Cloud Backups ist seit CNPG 1.26.0 deprecated
und wird in **CNPG 1.30.0 entfernt**. Die aktuelle Installation nutzt CNPG Operator v1.28.1
(Helm Chart v0.27.1), d.h. die Migration muss **vor dem Upgrade auf 1.30.0** erfolgen.

Das externe Plugin `barman-cloud.cloudnative-pg.io` ersetzt die in-tree Barman-Funktionalitaet
und wird von der CNPG-Community als offizieller Nachfolger gepflegt.

## Betroffene Cluster

| Cluster | Namespace | Umgebung | Backup-Ziel |
|---------|-----------|----------|-------------|
| cnpg-shared | databases | DEV, TEST, PROD | nas10.eneg.de (S3) |
| cnpg-erp | databases | DEV, TEST, PROD | nas10.eneg.de (S3) |

## Migrationsstrategie

### Schritt 1: Plugin-Image vorbereiten

Das Barman Cloud Plugin wird als separates Container-Image bereitgestellt.
Die aktuelle Version ist unter https://github.com/cloudnative-pg/plugin-barman-cloud verfuegbar.

```yaml
# Neues Plugin-Format in der Cluster-Spec (ersetzt .spec.backup.barmanObjectStore)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: <backup-object-store-name>
```

### Schritt 2: Cluster-Spec anpassen

Fuer jeden Cluster (cnpg-shared, cnpg-erp) in jeder Umgebung:

1. Plugin-Referenz in `.spec.plugins` hinzufuegen
2. Bestehende `.spec.backup.barmanObjectStore` Konfiguration in ein separates
   `ObjectStore`-Objekt migrieren
3. ScheduledBackup-Ressourcen auf das neue Plugin-Format umstellen

### Schritt 3: Image-Wechsel (optional, empfohlen)

Gleichzeitig das PostgreSQL-Image von `system` auf `standard` wechseln:
- `system`-Image enthaelt Barman CLI (wird nach Migration nicht mehr benoetigt)
- `standard`-Image ist leichter und hat geringere Angriffsflaeche

### Schritt 4: Verifizierung

Nach der Migration pruefen:

```bash
# WAL-Archivierung laeuft
kubectl get cluster -n databases -o jsonpath='{.items[*].status.conditions}'

# Backup manuell ausloesen und pruefen
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: migration-test-backup
  namespace: databases
spec:
  method: barmanObjectStore
  cluster:
    name: cnpg-shared
EOF

# Backup-Status pruefen
kubectl get backup -n databases migration-test-backup -o yaml
```

## Wichtige Hinweise

- **Kein Datenverlust:** Bestehende Backups auf S3 bleiben kompatibel
- **Kein Downtime noetig:** Die Migration kann im laufenden Betrieb erfolgen
- **Reihenfolge:** Erst auf DEV testen, dann TEST, dann PROD
- **Rollback:** Bei Problemen kann auf die in-tree Variante zurueckgewechselt werden,
  solange der Operator < 1.30.0 ist

## Referenzen

- CNPG Plugin Dokumentation: https://cloudnative-pg.io/documentation/current/plugins/
- Barman Cloud Plugin: https://github.com/cloudnative-pg/plugin-barman-cloud
- CNPG Deprecation Notice: https://cloudnative-pg.io/documentation/current/backup_barmanobjectstore/

---

*Diese Anleitung wird vor der tatsaechlichen Migration mit den dann aktuellen
Plugin-Versionen und CNPG-Operator-Versionen aktualisiert.*
