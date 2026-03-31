# ADR-002: Branch-per-Environment Promotion-Strategie

**Status:** Akzeptiert
**Datum:** 31.03.2026
**Entscheider:** Daniel Henke
**Ersetzt:** Teile von ADR-001 (Single-Branch-Strategie)

---

## Kontext

Das Projekt nutzt ein Monorepo (`eneg-k8s-infrastructure-v2`) mit drei Umgebungen
(DEV, TEST, PROD). Bisher werden alle Aenderungen auf einem einzigen Branch (`main`)
verwaltet (ADR-001). ArgoCD in allen drei Clustern tracked `main`.

### Problem

Bei Single-Branch propagieren Aenderungen an gemeinsamen Dateien (`base/`, `ansible/`,
`terraform/`, `packer/`) sofort in alle drei Umgebungen. Das ist inakzeptabel fuer:
- Kubernetes-Upgrades (K3s-Versionen)
- ArgoCD-Upgrades
- CNPG/MariaDB Operator-Updates
- Ansible-Playbook-Aenderungen
- Packer-Template-Updates
- Strukturelle Aenderungen an base/-Manifesten (Probes, SecurityContexts, neue Container)

Jede Aenderung — egal ob App-Update, Infrastruktur-Upgrade oder Konfigurationsanpassung —
muss den kontrollierten Weg DEV → TEST → PROD durchlaufen.

### Bewertete Alternativen

| Ansatz | Isolation | Infra-Upgrades | Audit-Trail | GitOps-konform | Merge-Konflikte |
|--------|-----------|----------------|-------------|----------------|-----------------|
| Single Branch + Kustomize Base | Nur Image-Tags | Keine Kontrolle | Kein Gate | Ja | Keine |
| Single Branch + Promotion-Script | Nur Apps | Keine Kontrolle | Commit-Messages | Ja | Keine |
| Single Branch + Manual Sync | Moeglich | Moeglich | Kein Trail | Nein (Drift) | Keine |
| **Branch-per-Environment** | **Vollstaendig** | **PR-Gate** | **PR-History** | **Ja** | **Selten** |

---

## Entscheidung

**Wir migrieren auf Branch-per-Environment mit Pull-Request-basierter Promotion.**

### Branch-Struktur

```
Branch: main        → ArgoCD DEV tracked main
Branch: test        → ArgoCD TEST tracked test
Branch: prod        → ArgoCD PROD tracked prod
```

### Promotion-Workflow

```
Entwicklung/Aenderung
       |
       v
   [main Branch]  ──push──>  ArgoCD DEV (Auto-Sync)
       |                          |
       |                     Test in DEV
       |                          |
       v                          v
   PR: main → test  ──merge──>  ArgoCD TEST (Auto-Sync)
       |                          |
       |                     Test in TEST
       |                          |
       v                          v
   PR: test → prod  ──merge──>  ArgoCD PROD (Auto-Sync)
```

### Regeln

1. **Alle Aenderungen starten auf `main`** (DEV-Branch). Kein direkter Push auf `test` oder `prod`.
2. **PRs sind Pflicht** fuer Promotion test→prod. Fuer main→test sind PRs empfohlen.
3. **PR-Diff pruefen** vor jedem Merge. Der Diff zeigt exakt was sich aendert.
4. **Regelmaessige Merges** (mindestens woechentlich) verhindern Branch-Drift.
5. **Image-Tags sind fest** (getaggte Versionen, kein `latest`). Tags stehen in den
   Deployment-Manifesten in `environments/{env}/apps/{app}/`.
6. **Secrets werden nie gemergt** — jede Umgebung hat eigene Secrets in
   `environments/{env}/`. SOPS-verschluesselte Dateien in env-spezifischen Pfaden
   aendern sich selten und verursachen dadurch kaum Merge-Konflikte.
7. **Ressourcen (CPU/RAM) sind pro Umgebung individuell** — kleiner in DEV,
   mittel in TEST, produktionsgerecht in PROD.

### ArgoCD-Konfiguration

Jeder ArgoCD-Cluster tracked seinen eigenen Branch:

```yaml
# DEV Bootstrap (kubernetes/bootstrap/argocd-app.yaml)
spec:
  source:
    targetRevision: main

# TEST Bootstrap (kubernetes/bootstrap/test-argocd-app.yaml)
spec:
  source:
    targetRevision: test

# PROD Bootstrap (kubernetes/bootstrap/prod-argocd-app.yaml)
spec:
  source:
    targetRevision: prod
```

