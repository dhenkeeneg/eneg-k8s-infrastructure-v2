# Phase 5: Datenbank-Cluster — Planungs- und Implementierungsdokument

**Status:** ⏳ In Arbeit
**Gestartet am:** 24.02.2026
**Umgebung:** DEV-Cluster (k8s-dev-21/22/23)

---

## Zusammenfassung

Phase 5 baut die gesamte Datenbank-Infrastruktur fuer den DEV-Cluster auf:
zwei PostgreSQL HA-Cluster (CloudNativePG) und ein MariaDB Galera-Cluster
(mariadb-operator). Beide Datenbank-Engines werden ueber Kubernetes-native
Operatoren verwaltet, die ein deklaratives Management via CRDs ermoeglichen.
Die Backup-Strategie wird direkt integriert mit S3-Storage auf nas10.eneg.de.

---

## Architektur-Entscheidungen

### Hybrid-Ansatz: 2 PostgreSQL-Cluster + 1 MariaDB-Cluster

Statt eines einzelnen Shared-Clusters pro Engine oder eines Clusters pro App
wurde ein Hybrid-Ansatz gewaehlt, der Ressourceneffizienz mit Isolation
der schwergewichtigen Workloads kombiniert.

| Cluster | Engine | Instanzen | Apps | Begruendung |
|---|---|---|---|---|
| **cnpg-shared** | PostgreSQL 17.8 | 3 (1 Primary + 2 Replicas) | n8n, Keycloak, Gitea, Papermerge | Leichtgewichtige Apps, aehnliches Lastprofil |
| **cnpg-erp** | PostgreSQL 17.8 | 3 (1 Primary + 2 Replicas) | Odoo, OpenProject | Schwergewichtige Apps mit hoher DB-Last |
| **mariadb-galera** | MariaDB 11.8.6 LTS | 3 (Multi-Master) | Nextcloud, i-doit, KixDesk | MariaDB-pflichtige Apps |

**Vorteile des Hybrid-Ansatzes:**
- Odoo/OpenProject koennen individuell getuned werden (hoehere shared_buffers, work_mem)
- Noisy-Neighbor-Problem zwischen leichten und schweren Apps eliminiert
- Ressourceneffizient: 6+3=9 DB-Instanzen statt 9×3=27 bei DB-pro-App
- Unabhaengige Maintenance Windows fuer ERP vs. Shared-Cluster

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

**Ausfallszenarien:**

| Szenario | Verhalten | Datenverlust? |
|---|---|---|
| 1 Node faellt aus | CNPG: automatisches Failover, Galera: weiter aktiv | Nein |
| 1 Node kommt zurueck | CNPG: automatische Resync, Galera: SST/IST | Nein |
| Alle 3 Nodes sauber heruntergefahren | Graceful Shutdown, Volumes bleiben lokal | Nein |
| Alle 3 Nodes gleichzeitig Crash (Strom) | WAL evtl. nicht komplett geflusht | Minimal (letzte Sekunden), Recovery via S3 WAL-Archiv |

**Empfehlung fuer geplante Wartung:** Nodes immer sequenziell (Rolling Restart)
herunterfahren, nie alle gleichzeitig.

---

## Komponenten und Versionen

| Komponente | Version | Installationsmethode | Namespace |
|---|---|---|---|
| CloudNativePG Operator | 1.28.1 | Helm Chart | cnpg-system |
| PostgreSQL | 17.8 (spaeter 17.9) | CNPG Cluster CRD | databases |
| mariadb-operator CRDs | 25.10.2 | Helm Chart | mariadb-operator |
| mariadb-operator | 25.10.2 | Helm Chart | mariadb-operator |
| MariaDB Server | 11.8.6 LTS | mariadb-operator CRD | databases |
| Longhorn StorageClass (DB) | - | Kubernetes Manifest | - |

### Helm Repositories

| Repository | URL |
|---|---|
| CloudNativePG | https://cloudnative-pg.github.io/charts |
| mariadb-operator | https://helm.mariadb.com/mariadb-operator |

---

## Backup-Strategie

### S3-Ziel: nas10.eneg.de (QuObject)

**Endpunkt:** `http://nas10.eneg.de:8010`
**Credentials:** Getrennt pro Umgebung (DEV/TEST/PROD)

### Bucket-Struktur (DEV)

