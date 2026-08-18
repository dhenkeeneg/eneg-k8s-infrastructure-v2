# OpenProject Update-Guide v2

**Erstellt:** 18.08.2026
**Ersetzt:** `phase-6.3-openproject-update-guide.md` (v1, 26.02.2026) — inhaltlich ueberholt
**Gueltig fuer:** OpenProject ab 17.7.2 in DEV, TEST und PROD
**Anlass:** Update 17.1.2 -> 17.7.2 ueber sechs Minor-Versionen

---

## 1. Zweck

Dieser Guide beschreibt das erprobte Verfahren fuer OpenProject-Updates in
allen drei Umgebungen. Er ist bewusst **versionsunabhaengig** formuliert —
die konkrete Historie des 17.7.2-Updates steht in der Projektplanung
v2.43. Wer das naechste Update fahren will, arbeitet Abschnitt 5 ab.

### Warum v1 ersetzt wurde

| v1 (26.02.2026) | Realitaet ab 18.08.2026 |
|---|---|
| Migration per `kubectl run ... rails db:migrate` manuell | laeuft automatisch im PreSync-Hook |
| Seeder als PostSync-Hook | PreSync — Migration VOR dem Pod-Rollout |
| Hocuspocus `latest` | auf Core-Version gepinnt |
| keine SSRF-Anforderung | ab 17.5.0 Pflicht-Allowlist |
| Versionsstaende 17.1.2 | 17.7.2 |

---

## 2. Architektur — wichtig vor dem ersten Eingriff

### Jede Umgebung hat eine eigene, vollstaendige Datei

```
kubernetes/environments/dev/apps/openproject/deployment.yaml    (~525 Zeilen)
kubernetes/environments/test/apps/openproject/deployment.yaml   (~570 Zeilen)
kubernetes/environments/prod/apps/openproject/deployment.yaml   (~583 Zeilen)
```

Die zugehoerigen ArgoCD-Applications zeigen direkt auf diese Verzeichnisse
(`spec.source.path`), es gibt **kein** Kustomize-Overlay und **keine**
gemeinsame Basis. Aenderungen an einer Umgebung wirken ausschliesslich dort.

> **`kubernetes/base/apps/openproject/` ist toter Code.** Keine einzige
> Application referenziert `path: kubernetes/base/apps` — nachgewiesen per
> Repo-Grep am 17.08.2026. Der Ordner ist ein historischer Stand (17.1.2)
> und darf nicht als Vorlage missverstanden werden. Ein Environment-Pinning
> per Kustomize-`images`-Patch ist deshalb **nicht** noetig.

### Umgebungsspezifische Werte

| | DEV | TEST | PROD |
|---|---|---|---|
| Hostname | `openproject-dev-v2.eneg.de` | `openproject-test.eneg.de` | `openproject.eneg.de` |
| Traefik LB | 192.168.180.100 | 192.168.179.100 | 192.168.178.100 |
| kubectl-Context | `k8s-dev` | `k8s-test` | `k8s-prod` |
| Datenbank | `cnpg-erp` / DB+User `openproject` | dito | dito |
| CNPG-Primary (wechselt!) | z.B. `cnpg-erp-4` | z.B. `cnpg-erp-1` | z.B. `cnpg-erp-1` |
| S3-Attachments | Garage `openproject-assets`, Service-CIDR | dito | dito |
| SMTP | **nicht** konfiguriert | ja, `openproject-test@eneg.de` | ja, `openproject@eneg.de` |
| Seeder-Deadline | 1800 s | 3600 s | 3600 s |
| Worker-Limit | 1Gi | 1Gi | **2Gi** (bewusste Ausnahme) |

Primary-Pod nie hart annehmen:
`kubectl --context <ctx> -n databases get pods -l cnpg.io/cluster=cnopg-erp`

### Downtime

