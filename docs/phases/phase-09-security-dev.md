# Phase 9: Security & Haertung (Kyverno, Trivy Operator, CrowdSec, Falco)

**Status:** In Arbeit
**Beginn:** 14.04.2026
**Voraussetzung:** Phase 7 (Monitoring), Phase 8 (TEST/PROD Rollout), Phase 10 (Backup) abgeschlossen

---

## 1. Zielsetzung

Implementierung eines mehrschichtigen Security-Stacks fuer alle drei Kubernetes-Umgebungen.
Die Komponenten ergaenzen sich in einem "Aussen-nach-Innen"-Modell:

### Sicherheitsschichten

```
Internet (geplant)
    |
    v
CrowdSec (Perimeter: WAF + IP-Reputation + Brute-Force-Schutz)
    |
    v
Kyverno (Policy Engine: Regeln, Standards, Image-Policies)
    |
    v
Trivy Operator (Schwachstellen-Scanner: CVEs, Fehlkonfigurationen)
    |
    v
Falco (Runtime Security: Syscall-Monitoring, Anomalie-Erkennung)
```

### Kernziele

- **Kyverno:** Pod Security Standards (Audit-Modus), Image-Policies, Resource-Quotas erzwingen
- **Trivy Operator:** Automatische Schwachstellen-Scans aller Container-Images, CRD-basierte Reports
- **CrowdSec:** WAF-Schutz (OWASP Top 10), Brute-Force-Erkennung, IP-Reputation als Traefik-Middleware
- **Falco:** Runtime-Erkennung verdaechtiger Aktivitaeten (Shell in Container, Dateimanipulationen, Netzwerk-Anomalien)

### Hintergrund: Geplante Internet-Freischaltung

Einzelne Apps sollen zukuenftig aus dem Internet erreichbar sein. Die Security-Schichten
muessen **vor** der Internet-Freischaltung implementiert und getunt sein. Besonders CrowdSec
als Perimeter-Schutz ist dafuer kritisch.

---

## 2. Komponenten und Versionen

| Komponente | Helm Chart / Image | Version | Quelle |
|------------|-------------------|---------|--------|
| Kyverno | kyverno/kyverno | **Helm 3.7.1** (App v1.17.1) | kyverno Helm Repo |
| Kyverno Policies | kyverno/kyverno-policies | **Helm 3.7.1** | kyverno Helm Repo |
| Trivy Operator | aqua/trivy-operator | **Helm 0.32.1** (App v0.30.1) | aqua Helm Repo |
| CrowdSec Security Engine | crowdsec/crowdsec | **Helm (latest stable)** | crowdsec Helm Repo |
| CrowdSec Traefik Bouncer | Plugin: crowdsec-bouncer-traefik-plugin | **v1.3.3** | Traefik Plugin Catalog |
| Falco | falcosecurity/falco | **Helm 8.0.1** (App v0.42.x) | falcosecurity Helm Repo |

**Versionen abgestimmt am 14.04.2026.**
Falco 0.43 ist noch RC — wir nutzen die stabile 0.42.x Linie.

---

## 3. Implementierungsreihenfolge

Die Reihenfolge baut das Sicherheitsmodell von innen nach aussen auf, damit bei
spaeterer Internet-Freischaltung alle Schichten bereits stehen.

### Schritt 1: Kyverno (Policy Engine)

**Warum zuerst:** Im Audit-Modus komplett ungefaehrlich. Gibt sofort Ueberblick
ueber Policy-Verstoesse im Cluster. Bildet die Grundlage fuer alle weiteren
Security-Entscheidungen.

**Umfang:**
- Kyverno Admission Controller (3 Controller: Admission, Background, Reports)
- Pod Security Standards im Audit-Modus (Baseline + Restricted)
- Image-Pull-Policies (immer bestimmte Tags, keine `latest`)
- Resource-Quotas (Limits/Requests muessen gesetzt sein)
- Namespace: `kyverno`

**Risiko:** Minimal (Audit-Modus meldet nur, blockiert nichts)

### Schritt 2: Trivy Operator (Vulnerability Scanner)

