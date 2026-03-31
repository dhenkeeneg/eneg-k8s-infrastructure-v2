# Phase 8e: Branch-per-Environment Migration — Handoff

**Erstellt:** 31.03.2026
**Status:** Vorbereitet, Umsetzung ausstehend
**ADR:** `docs/decisions/ADR-002-branch-per-environment.md`

---

## Ziel

Migration von Single-Branch (`main`) auf Branch-per-Environment (`main`, `test`, `prod`)
mit PR-basierter Promotion. Nach der Migration tracked jeder ArgoCD-Cluster seinen
eigenen Branch.

## Ausgangslage

- Repository: `dhenkeeneg/eneg-k8s-infrastructure-v2` auf GitHub
- Aktuell: Einziger Branch `main`, alle 3 ArgoCD-Instanzen tracken `main`
- Alle 3 Umgebungen sind strukturell identisch (39 Apps, 18 Overlay-Verzeichnisse)
- ArgoCD Auto-Sync ist auf allen 3 Clustern aktiv
- Alle Apps sind Synced + Healthy auf allen 3 Clustern

## Voraussetzungen vor dem Start

- [ ] ADR-002 committed und gepusht auf `main`
- [ ] Alle 3 ArgoCD-Instanzen zeigen Synced + Healthy
- [ ] Kein laufendes Deployment oder Upgrade auf irgendeinem Cluster
- [ ] Aktueller `main`-Branch ist der gewuenschte Zustand fuer alle 3 Umgebungen

## Migrationsplan

### Schritt 1: Branches auf GitHub erstellen

```bash
cd ~/git/eneg-k8s-infrastructure-v2
git checkout main
git pull

# test-Branch von main erstellen
git branch test
git push origin test

# prod-Branch von main erstellen
git branch prod
git push origin prod
```

**Ergebnis:** Drei identische Branches auf GitHub. Noch keine Auswirkung auf ArgoCD.

### Schritt 2: ArgoCD targetRevision anpassen

Alle ArgoCD-Manifeste die `targetRevision: main` enthalten muessen fuer TEST und PROD
auf den jeweiligen Branch geaendert werden.

**Betroffene Dateien auf dem `test`-Branch:**
- `kubernetes/bootstrap/test-argocd-app.yaml` → targetRevision: test
- `kubernetes/bootstrap/test-infrastructure-app.yaml` → targetRevision: test
- Alle 39 Dateien in `kubernetes/environments/test/infrastructure/*.yaml` → targetRevision: test
  (Betrifft sowohl `source.targetRevision` als auch `ref: values` Sources)

**Betroffene Dateien auf dem `prod`-Branch:**
- `kubernetes/bootstrap/prod-argocd-app.yaml` → targetRevision: prod
- `kubernetes/bootstrap/prod-infrastructure-app.yaml` → targetRevision: prod
- Alle 39 Dateien in `kubernetes/environments/prod/infrastructure/*.yaml` → targetRevision: prod

**DEV (`main`-Branch):** Keine Aenderung noetig — bleibt auf `targetRevision: main`.

**Vorgehen:**
1. Auf `test`-Branch wechseln, targetRevision aendern, committen, pushen
2. Auf `prod`-Branch wechseln, targetRevision aendern, committen, pushen
3. ACHTUNG: Diese Aenderungen duerfen NICHT zurueck nach `main` gemergt werden!

### Schritt 3: ArgoCD Bootstrap auf TEST/PROD neu anwenden

Die Bootstrap-Dateien werden nicht von ArgoCD selbst gemanagt — sie muessen
manuell auf den jeweiligen Clustern angewendet werden.

```bash
# Auf k8s-mgmt-10:
cd ~/git/eneg-k8s-infrastructure-v2

# TEST-Branch auschecken und Bootstrap anwenden
git checkout test
git pull
kubectl --context k8s-test apply -f kubernetes/bootstrap/test-argocd-app.yaml
kubectl --context k8s-test apply -f kubernetes/bootstrap/test-infrastructure-app.yaml

# PROD-Branch auschecken und Bootstrap anwenden
git checkout prod
git pull
kubectl --context k8s-prod apply -f kubernetes/bootstrap/prod-argocd-app.yaml
kubectl --context k8s-prod apply -f kubernetes/bootstrap/prod-infrastructure-app.yaml

# Zurueck auf main fuer normale Arbeit
git checkout main
```

### Schritt 4: Verifizierung

