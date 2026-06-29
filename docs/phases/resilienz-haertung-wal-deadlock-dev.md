# Resilienz-Haertung: WAL-Deadlock / Infra-Pod-Restart-Kaskade (DEV)

**Datum:** 2026-06-29
**Umgebung:** k8s-dev
**Bezug:** `docs/incidents/2026-06-29-cnpg-wal-deadlock-longhorn-kaskade.md`
**Status:** DEV abgeschlossen; TEST/PROD-Rollout offen

---

## Ziel

Haertung gegen das Ausfallmuster vom 2026-06-29: ein gleichzeitiger Restart
mehrerer Infra-Pods loeste eine vierstufige Kaskade aus (CNPG WAL-Deadlock →
Longhorn-Expansion-Haenger → iSCSI-Altlasten → Folgeschaeden). Die Massnahmen
setzen an der Wurzel (Stufe 1) an, um die Kette gar nicht erst entstehen zu
lassen, und ergaenzen Frueherkennung.

## Umgesetzte Massnahmen (DEV)

### 1. max_slot_wal_keep_size = 6GB (beide CNPG-Cluster)

Begrenzt, wieviel WAL ein (auch inaktiver) Replication-Slot zurueckhalten darf.
Verhindert den WAL-Deadlock an der Wurzel: das 8Gi-WAL-Volume kann nicht mehr
durch einen haengenden Slot volllaufen. Bei Ueberschreitung faellt die betroffene
Replica auf S3-Archive-Restore zurueck (Archiving laeuft durchgehend).
`sighup`-Parameter (Reload, kein Restart noetig).

- Dateien: `kubernetes/environments/dev/cnpg-cluster/cnpg-{erp,shared}.yaml`
- Feld: `spec.postgresql.parameters.max_slot_wal_keep_size: "6GB"`
- 8Gi WAL-Volume → 6GB Deckel laesst ~2Gi Puffer; normale HA-Slots liegen weit
  darunter.

### 2. PriorityClass eneg-stateful-critical (CNPG + MariaDB-Galera)

Schuetzt die zustandsbehafteten DB-Pods im Node-Pressure-Fall vor Verdraengung.
Ohne eigene PriorityClass liefen sie auf Priority 0 (gleichauf mit Pilot-Apps).

- Definition: `kubernetes/base/priorityclasses/eneg-stateful-critical.yaml`
  (cluster-global, `value: 900000000`, `globalDefault: false`)
- ArgoCD-App: `kubernetes/environments/dev/infrastructure/priorityclasses-app.yaml`
  (Sync-Wave 1, `directory.include` auf die eine Datei)
- Einbindung CNPG: `spec.priorityClassName` in cnpg-{erp,shared}.yaml
- Einbindung Galera: `spec.priorityClassName` in mariadb-galera.yaml
- Wert-Einordnung: knapp unter `longhorn-critical` (1e9), damit der Storage-Layer
  im Pressure-Fall Vorrang behaelt. Bewusst NICHT fuer Monitoring (Beobachter,
  speicherhungrig) und Registry/Zot (3 Replicas HA, DEV-Internet-Fallback).

### 3. Alert CnpgClusterNoPrimary (WAL-Deadlock-Frueherkennung)

Feuert, wenn ein CNPG-Cluster ueber 15 Minuten keinen aktiven Primary hat.
Warnt vor der Henne-Ei-Lage (kein Primary → WAL-Stau → Disk-full → kein Start),
bevor sich das WAL-Volume ueberhaupt zu fuellen beginnt.

- Datei: `kubernetes/base/monitoring/alert-rules/cnpg-alerts.yaml`
- Expr: `count by (cluster, namespace) (cnpg_pg_replication_in_recovery{namespace="databases"} == 0) < 1`
- `for: 15m` (ueberlebt normale Switchovers/Restarts und Sonderfaelle wie
  pg_basebackup-Join oder kurze API-Server-Haenger; der Deadlock baut sich erst
  ueber Stunden auf, im Incident ~3,5 Tage)
- Ergaenzt `CnpgClusterNotReady` (Exporter-Ausfall via `collector_up==0`) ohne
  Ueberschneidung: Exporter weg → NotReady; Exporter da, aber kein Primary → NoPrimary.
- Liegt in `base/` → kommt beim TEST/PROD-Sync automatisch mit.

### 4. CNPG-Operator-Patch 1.28.1 → 1.28.3 (Sicherheit)

Notwendig geworden im Zuge der Analyse: 1.28.3 behebt CVE-2026-44477 (CVSS 9.4,
Metrics-Exporter) und einen Daten-Sicherheits-Bug im Failover-Pfad. Da der
Rolling-Restart (fuer Massnahme 2) ohnehin Switchovers/Restarts ausloest, wurde
zuerst gepatcht, dann neu gestartet.

- Datei: `kubernetes/base/cloudnative-pg/operator/values.yaml`
- Methode: `image.tag: "1.28.3"` bei unveraendertem Chart 0.27.1 (Image-Override).
  Begruendung: Chart-appVersion-Pfad bietet von 1.28.1 nur den Sprung auf 1.29.1
  (Chart 0.28.x = Minor-Upgrade). 1.28.3 ist gleiche Minor-Linie → laut CNPG-
  Versionierungspolitik keine rueckwaerts-inkompatiblen Aenderungen, Chart-CRDs
  bleiben kompatibel.