**Warum zweiter:** Scannt passiv alle Container-Images auf CVEs. Erzeugt
Kubernetes CRDs (VulnerabilityReports) — kein Risiko fuer laufende Workloads.
Zeigt sofort, ob eingesetzte Images bekannte Schwachstellen haben.

**Umfang:**
- Trivy Operator Deployment (scannt automatisch bei Pod-Erstellung)
- VulnerabilityReports, ConfigAuditReports, ExposedSecretReports
- Prometheus ServiceMonitor fuer Metriken in Grafana
- Namespace: `trivy-system`

**Risiko:** Minimal (rein passiver Scanner, erzeugt nur CRD-Reports)

### Schritt 3: CrowdSec (Perimeter-Schutz / WAF)

**Warum dritter:** Schuetzt den Perimeter (Traefik als Eintrittspunkt). Erste
Verteidigungslinie bei Internet-Freischaltung. Weniger komplex als Falco
(kein eBPF), laesst sich als Traefik-Plugin sauber integrieren.

**Umfang:**
- CrowdSec Security Engine (LAPI + Agent als DaemonSet)
- Traefik Bouncer Plugin (Middleware fuer alle Ingress-Routen)
- AppSec/WAF-Modul (OWASP Top 10 Schutz)
- Traefik Access-Log Parsing (Brute-Force-Erkennung)
- Community Blocklists (globale IP-Reputation)
- Namespace: `crowdsec`

**Risiko:** Mittel (Traefik-Plugin muss sauber integriert werden,
False Positives bei WAF-Regeln moeglich → erst im Log-Modus starten)

### Schritt 4: Falco (Runtime Security)

**Warum letzter:** Am komplexesten — nutzt eBPF/modern_ebpf auf K3s-Nodes
fuer Syscall-Monitoring. Hoechstes Risiko fuer Seiteneffekte. Braucht
Feintuning der Regeln. Am wertvollsten, wenn die anderen drei Schichten stehen.

**Umfang:**
- Falco DaemonSet (1 Pod pro Node, privilegiert fuer eBPF)
- modern_ebpf Driver (kein Kernel-Modul noetig, CO-RE)
- Offizielle Falco Rules (automatische Updates via falcoctl)
- Alerting ueber Prometheus/AlertManager (bestehende Infrastruktur)
- Namespace: `falco`

**Risiko:** Hoeher (privilegierter DaemonSet, eBPF-Probes auf Nodes,
K3s-Kernel-Kompatibilitaet pruefen, False Positives bei Standard-Regeln)

---

## 4. Architektur-Uebersicht

```
+------------------------------------------------------------------+
|                    K3s Cluster (pro Umgebung)                      |
|                                                                    |
|  Internet (geplant)                                                |
|       |                                                            |
|       v                                                            |
|  +----------------------------------------------------------+     |
|  | Traefik (Ingress Controller)                              |     |
|  |   + CrowdSec Bouncer Plugin (WAF + IP-Ban)               |     |
|  +----------------------------------------------------------+     |
|       |                                                            |
|       v                                                            |
|  +----------------------------------------------------------+     |
|  | CrowdSec Security Engine                                  |     |
|  | LAPI (Deployment) + Agent (DaemonSet)                     |     |
|  | Traefik-Log-Parsing + AppSec (WAF)                        |     |
|  | Community Blocklists + lokale Entscheidungen              |     |
|  +----------------------------------------------------------+     |
|                                                                    |
|  +----------------------------------------------------------+     |
|  | Kyverno (Admission Controller)                            |     |
|  | Pod Security Standards (Audit → Enforce)                  |     |
|  | Image Policies, Resource Quotas                           |     |
|  +----------------------------------------------------------+     |
|                                                                    |
|  +----------------------------------------------------------+     |
|  | Trivy Operator (Vulnerability Scanner)                    |     |
|  | Automatische Scans bei Pod-Erstellung                     |     |
|  | VulnerabilityReports, ConfigAuditReports (CRDs)           |     |
|  +----------------------------------------------------------+     |
|                                                                    |
|  +----------------------------------------------------------+     |
|  | Falco (Runtime Security, DaemonSet)                       |     |
|  | eBPF Syscall-Monitoring auf jedem Node                    |     |
|  | Anomalie-Erkennung (Shell, Datei, Netzwerk)               |     |
|  +----------------------------------------------------------+     |
+------------------------------------------------------------------+
```