`openproject-web` laeuft mit `replicas: 1` und `strategy: Recreate` — auch in
PROD. Erzwungen wird das durch das RWO-Longhorn-Volume fuer `/tmp`
(`openproject-tmp`). Die Unterbrechung ist damit **vollstaendig, nicht
rollierend**: rund 3 Minuten bei reinen Neustarts, 5–7 Minuten bei einem
Versionssprung mit Image-Pull. Beim Rollout erscheint regelmaessig ein
`FailedAttachVolume` / Multi-Attach-Warning, weil das RWO-Volume erst vom
alten Pod geloest werden muss — das loest sich nach ~25 s selbst und ist
**kein** Fehler.

---

## 3. Das Migrationsverfahren: PreSync-Hook

Der Seeder-Job fuehrt `/app/docker/prod/seeder` aus, also **`db:migrate`
gefolgt von `db:seed`** — in zwei klar getrennten Log-Phasen
(`Executing database migrations...` / `Executing database seed...`).

```yaml
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 3600
```

### Warum PreSync und nicht PostSync

Bis 17.08.2026 war der Hook `PostSync`. ArgoCD rollte damit **erst** die neuen
Pods aus und migrierte **danach** — neuer Code gegen altes Schema. Der
gefaehrliche Fall: der neue web-Pod wird ueber `/health_checks/default` nicht
ready, der Sync bleibt auf `Progressing`, und der PostSync-Hook feuert **nie**.
Ergebnis waere ein Deadlock aus halb ausgerolltem Code und nicht migrierter
Datenbank. Das v1-Dokument kannte das Problem schon als Workaround
("DB-Migration manuell via `kubectl run` wenn PostSync-Hook blockiert").

Mit PreSync ist die Reihenfolge korrekt **und** das Fehlerverhalten sicher:

> **Schlaegt der PreSync-Hook fehl, bricht der Sync ab und die alten Pods
> laufen unangetastet weiter.** Das ist die entscheidende Eigenschaft fuer
> PROD — ein kaputter Migrationslauf kann nicht zu neuem Code auf altem
> Schema fuehren.

### Nebenwirkung, die man kennen muss

**Aenderungen, die NUR den Hook betreffen, loesen keinen Sync aus.** ArgoCD
nimmt Ressourcen mit `argocd.argoproj.io/hook` aus dem Diff heraus — die App
bleibt `Synced`, der alte abgeschlossene Job bleibt liegen. Wer den
Mechanismus vorab testen will, braucht entweder einen zusaetzlichen echten
Manifest-Change im selben Commit (z. B. eine env-Variable) oder einen
manuellen Sync:

```bash
argocd app sync openproject --prune=false
```

---

## 4. Versionsabhaengige Pflicht-Konfiguration

Diese beiden Punkte sind dauerhaft gesetzt und duerfen **nicht** entfernt
werden. Sie sind der Grund, warum ein OpenProject-Update nicht nur ein
Tag-Wechsel ist.

### 4.1 `SECRET_KEY_BASE` — Pflicht ab 17.4.0

CVE-2026-46386. Ohne gesetzten Wert **bootet der Container nicht**. Bei uns
in web, worker und seeder aus `openproject-secrets` gesetzt, war also nie ein
Eingriff noetig. Wichtig bei Neuanlage einer Umgebung: Wert nicht neu
generieren, sonst werden alle Sessions und 2FA-Registrierungen ungueltig.

### 4.2 SSRF-Allowlist — Pflicht ab 17.5.0

Ab 17.5.0 blockt OpenProject ausgehende HTTP-Requests in reservierte Netze
(10/8, 172.16/12, 192.168/16, 127/8, 169.254/16) — laut Hersteller-Doku
ausdruecklich **auch dann, wenn ein Hostname eingetragen ist, der dorthin
aufloest**. Betroffen sind OIDC-Provider, File-Storages, Webhooks, der
Jira-Migrator und ab 17.6.0 zusaetzlich Wiki-Integrationen.

**Ohne Allowlist waeren bei uns ausgefallen:**