Alle ArgoCD-Instanzen behalten `automated: prune: true, selfHeal: true`.

### Workflow-Beispiele

**Beispiel 1: App-Version-Upgrade (n8n 2.8.4 → 2.9.0)**
1. Auf `main`: Image-Tag in `environments/dev/apps/n8n/deployment.yaml` aendern
2. `git push` → ArgoCD DEV synct → Test in DEV
3. PR `main → test` erstellen → Diff zeigt nur den Tag-Change in dev/ UND test/ muss
   manuell im PR angepasst werden (Tag in test/apps/n8n/deployment.yaml aendern)
4. Merge → ArgoCD TEST synct → Test in TEST
5. PR `test → prod` → Tag in prod/apps/n8n/deployment.yaml aendern
6. Merge → ArgoCD PROD synct

**Beispiel 2: Infrastruktur-Upgrade (K3s, ArgoCD, CNPG)**
1. Auf `main`: Ansible-Playbooks, Helm-Versionen, base/-Manifeste anpassen
2. Ausfuehren auf DEV-Cluster → Test
3. PR `main → test` → Diff zeigt ALLE Infra-Aenderungen
4. Review → Merge → Ausfuehren auf TEST-Cluster → Test
5. PR `test → prod` → Review → Merge → Ausfuehren auf PROD-Cluster

**Beispiel 3: Neue App hinzufuegen**
1. Auf `main`: base/apps/neue-app/ + environments/dev/apps/neue-app/ + ArgoCD-App-Definition
2. Test in DEV
3. PR `main → test`: Bringt base/ und dev/ mit — TEST-Overlay muss im PR ergaenzt werden
   (environments/test/apps/neue-app/ mit test-spezifischen Werten)
4. Merge → Test in TEST
5. PR `test → prod`: PROD-Overlay im PR ergaenzen
6. Merge → PROD live

### SOPS/Secrets-Handling

- Secrets liegen in umgebungsspezifischen Pfaden (`environments/{env}/*/secrets/`)
- Jede Umgebung hat eigene Passwoerter (nie aus anderer Umgebung kopieren)
- SOPS `.enc.yaml`-Dateien sind binaer — Git kann Merge-Konflikte nicht automatisch loesen
- Da Secrets pro Umgebung in separaten Pfaden liegen, entstehen Merge-Konflikte nur
  wenn die gleiche Secret-Datei auf zwei Branches gleichzeitig geaendert wird
- In der Praxis aendern sich Secrets selten → geringes Risiko

---

## Konsequenzen

### Positiv
- **Volle Isolation:** Keine ungetestete Aenderung erreicht TEST oder PROD
- **Audit-Trail:** PR-History zeigt wann was promotet wurde
- **Sichtbarer Diff:** Jeder PR zeigt exakt welche Aenderungen mitkommen
- **GitOps-konform:** Git-State = Cluster-State auf jedem Branch
- **Kein eigenes Tooling:** GitHub-Bordmittel (PRs, Diffs, Merge) reichen
- **Infra-Upgrades kontrolliert:** K3s, ArgoCD, CNPG-Upgrades durchlaufen DEV→TEST→PROD

### Negativ
- **Merge-Aufwand:** PRs muessen erstellt und gemergt werden (ca. 5 Minuten pro Promotion)
- **Branch-Drift:** Bei seltenen Merges kann der Diff gross werden (Mitigation: woechentliche Merges)
- **SOPS-Konflikte:** Theoretisch moeglich bei gleichzeitiger Secret-Aenderung auf zwei Branches
  (Mitigation: Secrets aendern sich selten, unterschiedliche Pfade pro Umgebung)
- **Redundante Dateien:** `environments/dev/`-Dateien existieren auch auf test/prod-Branches
  (harmlos — ArgoCD TEST/PROD ignoriert dev/-Pfade)

### Migrationsaufwand
- Branches `test` und `prod` von `main` erstellen
- ArgoCD Bootstrap-Manifeste anpassen (`targetRevision` pro Umgebung)
- ArgoCD Bootstrap-Manifeste auf TEST/PROD-Cluster neu anwenden
- Alle ArgoCD App-Definitionen pruefen (targetRevision: main → Umgebungs-Branch)

---

## Referenzen

- ADR-001: Kustomize Overlay Pattern (bleibt gueltig fuer Verzeichnisstruktur)
- ArgoCD Multi-Environment Best Practices: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- GitHub PR-basierter GitOps-Workflow: https://www.gitops.tech/

---

*Erstellt: 31.03.2026 | Akzeptiert: 31.03.2026*
