# PostgreSQL Minor-Upgrade + Image-Wechsel: 17.8-system → 17.9-standard

**Erstellt:** 07.04.2026
**Status:** Abgeschlossen — 07.04.2026, alle 3 Umgebungen (DEV, TEST, PROD)
**Geschaetzter Aufwand:** 30 Minuten (alle 3 Umgebungen)
**Risiko:** Niedrig (Minor-Upgrade = Rolling Update, kein Dump/Restore)
**Reihenfolge:** DEV → TEST → PROD

---

## 1. Hintergrund

### Minor-Upgrade 17.8 → 17.9
PostgreSQL 17.9 wurde am 26.02.2026 veroeffentlicht (Out-of-Cycle Release mit
Bugfixes und Sicherheitskorrekturen). Unsere Cluster nutzen noch 17.8.
PostgreSQL empfiehlt grundsaetzlich immer die aktuellste Minor-Version.

### Image-Wechsel system → standard
Die `system`-Images von CloudNativePG sind deprecated und werden zusammen mit
der in-tree Barman Cloud Unterstuetzung entfernt (CNPG 1.30.0). Da die Barman
Cloud Plugin Migration am 07.04.2026 fuer alle Umgebungen abgeschlossen wurde,
wird der gebuendelte Barman-Client im `system`-Image nicht mehr benoetigt.

Das `standard`-Image ist funktional gleichwertig mit `system`, enthaelt aber
keinen Barman-Client mehr. Das Barman Cloud Plugin bringt seinen eigenen
Sidecar-Container mit (`plugin-barman-cloud-sidecar`), der unabhaengig vom
PostgreSQL-Image arbeitet.

**Image-Typen (CloudNativePG postgres-containers):**
- `minimal` — nur PostgreSQL, keine Extras
- `standard` — wie minimal + Barman Cloud (ab PG18: + JIT) — **empfohlen**
- `system` — Legacy, wird entfernt wenn in-tree Barman entfaellt

---

## 2. Voraussetzungen

- [x] Barman Cloud Plugin Migration abgeschlossen (alle Umgebungen, 07.04.2026)
- [x] Alle Cluster healthy (3/3 READY)
- [x] Full-Backups via Plugin erfolgreich (completed)
- [x] Image `ghcr.io/cloudnative-pg/postgresql:17.9-standard-bookworm` existiert (vor Start pruefen)

---

## 3. Aenderung

In **allen 6 Cluster-Dateien** (2 pro Umgebung) eine einzige Zeile aendern:

```yaml
# Vorher:
  imageName: ghcr.io/cloudnative-pg/postgresql:17.8-system-bookworm

# Nachher:
  imageName: ghcr.io/cloudnative-pg/postgresql:17.9-standard-bookworm
```

### Betroffene Dateien

| Umgebung | Datei |
|----------|-------|
| DEV | `kubernetes/environments/dev/cnpg-cluster/cnpg-shared.yaml` |
| DEV | `kubernetes/environments/dev/cnpg-cluster/cnpg-erp.yaml` |
| TEST | `kubernetes/environments/test/cnpg-cluster/cnpg-shared.yaml` |
| TEST | `kubernetes/environments/test/cnpg-cluster/cnpg-erp.yaml` |
| PROD | `kubernetes/environments/prod/cnpg-cluster/cnpg-shared.yaml` |
| PROD | `kubernetes/environments/prod/cnpg-cluster/cnpg-erp.yaml` |

Zusaetzlich existieren die gleichen Dateien in `kubernetes/base/cloudnative-pg/cluster/`,
die ebenfalls aktualisiert werden sollten (Konsistenz).

---

## 4. Durchfuehrung pro Umgebung

### Schritt 1: Image-Verfuegbarkeit pruefen (einmalig)

```bash
# Pruefen ob das Image existiert und pullbar ist
docker pull ghcr.io/cloudnative-pg/postgresql:17.9-standard-bookworm
# Oder auf k8s-mgmt-10:
crictl pull ghcr.io/cloudnative-pg/postgresql:17.9-standard-bookworm
```

Falls das Image nicht existiert, pruefen ob eine andere Minor-Version aktueller ist:
- https://github.com/cloudnative-pg/postgres-containers/pkgs/container/postgresql

### Schritt 2: imageName in Cluster-Manifesten aendern

Per Desktop Commander oder manuell in allen betroffenen Dateien ersetzen:

```
Suchen:   ghcr.io/cloudnative-pg/postgresql:17.8-system-bookworm
Ersetzen: ghcr.io/cloudnative-pg/postgresql:17.9-standard-bookworm
```

### Schritt 3: Commit & Push

