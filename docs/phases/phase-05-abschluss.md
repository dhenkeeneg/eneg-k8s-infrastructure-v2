# Phase 5: Datenbank-Cluster — Abschlussdokument

**Status:** ✅ Abgeschlossen
**Gestartet am:** 24.02.2026
**Abgeschlossen am:** 25.02.2026
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Zusammenfassung

Phase 5 hat die gesamte Datenbank-Infrastruktur fuer den DEV-Cluster aufgebaut:
zwei PostgreSQL HA-Cluster (CloudNativePG) und ein MariaDB Galera-Cluster
(mariadb-operator). Beide Datenbank-Engines werden ueber Kubernetes-native
Operatoren verwaltet, die ein deklaratives Management via CRDs ermoeglichen.
Die Backup-Strategie umfasst Physical Backups (Barman/mariabackup),
WAL-Archivierung und logische SQL-Dumps (pg_dumpall), alle auf S3-Storage
auf nas10.eneg.de.

---

## Architektur-Entscheidungen

### Hybrid-Ansatz: 2 PostgreSQL-Cluster + 1 MariaDB-Cluster

| Cluster | Engine | Instanzen | Apps | Begruendung |
|---|---|---|---|---|
| **cnpg-shared** | PostgreSQL 17.8 | 3 (1 Primary + 2 Replicas) | n8n, Keycloak, Gitea, Papermerge | Leichtgewichtige Apps, aehnliches Lastprofil |
| **cnpg-erp** | PostgreSQL 17.8 | 3 (1 Primary + 2 Replicas) | Odoo, OpenProject | Schwergewichtige Apps mit hoher DB-Last |
| **mariadb-galera** | MariaDB 11.8.6 LTS | 3 (Multi-Master Galera) | Nextcloud, i-doit, KixDesk | MariaDB-pflichtige Apps |

### Skalierung ueber Umgebungen

| Parameter | DEV | TEST | PROD |
|---|---|---|---|
| PG shared_buffers (shared) | 256MB | 512MB | 1GB |
| PG shared_buffers (erp) | 512MB | 1GB | 2GB |
| PG max_connections (shared) | 200 | 300 | 500 |
| PG max_connections (erp) | 100 | 200 | 300 |
| MariaDB innodb_buffer_pool_size | 512MB | 1GB | 2GB |
| Storage pro PG-Cluster | 20Gi | 50Gi | 100Gi |
| Storage pro MariaDB-Node | 20Gi | 50Gi | 100Gi |

### Storage-Strategie: strict-local + Replica-Count 1

**Entscheidung:** Longhorn Volumes fuer Datenbanken mit `strict-local` Data Locality
und nur 1 Longhorn-Replica pro Volume.

**Begruendung:**
- PostgreSQL (CNPG) repliziert Daten selbst ueber Streaming Replication (3 Instanzen)
- MariaDB Galera repliziert Daten selbst ueber Galera Sync (3 Nodes)
- Longhorn-Replicas + DB-Replikation = doppelte Schreiblast (unnoetig)
- `strict-local` eliminiert Netzwerk-Latenz fuer Disk I/O
- ~50% Storage-Ersparnis gegenueber Replica-Count 2
- Datensicherheit durch DB-eigene Replikation + S3-Backups gewaehrleistet

---

## Komponenten und Versionen (tatsaechlich installiert)

| Komponente | Version | Installationsmethode | Namespace |
|---|---|---|---|
| CloudNativePG Operator | 1.28.1 (Chart 0.27.1) | Helm Multi-Source | cnpg-system |
| PostgreSQL | 17.8 (Image: system-bookworm) | CNPG Cluster CRD | databases |
| mariadb-operator CRDs | 25.10.4 | Helm | (cluster-weit) |
| mariadb-operator | 25.10.4 | Helm Multi-Source | mariadb-operator |
| MariaDB Server | 11.8.6 LTS | mariadb-operator CRD | databases |
| Longhorn StorageClass (DB) | - | Kubernetes Manifest | - |

### Helm Repositories

| Repository | URL |
|---|---|
| CloudNativePG | https://cloudnative-pg.github.io/charts |
| mariadb-operator | https://helm.mariadb.com/mariadb-operator |

---

## Backup-Strategie (implementiert)

### S3-Ziel: nas10.eneg.de (QuObject)