| Bucket | Inhalt | Retention |
|---|---|---|
| k8s-dev-postgres-wal | WAL-Archivierung (kontinuierlich) | 7 Tage |
| k8s-dev-postgres-backup | Full Backups (taeglich) | 30 Tage |
| k8s-dev-mariadb-backup | MariaDB Backups (taeglich) | 30 Tage |
| k8s-dev-velero | Kubernetes Resource Backups | 14 Tage |
| k8s-dev-longhorn | Volume Snapshots | 14 Tage |

### Backup-Zeitplan

| Backup-Typ | Engine | Methode | Zeitplan | Retention |
|---|---|---|---|---|
| WAL-Archivierung | PostgreSQL | Barman (CNPG nativ) | Kontinuierlich | 7 Tage |
| Physical Backup | PostgreSQL | Barman (ScheduledBackup CRD) | Taeglich 02:00 | 30 Tage |
| Logical Backup | PostgreSQL | pg_dump (ScheduledBackup CRD) | Taeglich 03:00 | 30 Tage |
| Physical Backup | MariaDB | mariadb-backup (PhysicalBackup CRD) | Taeglich 02:30 | 30 Tage |

---

## Namespace-Struktur

| Namespace | Inhalt |
|---|---|
| cnpg-system | CloudNativePG Operator |
| mariadb-operator | mariadb-operator + CRDs |
| databases | Alle DB-Cluster (cnpg-shared, cnpg-erp, mariadb-galera) |

**Begruendung fuer gemeinsamen `databases`-Namespace:**
- Einfacheres Secret-Management (S3-Credentials einmal deployen)
- Konsistente Network Policies in Phase 9
- Klarere Trennung: Operatoren in eigenen Namespaces, Workloads in `databases`

---
## Implementierungsplan

### Schritt 5.1: Longhorn StorageClasses fuer Datenbanken

**Ziel:** Dedizierte StorageClass `longhorn-db` mit optimierten Einstellungen fuer
Datenbank-Workloads (strict-local, Replica-Count 1, Retain Policy).

**Dateien:**
- `kubernetes/base/longhorn/storageclass-db.yaml` (NEU)

**StorageClass-Uebersicht nach Phase 5:**

| StorageClass | Replicas | Data Locality | Reclaim Policy | Verwendung |
|---|---|---|---|---|
| longhorn (Standard) | 2 | best-effort | Delete | Normale Apps |
| longhorn-db | 1 | strict-local | Retain | Datenbank-Volumes |

**ArgoCD:** Neue Datei wird durch bestehende Longhorn-App automatisch erkannt,
da das longhorn-ingress Directory bereits als Source konfiguriert ist.
Alternativ als separate ArgoCD-App `longhorn-storageclass-app.yaml`.

**Validierung:**
```bash
kubectl get storageclass
# Erwartung: longhorn (default), longhorn-db
```

---

### Schritt 5.2: S3-Credentials als SOPS-Secrets

**Ziel:** S3-Zugangsdaten fuer Backups SOPS-verschluesselt im Git ablegen.

**Dateien:**
- `kubernetes/base/cloudnative-pg/secrets/kustomization.yaml` (NEU)
- `kubernetes/base/cloudnative-pg/secrets/secret-generator.yaml` (NEU)
- `kubernetes/base/cloudnative-pg/secrets/s3-credentials.enc.yaml` (NEU, SOPS-verschluesselt)
- `kubernetes/base/mariadb-galera/secrets/kustomization.yaml` (NEU)
- `kubernetes/base/mariadb-galera/secrets/secret-generator.yaml` (NEU)
- `kubernetes/base/mariadb-galera/secrets/mariadb-credentials.enc.yaml` (NEU, SOPS-verschluesselt)

**S3-Credentials (DEV):**

| Key | Wert |
|---|---|
| ACCESS_KEY_ID | (aus nas10 QuObject) |
| SECRET_ACCESS_KEY | (aus nas10 QuObject) |
| S3_ENDPOINT | http://nas10.eneg.de:8010 |

**SOPS-Verschluesselung:**
```bash
# Auf Management-VM oder Laptop mit Age-Key
sops --encrypt --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
  s3-credentials.yaml > s3-credentials.enc.yaml
```

**Validierung:**
```bash
kubectl get secrets -n databases
# Erwartung: s3-credentials, mariadb-credentials
```