| Ziel | Aufloesung | Folge |
|---|---|---|
| Keycloak-OIDC via Traefik-LB | 192.168.17x.100 | Login gebrochen |
| Garage S3 `garage-s3.garage.svc` | 10.43.x.x | Attachment-Upload gebrochen |

Und zwar bei **gruenen Pods, gruenem Health-Check und gruenem ArgoCD** — das
ist der Grund, warum dieser Punkt hier so ausfuehrlich steht.

Einheitlich in `web` und `worker` **aller drei Umgebungen**:

```yaml
- name: OPENPROJECT_SSRF__PROTECTION__IP__ALLOWLIST
  value: "192.168.178.0/24,192.168.179.0/24,192.168.180.0/24,192.168.161.0/24,10.43.0.0/16,10.42.0.0/16"
```

| Eintrag | Begruendung |
|---|---|
| 192.168.178.0/24 | PROD-Netz (Traefik LB .100) |
| 192.168.179.0/24 | TEST-Netz |
| 192.168.180.0/24 | DEV-Netz |
| 192.168.161.0/24 | eNeG-Servernetz inkl. NAS mit externem S3 — **Vorsorge**, OpenProject spricht die NAS aktuell nicht an |
| 10.43.0.0/16 | Service-CIDR (Garage S3, Memcached) |
| 10.42.0.0/16 | Pod-CIDR (Headless Services) |

Die Liste ist absichtlich in allen Umgebungen identisch, damit ein
verschobener oder geteilter Dienst nicht still blockiert wird.

**Nicht betroffen und daher kein Grund fuer Eintraege:**

- **Image-Pulls** — die macht containerd auf den Nodes, nicht OpenProject.
  Auch nicht relevant, dass die Registry (Zot) nur in DEV laeuft und
  TEST/PROD von dort ziehen.
- **LDAP** — kein HTTP. Der produktive Anmeldeweg ist damit nie betroffen.
- **SMTP** — kein HTTP, und der Relay ist ein externer, oeffentlicher Host.

### 4.3 Der Seeder braucht die Allowlist nicht

Er macht keine ausgehenden HTTP-Requests. Bewusst nur an web und worker.

---

## 5. Ablauf eines Updates (Checkliste)

### Schritt 1 — Recherche, bevor etwas geaendert wird

- [ ] Release Notes **jeder uebersprungenen Minor-Version** lesen, nicht nur
      der Zielversion. Die kritischen Anforderungen (SECRET_KEY_BASE, SSRF)
      standen jeweils in einer Zwischenversion, nicht im Ziel-Release.
- [ ] Auf diese Stichworte achten: *breaking change*, *manual step*,
      *administrators need to*, *requires configuration*, *deprecated*.
- [ ] Image-Tags vorab auf Existenz pruefen — verhindert ImagePullBackOff
      mitten im Rollout:

```bash
# Core
curl -s https://hub.docker.com/v2/repositories/openproject/openproject/tags/<VERSION>-slim | head -c 200
# Hocuspocus (muss dieselbe Version haben)
curl -s https://hub.docker.com/v2/repositories/openproject/hocuspocus/tags/<VERSION> | head -c 200
```

### Schritt 2 — Backups (vor jedem Versionssprung)

Auf **k8s-mgmt-10**, `<CTX>` und `<VERSION>` ersetzen:

```bash
cat <<EOF | kubectl --context <CTX> apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: cnpg-erp-pre-op-<VERSION>
  namespace: databases
spec:
  cluster:
    name: cnpg-erp
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

kubectl --context <CTX> -n databases create job \
  --from=cronjob/cnpg-erp-logical-backup pre-op-<VERSION>-dump

velero backup create openproject-<ENV>-pre-<VERSION> \
  --include-namespaces openproject --kubecontext <CTX> --wait
```

Status pruefen — **vollqualifizierte Ressourcennamen zwingend**, sonst greift
der Namenskonflikt mit dem MariaDB-Operator:

```bash
kubectl --context <CTX> -n databases get backups.postgresql.cnpg.io cnpg-erp-pre-op-<VERSION>
kubectl --context <CTX> -n databases get job pre-op-<VERSION>-dump
kubectl --context <CTX> -n velero    get backups.velero.io openproject-<ENV>-pre-<VERSION>
```

Das **logische Dump** ist der praktische Rueckweg: damit stellt man nur die
`openproject`-DB wieder her, ohne den `cnpg-erp`-Cluster anzufassen, in dem
auch Odoo liegt. Das physische Backup ist die PITR-Ebene.

> **Nicht abgedeckt:** die Attachments im Garage-Bucket `openproject-assets`.
> Eine Migration greift sie nicht an — bei einem echten Rollback waere die DB
> aber auf einem aelteren Stand als der Bucket.

### Schritt 3 — Tags aendern (6 Stellen je Umgebung)

| Was | Anzahl |
|---|---|
| `image: openproject/openproject:<VERSION>-slim` (web, worker, seeder) | 3 |
| `app.kubernetes.io/version: "<VERSION>"` (web, worker) | 2 |
| `image: openproject/hocuspocus:<VERSION>` | 1 |

Nicht anfassen: `busybox` (init), `memcached` (eigener Zyklus, siehe 7.2).

Kontrolle:

```bash
grep -n "image:\|app.kubernetes.io/version" \
  kubernetes/environments/<ENV>/apps/openproject/deployment.yaml
```

### Schritt 4 — Commit und Push (auf dem Arbeitsplatz, nicht mgmt-10!)

```bash
hostname                                          # Maschine verifizieren
cd /Users/danielhenke/git/eneg-k8s-infrastructure-v2   # absoluter Pfad
git status --short --branch
git diff kubernetes/environments/<ENV>/apps/openproject/deployment.yaml
```

Mehrere `-m`-Flags statt einer mehrzeiligen Message — vermeidet Aerger mit
Anfuehrungszeichen in zsh.

### Schritt 5 — Verifikation (lesend, in dieser Reihenfolge)

```bash
# 1. ArgoCD hat den Commit gezogen
kubectl --context <CTX> -n argocd get applications.argoproj.io openproject \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision

# 2. PreSync-Job durchgelaufen
kubectl --context <CTX> -n openproject get jobs openproject-seeder \
  -o custom-columns=HOOK:.metadata.annotations.argocd\\.argoproj\\.io/hook,\
SUCCEEDED:.status.succeeded,START:.status.startTime,COMPLETE:.status.completionTime

# 3. Migrationslog — auf Exceptions und Rollbacks
kubectl --context <CTX> -n openproject logs job/openproject-seeder | head -100

# 4. Pods auf der neuen Version, 0 Restarts
kubectl --context <CTX> -n openproject get pods \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,\
RESTARTS:.status.containerStatuses[*].restartCount,IMAGE:.spec.containers[*].image

# 5. Allowlist ist in web + worker angekommen
kubectl --context <CTX> -n openproject get pods -o jsonpath=\
'{range .items[*]}{.metadata.name}{"  "}{range .spec.containers[*]}{range .env[?(@.name=="OPENPROJECT_SSRF__PROTECTION__IP__ALLOWLIST")]}{.value}{end}{end}{"\n"}{end}'

# 6. Worker arbeitet wirklich (nicht nur gestartet)
kubectl --context <CTX> -n openproject logs deploy/openproject-worker --tail=40
```

Beim Worker auf `[GoodJob] started scheduler`, `started cron with N jobs`,
`Notifier subscribed with LISTEN` und danach echte `Performed ...Job`-Zeilen
achten. „Gestartet" allein ist keine Bestaetigung.

### Schritt 6 — Backfill-Jobs pruefen (NICHT auslassen)

