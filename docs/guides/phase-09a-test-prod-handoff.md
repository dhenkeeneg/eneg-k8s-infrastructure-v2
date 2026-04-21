# Phase 9a — Anweisung fuer neuen Chat (TEST-Mirror + Etappe B PROD)

**Stand:** 21.04.2026 — **Etappe A VOLLSTAENDIG ABGESCHLOSSEN (DEV+TEST+PROD).** Etappe B (PROD-Zot + Cutover) offen.
**Vorgaenger-Doku (Pflichtlektuere):** `docs/phases/phase-09a-security-registries.md` insbesondere Sektion 12 (Implementierungs-Learnings, inkl. 12.13–12.15 TEST+PROD-Abschluss)

---

## Kontext-Brief fuer den neuen Chat

Phase 9a Container Registry Infrastruktur (Zot) hat Etappe A **vollstaendig** abgeschlossen: DEV-Zot deployed + konfiguriert, containerd-Mirror auf allen 9 Nodes (DEV + TEST + PROD) via Ansible-Playbook 07 ausgerollt, End-to-End-Pulls in allen drei Envs verifiziert (hello-world/nginx in DEV, alpine in TEST, busybox in PROD), eigene Images aus `ghcr.io/dhenkeeneg/*` erscheinen im Zot-Catalog als `eneg/*`. Ansible-Playbook 07 wurde env-agnostisch gemacht (Variable `kubectl_context` aus Inventory-Dir abgeleitet). Der Multi-Arch-Bug wurde mit `preserveDigest: true` + `http.compat: ["docker2s2"]` geloest. DockerHub-Authentifizierung ist aktiv (Rate-Limit-Bypass fuer Sync).

**Was jetzt ausstehend ist:**

1. **Trivy-Rate-Limit-Fix in DEV** (nicht blockierend, DEV-local): Trivy Operator umgeht den containerd-Mirror (Remote-API-Pull direkt an `index.docker.io`). Fix: `TRIVY_REGISTRY_MIRROR=docker.io=registry-dev.eneg.de` als additionalEnvVar. Kann nach Etappe B gemacht werden.
2. **Etappe B: PROD-Zot komplett aufsetzen** (eigene Registry, Sync DEV→PROD, kein Internet-Fallback fuer PROD nach Cutover)

---

## Pflicht-Lesereihenfolge zu Beginn des neuen Chats

1. `docs/phases/phase-09a-security-registries.md` — **insbesondere Section 12.13–12.15** (TEST+PROD-Rollout-Learnings und Etappe-A-Final-Summary) und Section 6 (Etappe B)
2. `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.18.md` (Aenderungshistorie)
3. Diese Datei (Folge-Anweisung)

---

## Konkrete naechste Schritte (Reihenfolge!)

### Schritt 1 — TEST-Cluster containerd-Mirror ✅ ABGESCHLOSSEN (21.04.2026)

```bash
# Auf k8s-mgmt-10
cd ~/git/eneg-k8s-infrastructure-v2
git pull origin main
ansible-playbook -i ansible/inventory/test/hosts.ini ansible/playbooks/07-k3s-registries-mirror.yml
```

Ergebnis: PLAY RECAP `ok=15-16, changed=2, failed=0` auf allen 3 TEST-Nodes. hosts.toml mit Mirror verifiziert. alpine im Catalog.

### Schritt 2 — PROD-Cluster containerd-Mirror (mit Fallback bis Etappe B) ✅ ABGESCHLOSSEN (21.04.2026)

```bash
ansible-playbook -i ansible/inventory/prod/hosts.ini ansible/playbooks/07-k3s-registries-mirror.yml
```

Ergebnis: PLAY RECAP `ok=15-16, changed=2, failed=0` auf allen 3 PROD-Nodes. busybox-Test-Pull via Mirror erfolgreich. ArgoCD-Apps unveraendert Synced+Healthy.

**Hinweis:** Das Playbook 07 verwendet hardcoded `registry-dev.eneg.de` als Endpoint und bleibt so, bis Etappe B. Fuer Etappe B wird eine angepasste Variante (oder Variable-Override) eingefuehrt, die fuer PROD auf `registry-prod.eneg.de` OHNE Fallback umstellt.

### Schritt 3 — Trivy Rate-Limit-Aufloesung in DEV — OFFEN, nicht blockierend

**Stand 21.04.2026:** Trivy-Operator zeigt weiterhin `TOOMANYREQUESTS` fuer `docker.io/*`-Images (`velero/velero`, `busybox`, `odoo`, `kiwigrid/k8s-sidecar`). Ursache: Trivy nutzt Remote-API direkt gegen `index.docker.io`, umgeht den containerd-Mirror.