---

### Schritt 5.3: CloudNativePG Operator installieren

**Ziel:** CNPG Operator v1.28.1 als ArgoCD Helm-App deployen.

**Helm Repository:** `https://cloudnative-pg.github.io/charts`
**Chart:** `cloudnative-pg`
**Chart-Version:** Passend zu Operator 1.28.1

**Dateien:**
- `kubernetes/base/cloudnative-pg/operator/values.yaml` (NEU)
- `kubernetes/environments/dev/infrastructure/cnpg-operator-app.yaml` (NEU)
- `kubernetes/base/argocd/cnpg-helm-repo.yaml` (NEU - Helm Repo fuer ArgoCD)

**ArgoCD Application Pattern (Multi-Source Helm):**
```yaml
sources:
  - repoURL: https://cloudnative-pg.github.io/charts
    chart: cloudnative-pg
    targetRevision: <chart-version>
    helm:
      releaseName: cnpg
      valueFiles:
        - $values/kubernetes/base/cloudnative-pg/operator/values.yaml
  - repoURL: git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git
    targetRevision: main
    ref: values
```

**Validierung:**
```bash
kubectl get deployment -n cnpg-system
# Erwartung: cnpg-cloudnative-pg (1/1 Ready)

kubectl get crds | grep cnpg
# Erwartung: clusters.postgresql.cnpg.io, backups.postgresql.cnpg.io, ...
```

---

### Schritt 5.4: PostgreSQL Cluster "cnpg-shared"

**Ziel:** HA PostgreSQL-Cluster fuer leichtgewichtige Apps deployen.

**Dateien:**
- `kubernetes/base/cloudnative-pg/cluster/cnpg-shared.yaml` (NEU)
- `kubernetes/environments/dev/infrastructure/cnpg-cluster-app.yaml` (NEU)

**Cluster-Spezifikation (DEV):**

| Parameter | Wert |
|---|---|
| Instanzen | 3 (1 Primary + 2 Replicas) |
| PostgreSQL-Version | 17.8 |
| Image | ghcr.io/cloudnative-pg/postgresql:17.8 |
| Storage | 20Gi (StorageClass: longhorn-db) |
| shared_buffers | 256MB |
| max_connections | 200 |
| effective_cache_size | 768MB |
| Namespace | databases |
| Backup | WAL-Archivierung auf S3 + ScheduledBackup |

**Datenbanken (werden spaeter in Phase 6 per Database CRD angelegt):**
- n8n
- keycloak
- gitea
- papermerge

**Validierung:**
```bash
kubectl get clusters -n databases
# Erwartung: cnpg-shared (3/3 Ready, Primary: cnpg-shared-1)

kubectl get pods -n databases -l cnpg.io/cluster=cnpg-shared
# Erwartung: 3 Pods Running
```

---

### Schritt 5.5: PostgreSQL Cluster "cnpg-erp"

**Ziel:** Dedizierter HA PostgreSQL-Cluster fuer ERP-Workloads.

**Dateien:**
- `kubernetes/base/cloudnative-pg/cluster/cnpg-erp.yaml` (NEU)
- (Wird durch dieselbe cnpg-cluster-app.yaml deployed wie cnpg-shared)

**Cluster-Spezifikation (DEV):**

| Parameter | Wert |
|---|---|
| Instanzen | 3 (1 Primary + 2 Replicas) |
| PostgreSQL-Version | 17.8 |
| Storage | 20Gi (StorageClass: longhorn-db) |
| shared_buffers | 512MB |
| max_connections | 100 |
| effective_cache_size | 1536MB |
| work_mem | 8MB |
| maintenance_work_mem | 128MB |

**Datenbanken (Phase 6):**
- odoo
- openproject

**Validierung:**
```bash
kubectl get clusters -n databases
# Erwartung: cnpg-shared (3/3), cnpg-erp (3/3)
```

---

### Schritt 5.6: CNPG Backup-Konfiguration

**Ziel:** WAL-Archivierung und geplante Backups auf S3 konfigurieren.

**Dateien:**
- `kubernetes/base/cloudnative-pg/cluster/scheduled-backup.yaml` (NEU)