Der wichtigste nicht offensichtliche Schritt. Manche Versionen reihen
asynchrone Backfill-Jobs ein, die **fehlschlagen koennen, ohne dass Pods,
Logs, Health-Checks oder ArgoCD das zeigen**:

```bash
kubectl --context <CTX> -n databases exec -i <CNPG-PRIMARY> -c postgres -- \
  psql -U postgres -d openproject -c \
  "SELECT job_class, count(*) AS anzahl, max(finished_at) AS zuletzt,
          bool_or(error IS NOT NULL) AS hatte_fehler
     FROM good_jobs GROUP BY job_class ORDER BY anzahl DESC;"
```

Steht dort ein Job **nur** mit Fehler und ohne erfolgreichen Lauf, dann
zuerst pruefen, **ob ueberhaupt Daten betroffen sind** (siehe 7.4), und erst
danach nachziehen — als **eigener Job**, nie per exec (siehe 7.3).

### Schritt 7 — Funktionstest durch einen Menschen

Kein Log ersetzt das:

- [ ] Ab- und neu anmelden (LDAP; bei aktivem OIDC auch dieser Weg)
- [ ] Work Package oeffnen und speichern
- [ ] Wiki-Seite oeffnen — prueft Hocuspocus / Collaborative Editing
- [ ] Attachment anhaengen — prueft Garage S3 ueber den Service-CIDR
- [ ] **In TEST/PROD:** Testmail unter Administration -> E-Mail-Benachrichtigungen
- [ ] Version bestaetigen unter **Administration -> Information**

---

## 6. Gestaffelt oder in einem Sprung?

Beides ist erprobt.

| | Gestaffelt (DEV, 17.08.) | Direktsprung (TEST/PROD, 18.08.) |
|---|---|---|
| Etappen | 6 (je letzter Patch der Minor-Linie) | 1 |
| Migrationen | verteilt, ~2 Min gesamt | 107 in 100 s (TEST) / 42 s (PROD) |
| Downtime | 6 x ~3 Min | 1 x ~5–7 Min |
| Fehlereingrenzung | maximal | gut, solange die Logs gelesen werden |

**Empfehlung:** Die **erste** Umgebung gestaffelt — dort findet man die
versionsabhaengigen Anforderungen, und man will wissen, welche Etappe ein
Problem verursacht hat. Die **folgenden** Umgebungen als Direktsprung, weil
jede Migration dann schon gegen echte eNeG-Daten validiert ist und die
Ausgangsversion identisch ist.

Der Direktsprung laeuft in **zwei Commits**:

1. **Vorbereitung ohne Versionswechsel** — PreSync, Deadline, Allowlist. Weil
   dabei auch die Deployments veraendert werden (env-Variable), loest ArgoCD
   einen Sync aus und der PreSync-Hook macht automatisch seinen Trockenlauf
   mit der **alten** Version. Migration ist ein No-Op, Seeding idempotent.
2. **Upgrade** — Tags auf die Zielversion.

So ist der Mechanismus bestaetigt, bevor echte Migrationen laufen.

---

## 7. Stolperfallen

### 7.1 Falsche Maschine, falscher Cluster

Beide sind uns real passiert.

- **`~/git/eneg-k8s-infrastructure-v2` existiert auf MacMini UND k8s-mgmt-10.**
  Eine Anleitung mit `cd ~/git/...` fuehrte dazu, dass Commits im falschen
  Clone versucht wurden (`nothing to commit` + `fetch first`). **Immer
  absolute Pfade und ein `hostname` davor.**
- **Auf k8s-mgmt-10 zeigte der kubectl-Default-Context auf `k8s-test`, die
  `argocd`-CLI aber auf DEV.** Ein `velero backup create` ohne
  `--kubecontext` landete dadurch im falschen Cluster. **Immer `--context`
  bzw. `--kubecontext` explizit setzen**, auch wenn der Default gerade passt —
  dann ist im Terminalverlauf spaeter noch erkennbar, was gemeint war.

### 7.2 `latest`-Tags