**Endpunkt:** `http://nas10.eneg.de:8010`
**Credentials:** SOPS-verschluesselt im Git, getrennt pro Engine

### Backup-Zeitplan

| Zeit (UTC) | Backup | Typ | Methode | Ziel-Bucket | Retention |
|---|---|---|---|---|---|
| Kontinuierlich | cnpg-shared + cnpg-erp | WAL-Archivierung | Barman (CNPG nativ) | k8s-dev-postgres-wal | 7 Tage |
| 02:00 | cnpg-shared | Physical Backup | Barman (ScheduledBackup CRD) | k8s-dev-postgres-wal | 7 Tage |
| 02:15 | cnpg-erp | Physical Backup | Barman (ScheduledBackup CRD) | k8s-dev-postgres-wal | 7 Tage |
| 02:30 | mariadb-galera | Physical Backup | mariabackup (PhysicalBackup CRD) | k8s-dev-mariadb-backup | 7 Tage |
| 03:00 | cnpg-shared | Logical Backup | pg_dumpall (CronJob) | k8s-dev-postgres-backup | 32 Tage |
| 03:15 | cnpg-erp | Logical Backup | pg_dumpall (CronJob) | k8s-dev-postgres-backup | 32 Tage |

### Backup-Typen erklaert

**Physical Backup (Barman / mariabackup):** Binaere Kopie der Datenbank-Dateien.
Schnelles Restore, Point-in-Time Recovery moeglich (PG via WAL).
Gebunden an exakte Engine-Version.

**Logical Backup (pg_dumpall):** SQL-Dump aller Datenbanken, Rollen und
Tablespaces. Portabel ueber Versionen hinweg, menschenlesbar, einzelne
Datenbanken/Tabellen extrahierbar. Sichert automatisch alle zukuenftigen
Datenbanken (Phase 6+) ohne Konfigurationsaenderung.

**WAL-Archivierung:** Kontinuierliche Sicherung der Write-Ahead-Logs.
Ermoeglicht Point-in-Time Recovery bis auf Transaktionsebene.

### Bucket-Struktur auf S3

```
k8s-dev-postgres-wal/
├── cnpg-shared/          # WAL + Physical Backups (Barman)
└── cnpg-erp/             # WAL + Physical Backups (Barman)

k8s-dev-postgres-backup/
├── cnpg-shared/          # Logical Backups (pg_dumpall .sql.gz)
└── cnpg-erp/             # Logical Backups (pg_dumpall .sql.gz)

k8s-dev-mariadb-backup/
└── mariadb-galera/       # Physical Backups (mariabackup .xb.gz)
```

---

## Services und Zugriff

### PostgreSQL Services (CNPG)

| Service | Typ | Verwendung |
|---|---|---|
| cnpg-shared-rw | ClusterIP | Read-Write (Primary) |
| cnpg-shared-ro | ClusterIP | Read-Only (Replicas, Load-Balanced) |
| cnpg-shared-r | ClusterIP | Read-Any (alle Instanzen) |
| cnpg-erp-rw | ClusterIP | Read-Write (Primary) |
| cnpg-erp-ro | ClusterIP | Read-Only (Replicas) |
| cnpg-erp-r | ClusterIP | Read-Any (alle Instanzen) |

**Verbindungsbeispiel fuer Apps (Phase 6):**
```
Host: cnpg-shared-rw.databases.svc.cluster.local
Port: 5432
User: <app-user>
Password: <aus Secret>
```

### MariaDB Services (Galera)

| Service | Typ | Verwendung |
|---|---|---|
| mariadb-galera | ClusterIP | Standard-Zugriff |
| mariadb-galera-primary | ClusterIP | Nur Primary Node |
| mariadb-galera-secondary | ClusterIP | Nur Secondary Nodes |
| mariadb-galera-internal | ClusterIP (Headless) | Galera-interne Kommunikation |

**Verbindungsbeispiel fuer Apps (Phase 6):**
```
Host: mariadb-galera.databases.svc.cluster.local
Port: 3306
User: <app-user>
Password: <aus Secret>
```

---

## Implementierte Schritte

### Schritt 5.1: Longhorn StorageClass ✅

StorageClass `longhorn-db` erstellt mit strict-local, Replica=1, Retain.
App-of-Apps Pattern fuer Infrastructure-Apps implementiert
(`dev-infrastructure-app.yaml` ueberwacht `environments/dev/infrastructure/`).