**Backup-Konfiguration in den Cluster-CRDs:**
```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-dev-postgres-wal/cnpg-shared/
      endpointURL: http://nas10.eneg.de:8010
      s3Credentials:
        accessKeyId:
          name: s3-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-credentials
          key: SECRET_ACCESS_KEY
    retentionPolicy: "7d"
```

**ScheduledBackup CRDs:**

| Backup | Cluster | Typ | Schedule | Retention |
|---|---|---|---|---|
| cnpg-shared-full | cnpg-shared | Physical (Barman) | 0 2 * * * | 30d |
| cnpg-erp-full | cnpg-erp | Physical (Barman) | 0 2 * * * | 30d |

**Validierung:**
```bash
# WAL-Archivierung pruefen
kubectl logs -n databases cnpg-shared-1 | grep "archived WAL"

# Backup-Status pruefen
kubectl get backups -n databases
kubectl get scheduledbackups -n databases
```

---
### Schritt 5.7: mariadb-operator installieren

**Ziel:** mariadb-operator v25.10.2 als ArgoCD Helm-App deployen.
Der Operator wird in zwei Helm Charts aufgeteilt (wie bei cert-manager):
1. mariadb-operator-crds (CRDs separat, damit Uninstall des Operators die CRDs nicht loescht)
2. mariadb-operator (Controller)

**Helm Repository:** `https://helm.mariadb.com/mariadb-operator`
**Charts:** `mariadb-operator-crds` + `mariadb-operator`
**Version:** 25.10.2

**Dateien:**
- `kubernetes/base/mariadb-galera/operator/values.yaml` (NEU)
- `kubernetes/environments/dev/infrastructure/mariadb-operator-crds-app.yaml` (NEU)
- `kubernetes/environments/dev/infrastructure/mariadb-operator-app.yaml` (NEU)
- `kubernetes/base/argocd/mariadb-helm-repo.yaml` (NEU - Helm Repo fuer ArgoCD)

**Validierung:**
```bash
kubectl get deployment -n mariadb-operator
# Erwartung: mariadb-operator (1/1 Ready)

kubectl get crds | grep mariadb
# Erwartung: mariadbs.k8s.mariadb.com, backups.k8s.mariadb.com, ...
```

---

### Schritt 5.8: MariaDB Galera Cluster

**Ziel:** MariaDB Galera-Cluster mit 3 Nodes fuer MariaDB-pflichtige Apps.

**Dateien:**
- `kubernetes/base/mariadb-galera/cluster/mariadb-galera.yaml` (NEU)
- `kubernetes/base/mariadb-galera/secrets/mariadb-credentials.enc.yaml` (NEU)
- `kubernetes/environments/dev/infrastructure/mariadb-cluster-app.yaml` (NEU)
- `kubernetes/environments/dev/infrastructure/mariadb-secrets-app.yaml` (NEU)

**Cluster-Spezifikation (DEV):**

| Parameter | Wert |
|---|---|
| Replicas | 3 (Galera Multi-Master) |
| MariaDB-Version | 11.8.6 |
| Image | mariadb:11.8.6 |
| Storage | 20Gi (StorageClass: longhorn-db) |
| innodb_buffer_pool_size | 512MB |
| Namespace | databases |

**Galera-spezifische Konfiguration:**
```yaml
spec:
  replicas: 3
  galera:
    enabled: true
    primary:
      automaticFailover: true
    sst: mariabackup
    replicaThreads: 1
  storage:
    size: 20Gi
    storageClassName: longhorn-db
```

**Datenbanken (Phase 6):**
- nextcloud
- idoit
- kixdesk

**Validierung:**
```bash
kubectl get mariadbs -n databases
# Erwartung: mariadb-galera (Ready: True, Status: Running)

kubectl get pods -n databases -l app.kubernetes.io/instance=mariadb-galera
# Erwartung: 3 Pods Running

# Galera-Cluster-Status pruefen
kubectl exec -n databases mariadb-galera-0 -- \
  mariadb -u root -p$ROOT_PW -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Erwartung: wsrep_cluster_size = 3
```

---

### Schritt 5.9: MariaDB Backup-Konfiguration

**Ziel:** Automatische Physical Backups auf S3 konfigurieren.

**Dateien:**
- Backup-Konfiguration ist Teil von `mariadb-galera.yaml` (PhysicalBackup CRD)