**Fix-Strategie:**

Option 1 (Favorit — Mirror-Vernetzung):
```yaml
# kubernetes/environments/dev/trivy-operator/values-override.yaml
trivy:
  additionalEnvVars:
    - name: TRIVY_REGISTRY_MIRROR
      value: "docker.io=registry-dev.eneg.de"
```
(Exakter Konfigurations-Pfad muss vor Umsetzung gegen Trivy Operator + Aqua-Helm-Chart-Doku verifiziert werden.)

Option 2 (Rate-Limit-Bypass via Auth):
DockerHub-PAT an Trivy geben via `dockerConfigAuth` Secret-Referenz → authenticated Limit 200/6h statt anonymer 60/6h.

Option 3 (Security-tradeoff):
containerd-Socket `/run/k3s/containerd/containerd.sock` in Trivy-Scan-Job-Template mounten → privilegierte Pods, nicht empfohlen.

Verifikation nach Fix:
```bash
kubectl --context k8s-dev -n trivy-system logs -l app.kubernetes.io/name=trivy-operator --tail=200 | grep -iE "TOOMANYREQUESTS|rate.limit" | tail -20
# Erwartung: leerer Output
kubectl --context k8s-dev get vulnerabilityreports -A --no-headers | wc -l
# Erwartung: deutlich > 162 (aktueller Stand vor Fix)
```

### Schritt 4 — Eigene Images Sync (`dhenkeeneg/*`) ✅ VERIFIZIERT (21.04.2026)

Catalog zeigt `eneg/idoit-open`, `eneg/eneg-it-info-versand`, `eneg/prometheus-msteams` — scheduled Sync (PollInterval 15 min) aktiv.

### Schritt 5 — Etappe B starten (PROD-Registry) — AUSSTEHEND

**Erst nach Schritt 3 oder ohne Abhaengigkeit dazu.** Vorgehen siehe `phase-09a-security-registries.md` Section 6 (B1-B6). Kurzform:

1. **B1:** Bucket `k8s-prod-registry` auf NAS10 (✓ bereits erstellt, Stand 21.04.2026), eigene S3-Keys generieren (separate von DEV)
2. **B2:** Kopiere `kubernetes/environments/dev/registry/` nach `kubernetes/environments/prod/registry/`, anpassen:
   - S3-Bucket-Name → `k8s-prod-registry`
   - DNS → `registry-prod.eneg.de` (✓ bereits im DNS angelegt, Stand 21.04.2026)
   - Sync-Config: **NUR EINE** Source `https://registry-dev.eneg.de` mit Denylist-Filter (siehe Section 6 B4 fuer Tag-Liste)
   - **KEINE Proxy-Cache OnDemand-Registries** (PROD darf nichts aus dem Internet ziehen)
3. **B3:** Analog `registry-secrets/` mit eigenen Keys (SOPS), plus htpasswd fuer User `eneg` + Robot-User `sync-to-prod` in DEV-Zot
4. **B4:** ArgoCD-Apps `prod/infrastructure/registry-secrets-app.yaml` und `registry-app.yaml`
5. **Warm-up:** Initial-Sync abwarten (Zot-Logs + Catalog auf registry-prod.eneg.de pruefen). **Kritisch:** Wegen OnDemand-First-Pull-Latency (Section 12.13.1) muessen alle produktiven PROD-Images synct sein, bevor der Cutover stattfindet.
6. **B5:** Ansible 07 anpassen fuer PROD: Endpoint `registry-prod.eneg.de`, **KEIN** Fallback (entweder zweites Playbook `07b` oder Variable-Override `-e zot_registry_url=https://registry-prod.eneg.de`). Erneut ausrollen NUR auf PROD-Cluster.
7. **B6:** Verifikation laut Section 6 B6 Checkliste (eigener PROD-Zot antwortet, Pod-Restart-Test, Neu-Deployment-Test, alle ArgoCD Synced+Healthy).

### Schritt 6 — Doku-Update nach Etappe B Abschluss

- `phase-09a-security-registries.md` Section 12 ergaenzen mit Etappe-B-Learnings, Status auf "VOLLSTAENDIG ABGESCHLOSSEN"
- `phase-09-security-dev.md` Learning #8 (DockerHub Rate-Limit) auf "geloest" markieren mit Referenz auf Phase 9a
- Neue Projektplan-Version `K8s-GitOps-Infrastruktur-Projektplanung_v2.19.md` mit Phase 9a Vollabschluss
- Naechste Phase: 9b (CrowdSec + Falco)

---

## Wichtige Projekt-Eigenheiten (KOPIE aus Memory)