### Schritt 5.2: S3-Credentials (SOPS) ✅

SOPS-verschluesselte Secrets fuer S3-Zugang:
- `cnpg-s3-credentials` (ACCESS_KEY_ID, SECRET_ACCESS_KEY, S3_ENDPOINT)
- `mariadb-credentials` (ROOT_PASSWORD, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_ENDPOINT)

### Schritt 5.3: CloudNativePG Operator ✅

CNPG Operator v1.28.1 (Helm Chart 0.27.1) als Multi-Source Helm App deployed.
10 CRDs registriert.

### Schritt 5.4: PostgreSQL Cluster cnpg-shared ✅

3 Instanzen (1 Primary + 2 Replicas), 20Gi Data + 5Gi WAL pro Instanz.
Resources: 512Mi-1Gi RAM, 250m-1 CPU.
PostgreSQL-Tuning: shared_buffers=256MB, max_connections=200.

### Schritt 5.5: PostgreSQL Cluster cnpg-erp ✅

3 Instanzen (1 Primary + 2 Replicas), 20Gi Data + 5Gi WAL pro Instanz.
Resources: 1Gi-2Gi RAM, 500m-2 CPU.
PostgreSQL-Tuning: shared_buffers=512MB, max_connections=100, work_mem=8MB.

### Schritt 5.6: CNPG Backup-Konfiguration ✅

WAL-Archivierung laeuft kontinuierlich auf S3.
ScheduledBackups (Barman Physical) taeglich um 02:00/02:15 UTC.
Logische Backups (pg_dumpall CronJobs) taeglich um 03:00/03:15 UTC mit 32 Tagen Retention.
`enableSuperuserAccess: true` fuer pg_dumpall erforderlich.

### Schritt 5.7: mariadb-operator ✅

mariadb-operator v25.10.4 (urspruenglich 25.10.2 geplant, Patch-Update wegen
Galera PhysicalBackup-Fix). CRDs und Operator als separate Helm-Apps deployed.
3 Deployments: Operator, Webhook, Cert-Controller.

### Schritt 5.8: MariaDB Galera Cluster ✅

3-Node Galera Multi-Master Cluster (MariaDB 11.8.6 LTS).
20Gi Storage pro Node. innodb_buffer_pool_size=512MB, max_connections=200.
Auto-Failover aktiviert. TLS automatisch durch Operator konfiguriert.

### Schritt 5.9: MariaDB Backup ✅

PhysicalBackup (mariabackup) taeglich 02:30 UTC auf S3 mit gzip-Kompression.
7 Tage Retention. Backup von PreferReplica (schont Primary).

### Schritt 5.10: Validierung ✅

Alle Cluster Healthy, alle Backups erfolgreich, Galera wsrep_cluster_size=3.
OutOfSync-Problem bei cnpg-cluster durch CPU-Normalisierung behoben.

### Schritt 5.11: PostgreSQL Minor-Upgrade ⏳

PostgreSQL 17.9 (Out-of-Cycle-Release) wird separat durchgefuehrt wenn verfuegbar.

### Schritt 5.12: Dokumentation ✅

Dieses Abschlussdokument.

---

## Dateistruktur (tatsaechlich erstellt)