```bash
# DEV: Tracked main?
kubectl --context k8s-dev get app dev-infrastructure -n argocd \
  -o jsonpath='{.spec.source.targetRevision}' && echo
# Erwartung: main

# TEST: Tracked test?
kubectl --context k8s-test get app test-infrastructure -n argocd \
  -o jsonpath='{.spec.source.targetRevision}' && echo
# Erwartung: test

# PROD: Tracked prod?
kubectl --context k8s-prod get app prod-infrastructure -n argocd \
  -o jsonpath='{.spec.source.targetRevision}' && echo
# Erwartung: prod

# Alle Apps auf allen Clustern Synced + Healthy?
for ctx in k8s-dev k8s-test k8s-prod; do
  echo "=== $ctx ==="
  kubectl --context $ctx get app -n argocd | grep -v Synced
done
# Erwartung: Keine Ausgabe (alles Synced)
```

### Schritt 5: Erster Promotion-Test

Kleine, ungefaehrliche Aenderung zum Testen des PR-Workflows:

1. Auf `main`: Einen Kommentar in einer beliebigen Datei aendern (z.B. in
   `environments/dev/apps/n8n/deployment.yaml`)
2. Committen + pushen auf `main`
3. Pruefen: ArgoCD DEV synct? → Ja
4. Pruefen: ArgoCD TEST aendert sich NICHT? → Korrekt (tracked test-Branch)
5. PR `main → test` auf GitHub erstellen
6. Diff pruefen
7. Merge
8. Pruefen: ArgoCD TEST synct jetzt? → Ja
9. PR `test → prod` erstellen → Merge → PROD synct

### Schritt 6: GitHub Branch Protection (Optional, empfohlen)

Auf GitHub unter Settings → Branches → Branch protection rules:

- **prod-Branch:** Require pull request before merging (verhindert direkten Push)
- **test-Branch:** Optional — PR empfohlen aber nicht erzwungen
- **main-Branch:** Kein Schutz (direkter Push fuer schnelle DEV-Iterationen)

## Arbeitsablauf nach der Migration

### Alltaegliche Arbeit
```
1. git checkout main
2. Aenderungen machen (App-Updates, Config-Aenderungen, Infra-Upgrades)
3. git commit && git push  →  ArgoCD DEV synct automatisch
4. In DEV testen
5. Wenn OK: PR main → test auf GitHub  →  Review Diff  →  Merge
6. In TEST testen
7. Wenn OK: PR test → prod auf GitHub  →  Review Diff  →  Merge
```

### Lokales Git-Setup fuer Branch-Wechsel

Fuer die taegliche Arbeit bleibt man auf `main`. Branch-Wechsel ist nur noetig
wenn man direkt auf test/prod Aenderungen vornehmen muss (z.B. env-spezifische
Secrets). PRs werden ueber die GitHub-Weboberfläche erstellt.

```bash
# Normale Arbeit
git checkout main

# Nur wenn noetig: Direkter Zugriff auf test/prod
git checkout test   # oder: git checkout prod
# ... Aenderung ...
git push
git checkout main   # Zurueck auf main
```

### Umgang mit Branch-Drift

Wenn zwischen DEV und TEST/PROD viele Aenderungen aufgelaufen sind:

```bash
# Stand abfragen (ohne Merge)
git log main --not test --oneline   # Was ist auf main, aber nicht auf test?
git log test --not prod --oneline   # Was ist auf test, aber nicht auf prod?
```

**Empfehlung:** Mindestens woechentlich main → test → prod mergen, auch wenn
keine konkreten Aenderungen getestet werden muessen. Das haelt die Branches
synchron und die PRs uebersichtlich.

## Bekannte Einschraenkungen

1. **SOPS-Secrets:** `.enc.yaml` sind binaer. Bei Merge-Konflikten:
   Conflict-Marker entfernen, die korrekte Version behalten, SOPS re-encrypt.
   Tritt selten auf weil Secrets pro Umgebung in separaten Pfaden liegen.

2. **environments/dev/ auf test/prod-Branches:** Die DEV-Overlay-Dateien
   existieren auch auf den test/prod-Branches. Das ist harmlos — ArgoCD
   TEST/PROD referenziert nur die eigenen Pfade.

3. **targetRevision-Aenderungen:** Die targetRevision in den ArgoCD-App-
   Definitionen ist branch-spezifisch. Diese Aenderungen duerfen NICHT
   zurueck nach main gemergt werden. Bei PRs main→test darauf achten.

---

*Dieses Dokument dient als Anweisung fuer die Umsetzung in einem neuen Chat.*