- Alle Git-Commits/Pushes fuehrt Daniel selbst aus, nicht Claude
- Keine SSH-Kommandos von Claude auf Nodes oder k8s-mgmt-10
- Claude nutzt Desktop Commander fuer Repo-Dateien auf Windows-Laptop `C:\Users\dhenke\git\eneg-k8s-infrastructure-v2`
- Kubernetes-Zugriff per MCP (Contexts `k8s-dev`, `k8s-test`, `k8s-prod`)
- SOPS-verschluesselte Secrets per Age-Key auf k8s-mgmt-10 (`age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm`)
- Keine Entscheidungen ohne Optionen-Praesentation; Daniel entscheidet
- Immer DEV zuerst, dann TEST, dann PROD — nie parallel
- Schritt-fuer-Schritt vorgehen, Zwischen-Checkpoints, Daniel sagt "weiter" / "los" / "OK weiter"

---

## Kritische Learnings aus Etappe A (NICHT vergessen!)

1. **Multi-Arch + S3 + OnDemand braucht `preserveDigest: true` + `http.compat: ["docker2s2"]`** — beides muss zusammen gesetzt sein, sonst Pod-CrashLoop oder `invalid manifest content`. Fuer PROD-Sync (kein OnDemand, sondern scheduled) gilt das gleiche, weil DockerHub-Manifests vom DEV-Zot byte-exakt nach PROD propagieren muessen.

2. **DockerHub-Authentifizierung muss in PROD-Sync **nicht** noetig sein**, weil PROD nur von DEV-Zot zieht (kein DockerHub-Kontakt). Aber DEV braucht weiterhin DockerHub-PAT.

3. **K3s containerd default endpoint fallback** funktioniert seit 1.26.13 ohne `rewrites:`. NICHT `rewrites:` einfuegen — verursacht Doppelpfade.

4. **ArgoCD Replica-State** wird nach manuellem `scale=0` nicht zurueckgesetzt; bei Reset-Operationen muss man manuell wieder `scale=1` machen.

5. **Zot ist distroless** — `kubectl exec ... -- sh` schlaegt fehl. Verifikation laeuft via HTTP-API von extern.

6. **Sync-Credentials JSON-Format** kann mehrere Upstream-Registries enthalten; eine einzige Datei reicht fuer ghcr.io + DockerHub + ggf. mehr.

7. **Erste Sync-Iteration zeigt `cache miss` Warnings** — das ist normal, nicht Fehler. Erfolgs-Signal ist `successfully synced image`.

8. **First-pull cache miss ist erwartetes Verhalten** — bei zweitem Pull ist der Manifest-Index im Catalog und keine Warnings mehr.

---

## Wenn etwas schiefgeht

**Pod startet nicht (CrashLoopBackOff):**
- `kubectl --context k8s-dev -n registry logs registry-zot-0 --previous`
- Pruefen ob `preserveDigest` ohne `http.compat` konfiguriert ist (Fehlermeldung `can not use PreserveDigest option without enabling http.Compat`)

**`invalid manifest content` Fehler:**
- Multi-Arch-Bug. `preserveDigest: true` + `http.compat: ["docker2s2"]` setzen, dann State-Reset (Bucket leeren, PVC loeschen)

**State-Reset Procedure (NUR im Notfall):**
1. ArgoCD App `registry` pausieren
2. `kubectl scale -n registry sts/registry-zot --replicas=0`
3. `kubectl delete pvc -n registry registry-pvc-registry-zot-0`
4. NAS10 Bucket `k8s-dev-registry` leeren via QuObjects UI
5. `kubectl scale -n registry sts/registry-zot --replicas=1` (NICHT 0 lassen — ArgoCD restored das nicht!)
6. ArgoCD App wieder enable

**containerd Mirror funktioniert nicht:**
- `cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml` — pruefen
- `crictl pull --debug docker.io/library/alpine:3` — sehen wo es haengt
- Default endpoint fallback sollte aktiv sein, sonst funktioniert auch `nginx:latest` nicht ohne Mirror

---

## Erste Aktion im neuen Chat

Anweisung an Claude:

> Wir machen mit Phase 9a Etappe B (PROD-Zot + Sync DEV→PROD + Cutover auf PROD ohne Internet-Fallback) weiter. Etappe A ist vollstaendig abgeschlossen (DEV + TEST + PROD containerd-Mirror, siehe `docs/phases/phase-09a-security-registries.md` Section 12.13–12.15). Lies bitte zuerst Section 6 (Etappe B) der Phase-Doku und diese Folge-Anweisung komplett. Optional vor Etappe B: Trivy-Rate-Limit-Fix in DEV (Schritt 3 dieser Anweisung) — kann parallel oder nach Etappe B gemacht werden. Praesentiere mir die naechsten konkreten Schritte mit Optionen.