```
kubernetes/
├── base/
│   ├── cloudnative-pg/
│   │   ├── operator/
│   │   │   └── values.yaml                     # CNPG Operator Helm Values
│   │   ├── cluster/
│   │   │   ├── cnpg-shared.yaml                # Shared PG Cluster CRD
│   │   │   ├── cnpg-erp.yaml                   # ERP PG Cluster CRD
│   │   │   └── scheduled-backup.yaml           # ScheduledBackup CRDs
│   │   ├── backup/
│   │   │   ├── configmap-backup-script.yaml     # pg_dumpall Script (ConfigMap)
│   │   │   ├── cronjob-shared.yaml             # CronJob: Logical Backup cnpg-shared
│   │   │   └── cronjob-erp.yaml                # CronJob: Logical Backup cnpg-erp
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml
│   │       ├── s3-credentials.yaml.template     # Vorlage (unverschluesselt)
│   │       └── s3-credentials.enc.yaml          # SOPS-verschluesselt
│   ├── mariadb-galera/
│   │   ├── operator/
│   │   │   └── values.yaml                     # mariadb-operator Helm Values
│   │   ├── cluster/
│   │   │   ├── mariadb-galera.yaml             # Galera Cluster CRD
│   │   │   └── physical-backup.yaml            # PhysicalBackup CRD
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml
│   │       ├── mariadb-credentials.yaml.template
│   │       └── mariadb-credentials.enc.yaml     # SOPS-verschluesselt
│   └── longhorn/
│       └── storageclass-db.yaml                 # DB StorageClass
├── bootstrap/
│   └── dev-infrastructure-app.yaml              # App-of-Apps (NEU in Phase 5)
└── environments/
    └── dev/
        └── infrastructure/
            ├── longhorn-storageclass-app.yaml    # StorageClass
            ├── cnpg-operator-app.yaml            # CNPG Operator (Helm)
            ├── cnpg-cluster-app.yaml             # PG Cluster CRDs
            ├── cnpg-secrets-app.yaml             # S3 Credentials (KSOPS)
            ├── cnpg-logical-backup-app.yaml      # pg_dumpall CronJobs
            ├── mariadb-operator-crds-app.yaml    # MariaDB CRDs (Helm)
            ├── mariadb-operator-app.yaml         # MariaDB Operator (Helm)
            ├── mariadb-cluster-app.yaml          # Galera Cluster + Backup
            └── mariadb-secrets-app.yaml          # MariaDB Credentials (KSOPS)
```

---

## ArgoCD Applications (nach Phase 5)

### Bestehend (Phase 4)

| Application | Typ | Namespace |
|---|---|---|
| metallb | Kustomize | metallb-system |
| traefik | Helm (multi-source) | traefik |
| cert-manager | Helm (multi-source) | cert-manager |
| cert-manager-webhook-ionos | Helm | cert-manager |
| cert-manager-secrets | Kustomize + KSOPS | cert-manager |
| cert-manager-config | Directory | cert-manager |
| longhorn | Helm (multi-source) | longhorn-system |
| longhorn-ingress | Directory | traefik |

### Neu (Phase 5)

| Application | Typ | Namespace | Sync-Wave |
|---|---|---|---|
| dev-infrastructure | App-of-Apps | argocd | - |
| longhorn-storageclass | Directory | longhorn-system | 3 |
| cnpg-operator | Helm (multi-source) | cnpg-system | 4 |
| cnpg-secrets | Kustomize + KSOPS | databases | 4 |
| cnpg-cluster | Directory | databases | 5 |
| cnpg-logical-backup | Directory | databases | 6 |
| mariadb-operator-crds | Helm | (cluster-weit) | 4 |
| mariadb-operator | Helm (multi-source) | mariadb-operator | 4 |
| mariadb-secrets | Kustomize + KSOPS | databases | 4 |
| mariadb-cluster | Directory | databases | 5 |

**Gesamt:** 18 ArgoCD Applications (8 bestehend + 10 neu)

---

## Key Learnings

### App-of-Apps Pattern
Infrastructure-Apps wurden zuvor manuell per `kubectl apply` deployed. Das neue
App-of-Apps Pattern (`dev-infrastructure-app.yaml`) ueberwacht das
`environments/dev/infrastructure/`-Verzeichnis und deployed automatisch alle
`*-app.yaml` Dateien. Neue Datenbank-Apps erscheinen sofort nach Git Push.

### CRD-Namenskonflikte
`kubectl get backups` loest zu `backups.longhorn.io` auf statt
`backups.postgresql.cnpg.io`. Immer die volle API-Gruppe verwenden:
`kubectl get backups.postgresql.cnpg.io -n databases`

### CPU-Normalisierung in Kubernetes
Kubernetes normalisiert CPU-Werte: `1000m` wird zu `1`, `2000m` wird zu `2`.
In CRDs sollte man die normalisierte Form verwenden (ganze Zahlen statt Millicore),
um ArgoCD OutOfSync-Diffs zu vermeiden.

### MariaDB vs. MySQL Parameter
MariaDB kennt nicht alle MySQL-Parameter. `log_error_verbosity` (MySQL)
existiert nicht in MariaDB — stattdessen `log_warnings` verwenden.

### MariaDB Galera Feldnamen
Das Feld fuer automatisches Failover heisst `autoFailover` (nicht
`automaticFailover`). Immer `kubectl explain` verwenden um CRD-Felder
zu validieren bevor man YAML schreibt.