---

## 5. Neue Namespaces

| Namespace | Komponente | Pods (DEV) |
|-----------|------------|------------|
| `kyverno` | Kyverno Admission, Background, Reports Controller | 3 |
| `trivy-system` | Trivy Operator | 1 |
| `crowdsec` | CrowdSec LAPI + Agent DaemonSet | 1 + 3 |
| `falco` | Falco DaemonSet | 3 |

**Gesamt: ~11 neue Pods pro Umgebung**

---

## 6. Repository-Struktur (Ziel-Zustand)

```
kubernetes/
├── base/
│   ├── kyverno/
│   │   └── values.yaml                    # Helm Base-Values
│   ├── kyverno-policies/
│   │   └── values.yaml                    # Pod Security Standards
│   ├── trivy-operator/
│   │   └── values.yaml                    # Helm Base-Values
│   ├── crowdsec/
│   │   └── values.yaml                    # Helm Base-Values
│   └── falco/
│       └── values.yaml                    # Helm Base-Values
│
└── environments/dev/
    ├── kyverno/
    │   └── values-override.yaml           # DEV: Audit-Modus, Exclusions
    ├── trivy-operator/
    │   └── values-override.yaml           # DEV: Scan-Intervall, ServiceMonitor
    ├── crowdsec/
    │   └── values-override.yaml           # DEV: Traefik-Log-Pfad, Collections
    ├── crowdsec-secrets/
    │   ├── crowdsec-credentials.yaml.template
    │   ├── crowdsec-credentials.enc.yaml  # SOPS-verschluesselt
    │   ├── kustomization.yaml
    │   └── secret-generator.yaml
    ├── falco/
    │   └── values-override.yaml           # DEV: eBPF-Config, Custom Rules
    └── infrastructure/
        ├── kyverno-app.yaml               # ArgoCD App (Helm Multi-Source)
        ├── kyverno-policies-app.yaml      # ArgoCD App (Helm Multi-Source)
        ├── trivy-operator-app.yaml        # ArgoCD App (Helm Multi-Source)
        ├── crowdsec-app.yaml              # ArgoCD App (Helm Multi-Source)
        ├── crowdsec-secrets-app.yaml       # ArgoCD App (KSOPS)
        └── falco-app.yaml                 # ArgoCD App (Helm Multi-Source)
```

---

## 7. ArgoCD Apps (Neue Apps pro Environment)

| Nr | App-Name | Typ | Namespace | Pfad |
|----|----------|-----|-----------|------|
| 1 | kyverno | Helm (Multi-Source) | kyverno | base/kyverno/ + environments/{env}/kyverno/ |
| 2 | kyverno-policies | Helm (Multi-Source) | kyverno | base/kyverno-policies/ + environments/{env}/kyverno/ |
| 3 | trivy-operator | Helm (Multi-Source) | trivy-system | base/trivy-operator/ + environments/{env}/trivy-operator/ |
| 4 | crowdsec | Helm (Multi-Source) | crowdsec | base/crowdsec/ + environments/{env}/crowdsec/ |
| 5 | crowdsec-secrets | Kustomize (KSOPS) | crowdsec | environments/{env}/crowdsec-secrets/ |
| 6 | falco | Helm (Multi-Source) | falco | base/falco/ + environments/{env}/falco/ |

**Gesamt: 6 neue ArgoCD Apps pro Environment**

---

## 8. Abhaengigkeiten und Voraussetzungen

| Voraussetzung | Status | Verantwortlich |
|---------------|--------|----------------|
| Phase 7 Monitoring abgeschlossen | ✅ | - |
| Phase 8 TEST/PROD Rollout abgeschlossen | ✅ | - |
| Phase 10 Backup abgeschlossen | ✅ | - |
| Helm Repos auf k8s-mgmt-10 | Offen | Daniel (CLI) |
| CrowdSec Account (Community Console) | Offen | Daniel |
| Versionsabstimmung | ✅ (14.04.2026) | - |

