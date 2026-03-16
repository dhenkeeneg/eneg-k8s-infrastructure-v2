# ADR-001: Kustomize-Overlay Pattern fuer Multi-Environment

**Status:** Akzeptiert  
**Datum:** 16.03.2026  
**Entscheider:** Daniel Henke

---

## Kontext

Das Projekt nutzt drei Kubernetes-Umgebungen (DEV, TEST, PROD) auf separaten
K3s-Clustern. Bis Phase 6 waren alle Kubernetes-Manifeste in `kubernetes/base/`
mit DEV-spezifischen Werten (IPs, Hostnames, MetalLB-Pool-Namen) hartcodiert.
Fuer den Aufbau der TEST-Umgebung (Phase 8) musste eine Multi-Environment-faehige
Struktur geschaffen werden.

## Entscheidung

Infrastruktur-Manifeste (Phase 2-4 Komponenten) werden auf ein Kustomize-Overlay
Pattern umgestellt:

- `kubernetes/base/` enthaelt nur generische, umgebungsunabhaengige Konfiguration
- `kubernetes/environments/{dev,test,prod}/` enthaelt Environment-Overlays mit
  umgebungsspezifischen Werten (IPs, Hostnames, Pool-Namen, Certificates)
- ArgoCD App-Definitionen verweisen auf Overlay-Pfade statt direkt auf base

## Betrachtete Alternativen

### Option A: Copy-Paste (separates base-test Verzeichnis)

- Kompletter Satz Manifeste pro Umgebung kopieren und anpassen
- Vorteil: Null Risiko fuer DEV, sofort umsetzbar
- Nachteil: Doppelte Pflege, Drift-Gefahr bei Updates
- **Abgelehnt:** Nicht wartbar bei >3 Umgebungen

### Option B: Kustomize-Overlays (gewaehlt)

- Base generisch, Overlays pro Umgebung
- Vorteil: DRY-Prinzip, einfache Promotion DEV->TEST->PROD
- Nachteil: Initialer Refactoring-Aufwand, Risiko bei Umstellung
- **Gewaehlt:** Risiko durch schrittweise Umstellung minimiert

## Umsetzung

### Refactored (Phase 2-4 Infrastruktur):

| Komponente | Base-Inhalt | Overlay-Inhalt | ArgoCD-Pattern |
|------------|-------------|----------------|----------------|
| MetalLB | Installation (v0.15.3) | IPAddressPool, L2Advertisement | Kustomize |
| Traefik | Generische Helm Values | values-override, Certificate | Multi-Source Helm (base + override) |
| Longhorn | Helm Values, StorageClass | Dashboard Ingress | Directory include |
| ArgoCD | KSOPS-Config, Cmd-Params | URL (JSON-Patch), Ingress | Kustomize mit Patch |
| Cert-Manager | Alles (bereits generisch) | _(kein Overlay)_ | Direkt auf base |

### Noch nicht refactored (spaeter bei App-Promotion):

- `kubernetes/base/apps/` — Alle Pilot-Apps (n8n, Odoo, OpenProject, Keycloak, i-doit)
- `kubernetes/base/cloudnative-pg/` — CNPG Cluster-Definitionen, Backup-CronJobs
- `kubernetes/base/mariadb-galera/` — MariaDB Cluster, Backup-CronJobs
- `kubernetes/base/garage/` — Garage S3 Cluster, Backup-CronJobs

Diese werden erst refactored, wenn die jeweiligen Apps nach TEST promoted werden.

## Risikobewertung

**Risiko:** Gering. Die Umstellung wurde komponentenweise durchgefuehrt
(MetalLB -> Traefik -> Longhorn -> ArgoCD). Nach jeder Komponente wurde
per ArgoCD-Refresh und Dashboard-Zugriff verifiziert, dass die resultierende
Konfiguration identisch ist.

**Verifizierung (16.03.2026):**
- Alle ArgoCD Apps: Synced + Healthy nach Refactoring
- Keine Pod-Restarts bei MetalLB, Traefik, Longhorn, ArgoCD
- Dashboards erreichbar: ArgoCD, Traefik, Longhorn

## Konsequenzen

### Positiv
- TEST- und PROD-Cluster koennen dieselben base-Manifeste nutzen
- Aenderungen an base propagieren automatisch in alle Umgebungen
- Promotion-Pipeline (DEV->TEST->PROD) wird durch Overlay-Anpassung moeglich

### Negativ
- Etwas hoehere Komplexitaet beim Verstaendnis der Verzeichnisstruktur
- Neue Komponenten muessen in base generisch angelegt werden
- Helm-basierte Apps (Traefik, Longhorn) brauchen Multi-Source in ArgoCD