`openproject/hocuspocus:latest` wurde laufend neu gebaut. Beleg, wie stark
das driftet: unter **demselben** `latest` lief DEV am 17.08. auf Hocuspocus
**v3.4.4**, TEST am 18.08. auf **v4.3.0**. Ein Pod-Restart zog also einen
unbekannten Build — ohne Rollback-Punkt und potenziell inkompatibel zum Core.

**Regel:** Hocuspocus zieht immer mit dem Core-Tag mit. Memcached wird
separat gepflegt (aktuell `1.6.45-alpine`) und bewusst **nicht** in einem
Update-Commit mitgeaendert, damit pro Etappe nur eine Variable wechselt.

### 7.3 `rails runner` nie per exec in den Worker

```bash
# FALSCH — fuehrt zu OOMKilled (Exit 137), der Worker startet neu
kubectl exec deploy/openproject-worker -- bundle exec rails runner '...'
```

Ein zweiter vollstaendiger Rails-Prozess passt nicht neben den laufenden
Worker (Limit 1Gi in DEV/TEST). Richtig ist ein **eigener Job** mit eigenem
Limit:

```bash
cat <<'EOF' | kubectl --context <CTX> apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: op-einmal-aufgabe
  namespace: openproject
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 900
  template:
    spec:
      restartPolicy: Never
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsGroup: 1000
      containers:
        - name: runner
          image: openproject/openproject:17.7.2-slim
          command: ["bundle","exec","rails","runner","<RUBY-AUSDRUCK>"]
          env:
            - name: RAILS_ENV
              value: "production"
            - name: TMPDIR
              value: "/tmp"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: {name: openproject-secrets, key: database-url}
            - name: SECRET_KEY_BASE
              valueFrom:
                secretKeyRef: {name: openproject-secrets, key: secret-key-base}
          resources:
            requests: {cpu: 250m, memory: 1Gi}
            limits:   {cpu: "2",  memory: 3Gi}
EOF
```

Anderer Name als `openproject-seeder` waehlen, damit ArgoCD ihn nicht mit dem
verwalteten Hook verwechselt; ohne Tracking-Annotation wird er nicht
weggeprunt. Nach dem Lauf `kubectl delete job` aufraeumen.

### 7.4 Erst pruefen, dann reparieren

Als `Backlogs::MigrateVersionSprintJournalsJob` in DEV und PROD fehlschlug,
war die naheliegende Reaktion, ihn nachzuziehen. Die Datenpruefung zeigte
aber, dass PROD und TEST identisch waren — die Arbeit hatten die
SQL-Migrationen bereits erledigt. Nur DEV fehlte wirklich etwas.

```bash
kubectl --context <CTX> -n databases exec -i <CNPG-PRIMARY> -c postgres -- \
  psql -U postgres -d openproject -t -c \
  "SELECT 'versionen=' || (SELECT count(*) FROM versions)
       || '  sprints='  || (SELECT count(*) FROM sprints)
       || '  journale_mit_sprint=' || (SELECT count(*) FROM work_package_journals WHERE sprint_id IS NOT NULL);"
```

Umgebungen vergleichen statt aus einem Fehler-Log auf Datenverlust schliessen.

### 7.5 Namenskonflikt `backup`

`kubectl get backup` loest auf `backups.k8s.mariadb.com` auf, weil der
MariaDB-Operator dieselbe Kurzform registriert. Ergebnis sind irritierende
`NotFound`-Meldungen fuer Backups, die sehr wohl existieren. Immer
`backups.postgresql.cnpg.io` bzw. `backups.velero.io` schreiben.

### 7.6 Der `-c postgres`-Hinweis

`kubectl exec` in einen CNPG-Pod ohne `-c postgres` gibt eine
Defaulted-container-Warnung aus. Harmlos, aber mit `-c postgres` bleibt die
Ausgabe sauber.

---

## 8. Rollback