---

## 9. Risiken und Mitigationen

| Risiko | Mitigation |
|--------|------------|
| Kyverno Webhook blockiert Deployments | Audit-Modus zuerst, System-Namespaces ausschliessen |
| Kyverno CRDs gross (aehnlich ArgoCD) | ServerSideApply in ArgoCD App |
| Trivy DB-Download bei eingeschraenktem Egress | Built-in Trivy Server im Cluster (lokaler Cache) |
| CrowdSec Traefik-Plugin Kompatibilitaet | Gruendlich in DEV testen, erst Log-Modus |
| CrowdSec WAF False Positives | AppSec erst im Detection-Modus, Regeln iterativ tunen |
| Falco eBPF auf K3s-Kernel | modern_ebpf (CO-RE) pruefen, Kernel >= 5.8 noetig |
| Falco False Positives bei Standard-Regeln | Regeln schrittweise aktivieren, Exceptions fuer bekannte Patterns |
| Falco privilegierter DaemonSet | Resource Limits setzen, Monitoring-Alert bei OOM |
| Ressourcen-Overhead durch 4 neue Tools | Monitoring der Node-Auslastung, ggf. Anpassung der Ressourcen |

---

## 10. Geschaetzter Aufwand

| Schritt | Beschreibung | Geschaetzter Aufwand |
|---------|--------------|----------------------|
| 1 | Kyverno + Policies (DEV) | 2-3h |
| 2 | Trivy Operator (DEV) | 1-2h |
| 3 | CrowdSec + Traefik-Integration (DEV) | 3-5h |
| 4 | Falco (DEV) | 2-4h |
| 5 | Dokumentation + Learnings | 1h |
| **DEV Gesamt** | | **~10-15h** |
| 6 | TEST Rollout | 2-3h |
| 7 | PROD Rollout | 2-3h |
| **Gesamtprojekt** | | **~14-21h** |

---

## 11. Offene Entscheidungen

- [x] Toolauswahl: Kyverno, Trivy Operator, CrowdSec, Falco
- [x] Reihenfolge: Kyverno → Trivy → CrowdSec → Falco
- [x] Kyverno-Version: v1.17.1 (Helm 3.7.1)
- [x] Trivy-Operator-Version: v0.30.1 (Helm 0.32.1)
- [x] CrowdSec Traefik Plugin: v1.3.3
- [x] Falco-Version: v0.42.x (Helm 8.0.1)
- [ ] Kyverno: Welche Policies im Audit-Modus starten? (Baseline vs. Restricted)
- [ ] CrowdSec: Community Console Account anlegen (Enrollment Key)
- [ ] CrowdSec: SQLite oder externe DB (MariaDB/PostgreSQL) fuer LAPI?
- [ ] CrowdSec: Welche Collections/Szenarien aktivieren?
- [ ] Falco: modern_ebpf Kompatibilitaet mit K3s Ubuntu 24.04 Kernel pruefen
- [ ] Falco: Welche Custom Rules / Exceptions fuer bekannte Workloads?
- [ ] Grafana: Dashboards fuer Kyverno, Trivy, Falco erstellen?

---

## 12. Learnings (DEV)

1. **Kyverno `config.webhooks` Helm-Format:** Das Kyverno Helm Chart erwartet unter
   `config.webhooks` eine Liste von Webhook-Objekten mit `namespaceSelector` — nicht
   einfache `failurePolicy`-Eintraege. Die `failurePolicy` fuer den Admission-Webhook
   muss unter `admissionController.webhookConfiguration.failurePolicy` gesetzt werden.
   Falsches Format fuehrt zu `helm template` Fehler:
   `cannot overwrite table with non table for kyverno.config.webhooks`.