```bash
cd C:\Users\dhenke\git\eneg-k8s-infrastructure-v2

# Alle Umgebungen auf einmal (oder einzeln pro Umgebung)
git add kubernetes/environments/dev/cnpg-cluster/cnpg-shared.yaml
git add kubernetes/environments/dev/cnpg-cluster/cnpg-erp.yaml
git add kubernetes/environments/test/cnpg-cluster/cnpg-shared.yaml
git add kubernetes/environments/test/cnpg-cluster/cnpg-erp.yaml

git add kubernetes/environments/prod/cnpg-cluster/cnpg-shared.yaml
git add kubernetes/environments/prod/cnpg-cluster/cnpg-erp.yaml
git add kubernetes/base/cloudnative-pg/cluster/cnpg-shared.yaml
git add kubernetes/base/cloudnative-pg/cluster/cnpg-erp.yaml

git commit -m "feat(cnpg): upgrade PostgreSQL 17.8-system to 17.9-standard

- Minor upgrade 17.8 → 17.9 (bugfixes + security)
- Image switch system → standard (system deprecated in CNPG)
- Barman Cloud Plugin sidecar handles backups independently"

git push
```

### Schritt 4: ArgoCD Sync abwarten

Auf k8s-mgmt-10:
```bash
cd ~/git/eneg-k8s-infrastructure-v2 && git pull
```

ArgoCD erkennt die Image-Aenderung und CNPG fuehrt automatisch einen
**Rolling Update** durch:
1. Replicas werden nacheinander neu gestartet (neues Image wird gepullt)
2. Primary wird als letztes neu gestartet
3. Cluster ist kurzzeitig degraded — das ist normal

### Schritt 5: Verifikation pro Umgebung

```bash
# Cluster healthy?
kubectl get cluster -n databases --context k8s-{env}

# Alle Pods 2/2 Running?
kubectl get pods -n databases -l cnpg.io/podRole --context k8s-{env}

# PostgreSQL-Version pruefen (sollte 17.9 zeigen)
kubectl exec -n databases cnpg-shared-1 --context k8s-{env} -c postgres -- psql -qAt -c 'SELECT version()'
kubectl exec -n databases cnpg-erp-1 --context k8s-{env} -c postgres -- psql -qAt -c 'SELECT version()'

# Image pruefen (sollte 17.9-standard-bookworm zeigen)
kubectl get cluster cnpg-shared -n databases --context k8s-{env} -o jsonpath='{.status.image}'
echo ""
kubectl get cluster cnpg-erp -n databases --context k8s-{env} -o jsonpath='{.status.image}'
echo ""

# WAL-Archivierung laeuft noch?
kubectl logs -n databases cnpg-shared-1 -c plugin-barman-cloud --tail=5 --context k8s-{env}

# ArgoCD Sync-Status
kubectl get app cnpg-cluster -n argocd --context k8s-{env} -o jsonpath='{.status.sync.status}'
```

---

## 5. Rollback

Falls Probleme auftreten, `imageName` auf den vorherigen Wert zuruecksetzen:
```yaml
  imageName: ghcr.io/cloudnative-pg/postgresql:17.8-system-bookworm
```
Commit, Push — CNPG macht erneut einen Rolling Update zurueck.

---

## 6. Hinweise

- **Kein Dump/Restore noetig:** Minor-Upgrades sind binaer-kompatibel. CNPG startet
  die Pods einfach mit dem neuen Image neu.
- **Rolling Update Dauer:** Ca. 2-3 Minuten pro Cluster (6 Pods insgesamt).
- **Primary-Pod-Name:** Der Primary-Pod-Name kann sich nach dem Restart aendern
  (CNPG nummeriert die Pods bei jedem Neustart). Nicht vom Pod-Namen abhaengig machen,
  sondern vom `PRIMARY`-Feld in `kubectl get cluster`.
- **Backup nach Upgrade:** Es empfiehlt sich, nach dem Upgrade ein manuelles Backup
  auszuloesen um eine saubere Baseline mit dem neuen Image zu haben:
  ```bash
  kubectl create -f - --context k8s-{env} <<EOF
  apiVersion: postgresql.cnpg.io/v1
  kind: Backup
  metadata:
    name: cnpg-shared-post-upgrade
    namespace: databases
  spec:
    cluster:
      name: cnpg-shared
    method: plugin
    pluginConfiguration:
      name: barman-cloud.cloudnative-pg.io
  EOF
  ```
- **base/-Dateien:** Die Dateien in `kubernetes/base/cloudnative-pg/cluster/` dienen
  als Referenz/Template. Diese sollten ebenfalls aktualisiert werden fuer Konsistenz.

---

## 7. Referenzen

- PostgreSQL 17.9 Release Notes: https://www.postgresql.org/docs/release/17.9/
- CloudNativePG postgres-containers: https://github.com/cloudnative-pg/postgres-containers
- CloudNativePG PostgreSQL Upgrades: https://cloudnative-pg.io/docs/1.26/postgres_upgrades/
- Image-Katalog (verfuegbare Tags): https://github.com/cloudnative-pg/postgres-containers/pkgs/container/postgresql
- Barman Cloud Plugin Migration (abgeschlossen): docs/guides/cnpg-barman-cloud-plugin-migration-v2.md

---

*Erstellt am 07.04.2026 nach Abschluss der Barman Cloud Plugin Migration.
Alle Umgebungen nutzen bereits das Plugin — der Image-Wechsel ist der naechste logische Schritt.*