**Backup-Spezifikation:**
```yaml
apiVersion: k8s.mariadb.com/v1alpha1
kind: PhysicalBackup
metadata:
  name: mariadb-galera-backup
  namespace: databases
spec:
  mariaDbRef:
    name: mariadb-galera
  schedule:
    cron: "30 2 * * *"    # Taeglich 02:30
    suspend: false
  target: Replica
  storage:
    s3:
      bucket: k8s-dev-mariadb-backup
      endpoint: nas10.eneg.de:8010
      accessKeyIdSecretKeyRef:
        name: mariadb-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKeySecretKeyRef:
        name: mariadb-s3-credentials
        key: SECRET_ACCESS_KEY
  retentionPolicy: 30d
```

**Validierung:**
```bash
kubectl get physicalbackups -n databases
# Erwartung: mariadb-galera-backup (Schedule aktiv)
```

---

### Schritt 5.10: Validierung und Tests

**Checkliste nach vollstaendiger Installation:**

| Test | Befehl | Erwartetes Ergebnis |
|---|---|---|
| CNPG Operator laeuft | `kubectl get deploy -n cnpg-system` | 1/1 Ready |
| cnpg-shared Cluster | `kubectl get clusters -n databases` | 3/3 Instances |
| cnpg-erp Cluster | `kubectl get clusters -n databases` | 3/3 Instances |
| PG Primary erreichbar | `kubectl exec cnpg-shared-1 -n databases -- pg_isready` | accepting connections |
| WAL-Archivierung aktiv | `kubectl logs cnpg-shared-1 -n databases \| grep WAL` | archived WAL files |
| mariadb-operator laeuft | `kubectl get deploy -n mariadb-operator` | 1/1 Ready |
| Galera Cluster | `kubectl get mariadbs -n databases` | Ready: True |
| Galera Cluster Size | exec + `SHOW STATUS LIKE 'wsrep_cluster_size'` | 3 |
| ArgoCD Apps alle Healthy | ArgoCD UI | Alle Synced + Healthy |
| StorageClass vorhanden | `kubectl get sc longhorn-db` | Available |
| Longhorn Volumes | Longhorn UI | Volumes auf korrekten Nodes |

**Failover-Test (optional, empfohlen):**
```bash
# CNPG: Primary-Pod loeschen und Failover beobachten
kubectl delete pod cnpg-shared-1 -n databases
# Erwartung: neuer Primary wird automatisch promotet (< 30 Sekunden)

# Galera: einen Node-Pod loeschen
kubectl delete pod mariadb-galera-0 -n databases
# Erwartung: Cluster bleibt verfuegbar, Pod wird neu erstellt
```

---

### Schritt 5.11: PostgreSQL Minor-Upgrade 17.8 → 17.9

**Ziel:** PostgreSQL 17.9 (Out-of-Cycle-Release, geplant 26.02.2026) einspielen
und dabei den CNPG Rolling-Update-Prozess kennenlernen.

**Vorgehen:**
1. Image-Tag in Cluster-CRDs aendern: `17.8` → `17.9`
2. Git commit + push
3. ArgoCD synct automatisch
4. CNPG fuehrt Rolling Update durch:
   - Replicas werden zuerst aktualisiert (eine nach der anderen)
   - Primary wird als letztes aktualisiert (Switchover + Update)
5. Keine Downtime bei korrekter Konfiguration

**Dateien aendern:**
- `kubernetes/base/cloudnative-pg/cluster/cnpg-shared.yaml` → Image-Tag
- `kubernetes/base/cloudnative-pg/cluster/cnpg-erp.yaml` → Image-Tag

**Validierung nach Upgrade:**
```bash
kubectl get clusters -n databases -o wide
# Erwartung: Alle Instanzen auf 17.9

kubectl exec cnpg-shared-1 -n databases -- psql -c "SELECT version();"
# Erwartung: PostgreSQL 17.9
```

---

### Schritt 5.12: Dokumentation

**Ziel:** Dieses Dokument nach Abschluss vervollstaendigen:
- Alle tatsaechlich installierten Versionen eintragen
- Key Learnings dokumentieren
- Dateistruktur aktualisieren
- README.md in docs/phases/ aktualisieren
- Projektplanung v2.0 aktualisieren (Phase 5 Status)

---
## Geplante Dateistruktur