- Nebenwirkung Metrics: ab 1.28.3 nutzt der Exporter die Rolle
  `cnpg_metrics_exporter` (pg_monitor) statt postgres-Superuser. Standard-Queries
  (`cnpg-default-monitoring`) sind nicht betroffen; im DEV-Log bestaetigt
  (`CREATE ROLE cnpg_metrics_exporter` + `GRANT pg_monitor`), keine Nacharbeit.

## Verifikation (DEV, 2026-06-29)

- CNPG-Rolling-Restart: sauber durchgelaufen (Replicas → In-Place-Primary-Restart
  bei `primaryUpdateMethod: restart`, kein Switchover-Pfad), kein Attach-/WAL-Haenger.
  Beide Cluster healthy 3/3, Archiving OK, Backup OK.
- Galera-Rolling-Restart: alle 3 Nodes per IST (kein SST), `ReplicasFirstPrimaryLast`
  eingehalten, durchgehende Schreibverfuegbarkeit via autoFailover. Cluster Ready/Running.
- Alle DB-Pods (6x CNPG, 3x Galera) tragen `priorityClassName: eneg-stateful-critical`
  (priority 900000000).
- `max_slot_wal_keep_size=6GB` in beiden Cluster-Specs aktiv (sighup-Reload).
- `CnpgClusterNoPrimary` als Regel im Cluster, im Normalzustand inaktiv
  (pro Cluster genau 1 Primary → `count==1`, `<1` false).
- Operator-Deployment `cnpg-cloudnative-pg` auf Image 1.28.3, 1/1 available.

## TEST/PROD-Rollout (offen, sequenziell DEV→TEST→PROD)

Pro Umgebung einzeln, mit Verifikation dazwischen. Reihenfolge je Umgebung:

1. **PriorityClass-Definition zuerst** (muss existieren, bevor ein Workload sie
   referenziert, sonst wird der Pod nicht admittiert):
   - Neue App-Datei `kubernetes/environments/{test,prod}/infrastructure/priorityclasses-app.yaml`
     anlegen (analog DEV, zeigt auf dasselbe `base/priorityclasses/`).
   - Commit/Push, Hard-Refresh `{test,prod}-infrastructure`, verifizieren dass
     PriorityClass im Cluster ist.
2. **CNPG-Operator-Patch 1.28.3**: `image.tag` in den Operator-Values der Umgebung
   setzen (bzw. falls base-Values geteilt: pruefen, ob bereits abgedeckt).
   Loest Rolling-Restart der CNPG-Cluster aus → engmaschig beobachten.
3. **CNPG-Manifeste**: `priorityClassName` + `max_slot_wal_keep_size: 6GB` in den
   cnpg-{erp,shared}.yaml der Umgebung. WAL-Volume-Groesse pruefen (TEST/PROD ggf.
   nicht 8Gi — Deckel < Volume-Groesse halten, ~2Gi Puffer).
4. **MariaDB-Galera**: `priorityClassName` in mariadb-galera.yaml der Umgebung.
   Rolling-Restart → IST/SST beobachten.
5. **CnpgClusterNoPrimary-Alert**: liegt in `base/` → kommt automatisch mit, sobald
   TEST/PROD ihre base-alert-rules referenzieren. Nach Sync verifizieren, dass die
   Regel da ist und nicht faelschlich feuert.

**Wichtig:** WAL-Volume-Groesse je Umgebung pruefen, bevor `max_slot_wal_keep_size`
gesetzt wird. In DEV ist das WAL-Volume 8Gi (nach Incident-Resize); in TEST/PROD
kann die Groesse abweichen. Der Deckel muss deutlich unter der Volume-Groesse
liegen (Faustregel: Volume-Groesse minus ~2Gi Puffer).

## Offene Punkte aus der Resilienz-Analyse (nicht in dieser Runde umgesetzt)

- **Longhorn-Node-Speicher-Alert**: warnen, bevor ein Node real volllaeuft
  (Schwelle z.B. < 15% frei). Am 2026-06-29 war -23 am engsten (~121 GB frei),
  -22 ~142 GB, bei `storage-over-provisioning-percentage: 200`.
- **Speicher-Headroom -22/-23**: verwaiste Volumes/alte PVCs pruefen, ggf.
  Over-Provisioning von 200% auf 150% senken.
- **Resource-Review der neustartenden Infra-Pods** (csi-resizer mit 66, cnpg-operator
  mit 32 Restarts im Incident): Restart-Ursache eingrenzen (OOM? Limits?).
- **Loki-FS-Korruption** (2. Vorfall Mai+Juni): eigene Root-Cause-Untersuchung.
- **CNPG Minor-Upgrade 1.28.x → 1.29.x**: eigenes geplantes Vorhaben (Chart 0.28.x),
  Review der 1.29-Breaking-Changes (Image Catalogs, neue Features) noetig.

## Bewusst NICHT umgesetzt (mit Begruendung)

- **PriorityClass fuer Monitoring**: Beobachter, Verlust temporaer, speicherhungrig
  (Prometheus 3Gi-Limit) → soll im Pressure-Fall eher weichen als eine DB verdraengen.
- **PriorityClass fuer Registry/Zot**: 3 Replicas HA, in DEV Internet-Fallback.
  Fuer PROD (Phase 9a Etappe B, kein Fallback) separat zu bewerten — dann aber eher
  eigene, niedrigere Ueberlegung, nicht stateful-critical. Image-Warmup vor Cutover
  ist die eigentliche PROD-Absicherung, nicht Pod-Priority.