2. **Kyverno ClusterPolicy ArgoCD OutOfSync:** Kyvernos Admission Controller fuegt
   Default-Werte in ClusterPolicies ein (`spec.admission`, `spec.emitWarning`,
   `spec.failurePolicy` auf Top-Level; `skipBackgroundRequests` und
   `allowExistingViolations` in Rules). Diese Felder existieren nicht im Helm-Template
   und erzeugen permanentes OutOfSync. Fix: `resource.customizations.ignoreDifferences`
   in `argocd-cm` fuer `kyverno.io_ClusterPolicy` mit `managedFieldsManagers: [kyverno]`
   + `jsonPointers` + `jqPathExpressions`.

3. **Kyverno CRD leere Metadata-Maps:** Helm generiert `metadata.annotations: {}` und
   `metadata.labels: {}` als leere Maps in den `policies.kyverno.io` CRDs. Kubernetes
   normalisiert diese leeren Maps weg (Feld existiert nicht). ArgoCD sieht den Diff
   zwischen "leeres Objekt" vs "Feld nicht vorhanden". Fix: `ignoreDifferences` fuer
   `apiextensions.k8s.io_CustomResourceDefinition` mit
   `jqPathExpressions: [.metadata.annotations, .metadata.labels]` in `argocd-cm`.
   Dieser Fix ist global und betrifft alle CRDs — fuer TEST/PROD bereits vorbereitet.

4. **ArgoCD Application `ignoreDifferences` Schema:** Das Application CRD erwartet
   `jqPathExpressions` (Plural, Array), nicht `jqPathExpression` (Singular). Die
   `argocd-cm` ConfigMap verwendet dagegen die Singular-Form als YAML-Key-Suffix.
   App-level ignoreDifferences sind redundant wenn der globale Fix in argocd-cm greift
   → entfernt zugunsten der globalen Loesung.

5. **Trivy Operator OOMKilled bei 256Mi:** Der Operator watcht alle Workloads in allen
   Namespaces gleichzeitig. 256Mi Memory-Limit reicht nicht fuer einen Cluster mit
   ~50 Apps. Fix: Memory-Limit auf 512Mi erhoeht (Requests 256Mi).

6. **Trivy Operator `builtInTrivyServer`:** Statt manuell `trivy.mode: ClientServer`
   und `trivy.serverURL` zu setzen, genuegt `trivy.builtInTrivyServer: true`. Das
   Chart setzt automatisch mode=ClientServer und die korrekte interne Service-URL.

---

## 13. DEV Implementierung — Ergebnisse

### Schritt 1: Kyverno (14.04.2026) ✅

| Komponente | Version | Pods | Status |
|------------|---------|------|--------|
| Admission Controller | v1.17.1 (Chart 3.7.1) | 1 | ✅ Running |
| Background Controller | v1.17.1 | 1 | ✅ Running |
| Cleanup Controller | v1.17.1 | 1 | ✅ Running |
| Reports Controller | v1.17.1 | 1 | ✅ Running |

**ArgoCD Apps:** kyverno (Synced+Healthy), kyverno-policies (Synced+Healthy)
**ClusterPolicies:** 11 Baseline PSS Policies, alle Ready, Audit-Modus
**ArgoCD OutOfSync Fix:** Global in argocd-cm (ClusterPolicy + CRD ignoreDifferences)

### Schritt 2: Trivy Operator (14.04.2026) ✅

| Komponente | Version | Pods | Status |
|------------|---------|------|--------|
| Trivy Operator | v0.30.1 (Chart 0.32.1) | 1 | ✅ Running |
| Built-in Trivy Server | (im Operator integriert) | - | ✅ Aktiv |
| Scan-Jobs | (dynamisch, 2 parallel) | 0-2 | ✅ Laufen |

**ArgoCD App:** trivy-operator (Synced+Healthy)
**VulnerabilityReports:** Automatisch fuer alle Workloads, erste Ergebnisse nach ~2min
**Erste Findings:** Velero 6 Critical, PostgreSQL 2 Critical, Longhorn 2 Critical

### Schritt 3: CrowdSec — Ausstehend
### Schritt 4: Falco — Ausstehend

---

*Erstellt: 14.04.2026*
*Letzte Aktualisierung: 14.04.2026 (Kyverno + Trivy Operator DEV deployed, CrowdSec + Falco ausstehend)*