```
kubernetes/
├── base/
│   ├── argocd/
│   │   ├── cnpg-helm-repo.yaml                 # NEU: Helm Repo fuer CNPG
│   │   ├── mariadb-helm-repo.yaml              # NEU: Helm Repo fuer mariadb-operator
│   │   └── ... (bestehend)
│   ├── cloudnative-pg/
│   │   ├── operator/
│   │   │   └── values.yaml                     # CNPG Operator Helm Values
│   │   ├── cluster/
│   │   │   ├── cnpg-shared.yaml                # Shared PG Cluster
│   │   │   ├── cnpg-erp.yaml                   # ERP PG Cluster
│   │   │   └── scheduled-backup.yaml           # ScheduledBackup CRDs
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml
│   │       └── s3-credentials.enc.yaml         # SOPS-verschluesselt
│   ├── mariadb-galera/
│   │   ├── operator/
│   │   │   └── values.yaml                     # mariadb-operator Helm Values
│   │   ├── cluster/
│   │   │   ├── mariadb-galera.yaml             # Galera Cluster CRD
│   │   │   └── mariadb-backup.yaml             # PhysicalBackup CRD
│   │   └── secrets/
│   │       ├── kustomization.yaml
│   │       ├── secret-generator.yaml
│   │       └── mariadb-credentials.enc.yaml    # SOPS-verschluesselt
│   └── longhorn/
│       ├── values.yaml                          # (bestehend)
│       ├── ingress.yaml                         # (bestehend)
│       └── storageclass-db.yaml                 # NEU: DB StorageClass
└── environments/
    └── dev/
        └── infrastructure/
            ├── ... (bestehende 8 Apps)
            ├── longhorn-storageclass-app.yaml    # NEU (oder in bestehende App)
            ├── cnpg-operator-app.yaml            # NEU
            ├── cnpg-cluster-app.yaml             # NEU
            ├── cnpg-secrets-app.yaml             # NEU
            ├── mariadb-operator-crds-app.yaml    # NEU
            ├── mariadb-operator-app.yaml         # NEU
            ├── mariadb-cluster-app.yaml          # NEU
            └── mariadb-secrets-app.yaml          # NEU
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

| Application | Typ | Namespace |
|---|---|---|
| cnpg-operator | Helm (multi-source) | cnpg-system |
| cnpg-cluster | Directory | databases |
| cnpg-secrets | Kustomize + KSOPS | databases |
| mariadb-operator-crds | Helm | mariadb-operator |
| mariadb-operator | Helm (multi-source) | mariadb-operator |
| mariadb-cluster | Directory | databases |
| mariadb-secrets | Kustomize + KSOPS | databases |

---

## Abhaengigkeiten und Reihenfolge

```
Phase 4 (bestehend)
    │
    ▼
Schritt 5.1: StorageClass longhorn-db
    │
    ▼
Schritt 5.2: S3-Credentials (SOPS Secrets)
    │
    ├──────────────────────────┐
    ▼                          ▼
Schritt 5.3: CNPG Operator    Schritt 5.7: mariadb-operator
    │                          │
    ▼                          ▼
Schritt 5.4: cnpg-shared       Schritt 5.8: MariaDB Galera
    │                          │
    ▼                          ▼
Schritt 5.5: cnpg-erp          Schritt 5.9: MariaDB Backup
    │                          │
    ▼                          ▼
Schritt 5.6: CNPG Backup       │
    │                          │
    ├──────────────────────────┘
    ▼
Schritt 5.10: Validierung & Tests
    │
    ▼
Schritt 5.11: PG Minor-Upgrade (17.8 → 17.9, wenn verfuegbar)
    │
    ▼
Schritt 5.12: Dokumentation
```

---

## Key Learnings

*(Wird waehrend der Implementierung ergaenzt)*

---

## Naechste Schritte → Phase 6

- Pilot-Apps deployen (n8n, OpenProject, Odoo)
- Datenbanken per CNPG Database CRD anlegen
- App-spezifische DB-User und Grants konfigurieren
- Ingress-Pattern fuer jede App (wie in Phase 4 definiert)

---

## Aenderungshistorie

| Datum | Aenderung |
|---|---|
| 24.02.2026 | Initiale Version (Planungsdokument) |

---

*Dieses Dokument wird waehrend der Implementierung kontinuierlich aktualisiert
und nach Abschluss als Phase-5-Abschlussdokument finalisiert.*