**Ab 17.4.1 ist ein Rollback durch Zuruecksetzen des Image-Tags nicht mehr
moeglich.** Beim Weg auf 17.7.2 wurden Tabellen und Spalten geloescht:

| Version | Destruktive Operation |
|---|---|
| 17.4.1 | `drop_table(:scheduled_meetings)` |
| 17.5.1 | `drop_table(:version_settings)`, `remove_column(:custom_fields, :position_in_custom_field_section)` |
| 17.7.2 | `DELETE FROM enabled_modules WHERE name = 'wiki'`, `remove_column(:sprints, :sharing)` |

Ein Rueckweg erfordert damit ein **DB-Restore**:

1. web und worker auf `replicas: 0` (per Git, damit ArgoCD nicht zurueckdreht)
2. `openproject`-DB aus dem logischen Dump wiederherstellen
3. Image-Tags im Git auf die Ausgangsversion zuruecksetzen
4. Replicas zurueck auf 1

Zu bedenken: Attachments im Garage-Bucket sind **nicht** Teil des Restores und
liegen danach auf einem neueren Stand als die Datenbank.

---

## 9. Was am Ende offen blieb

| Punkt | Status |
|---|---|
| `kubernetes/base/apps/openproject/` (toter Code, Stand 17.1.2) | Aufraeumen offen — Entfernung vorgeschlagen |
| Keycloak-OIDC-Konfiguration (~20 Zeilen je Umgebung, wirkungslos) | Aufraeumen offen |
| Worker-Limit in DEV/TEST | bewusst auf 1Gi belassen, nur PROD auf 2Gi |
| Wiki-Berechtigungen | 17.5.1 hat acht granulare Wiki-Rechte aus `role_permissions` geloescht — Rollenkonfiguration einmal durchsehen |
| Wiki als Modul | ab 17.7.2 keine `enabled_modules`-Eintragung mehr, sondern `wikis.enabled` — in der Projektkonfiguration nicht mehr sichtbar, das ist gewollt |

### Zur toten Keycloak-Konfiguration

Der Beleg steht in **jedem** Seeder-Lauf:

```
↳ OpenIDConnect::ProviderSeeder
   *** Skipping EnvData::OpenIDConnect::ProviderSeeder
```

Es wurde also nie ein OIDC-Provider aus den Umgebungsvariablen angelegt,
entsprechend gibt es keinen Keycloak-Button auf der Login-Seite. Die
produktive Anmeldung laeuft ueber LDAP. Keycloak selbst **laeuft** im Cluster
als eigene Anwendung — nur OpenProject nutzt es nicht.

---

## 10. Referenzen

- Release Notes: https://www.openproject.org/docs/release-notes/
- SSRF-Schutz: https://www.openproject.org/docs/installation-and-operations/configuration/ssrf-protection/
- Projektplanung v2.43 — vollstaendige Historie des 17.7.2-Updates
- `docs/guides/phase-6.3-openproject-update-guide.md` — v1, historisch
- `docs/phases/phase-06-pilot-apps.md` — Ersteinrichtung OpenProject

---

## Aenderungshistorie

| Datum | Version | Aenderung |
|---|---|---|
| 26.02.2026 | 1.0 | Erstfassung als Handoff (Datei `phase-6.3-openproject-update-guide.md`) |
| 18.08.2026 | 2.0 | Neufassung nach dem Update 17.1.2 -> 17.7.2 in DEV, TEST und PROD. Verfahren auf PreSync-Hook umgestellt, SSRF-Allowlist und SECRET_KEY_BASE als versionsabhaengige Pflicht dokumentiert, Hocuspocus-Pinning, Backfill-Job-Pruefung als eigener Schritt, Stolperfallen aus dem realen Ablauf ergaenzt, Rollback-Abschnitt wegen destruktiver Migrationen neu. |

---

*Erstellt im Rahmen des OpenProject-Updates 17.1.2 -> 17.7.2 (17.–18.08.2026).*