### Galera Init-Job Reihenfolge
Der mariadb-operator erstellt einen Init-Job der das Datenverzeichnis vorbereitet.
Fehler in der MariaDB-Konfiguration (wie unbekannte Parameter) fuehren zum
BackoffLimitExceeded des Init-Jobs. Nach Konfigurationskorrektur muessen
Init-Job und PVC geloescht werden, damit der Operator sauber neu starten kann.

### S3-Endpoint bei mariadb-operator
Der mariadb-operator erwartet den S3-Endpoint **ohne Schema** (z.B.
`nas10.eneg.de:8010` statt `http://nas10.eneg.de:8010`). TLS muss explizit
mit `tls.enabled: false` deaktiviert werden fuer HTTP-Endpoints.

### CNPG Superuser-Zugang
Standardmaessig erstellt CNPG nur einen `app`-User (Secret: `cnpg-*-app`).
Fuer `pg_dumpall` wird der `postgres`-Superuser benoetigt. Dafuer muss
`enableSuperuserAccess: true` in der Cluster-CRD gesetzt werden, was ein
zusaetzliches `cnpg-*-superuser`-Secret erstellt.

### postgres:17 Image und awscli
Das offizielle `postgres:17`-Image (Debian Trixie) hat kein Python/pip.
awscli muss per `apt-get install -y awscli` installiert werden, nicht per pip.

### CNPG PostgreSQL Image-Tags
Format: `<major>.<minor>-<type>-<os>` (z.B. `17.8-system-bookworm`).
`system` enthält Barman Cloud (benoetigt fuer S3-Backups).
`minimal` und `standard` sind neuere Images wo Barman als Plugin kommt.

### Helm Chart vs. App Version
Chart-Version ist nicht gleich Operator-Version. Beispiele:
- CNPG: Chart 0.27.1 = Operator 1.28.1
- mariadb-operator: Chart 25.10.4 = Operator 25.10.4 (gleich in diesem Fall)
Immer `appVersion` im Chart pruefen.

---

## Storage-Uebersicht

### PVCs (18 Volumes)

| PVC-Muster | Anzahl | Groesse | StorageClass | Verwendung |
|---|---|---|---|---|
| cnpg-shared-{1,2,3} | 3 | 20Gi | longhorn-db | PG Shared Data |
| cnpg-shared-{1,2,3}-wal | 3 | 5Gi | longhorn-db | PG Shared WAL |
| cnpg-erp-{1,2,3} | 3 | 20Gi | longhorn-db | PG ERP Data |
| cnpg-erp-{1,2,3}-wal | 3 | 5Gi | longhorn-db | PG ERP WAL |
| storage-mariadb-galera-{0,1,2} | 3 | 20Gi | longhorn-db | MariaDB Data |
| galera-mariadb-galera-{0,1,2} | 3 | 100Mi | longhorn | Galera State |

**Gesamt-Storage:** ~210 Gi (6×20Gi Data PG + 6×5Gi WAL PG + 3×20Gi MariaDB + 300Mi Galera)

---

## Naechste Schritte

### Phase 5.11 (ausstehend): PostgreSQL Minor-Upgrade

PostgreSQL 17.9 (Out-of-Cycle-Release, geplant 26.02.2026) wird in einem
separaten Vorgang eingespielt. CNPG fuehrt Rolling Updates durch:
Replicas zuerst, Primary zuletzt (Switchover + Update), keine Downtime.

### Phase 6: Applikations-Deployment

- Datenbanken per CNPG Database CRD und mariadb-operator Database CRD anlegen
- App-spezifische DB-User und Grants konfigurieren
- Pilot-Apps deployen (n8n, Keycloak, Gitea)
- Ingress-Pattern fuer jede App (wie in Phase 4 definiert)

### Phase 8: Backup & Disaster Recovery

- Velero fuer Kubernetes-Ressourcen-Backups (ergaenzt DB-Backups)
- Disaster-Recovery-Tests durchfuehren
- Restore-Runbooks dokumentieren

---

## Aenderungshistorie

| Datum | Aenderung |
|---|---|
| 24.02.2026 | Initiale Version (Planungsdokument) |
| 25.02.2026 | Abschlussdokument: Phase 5 implementiert und validiert |
