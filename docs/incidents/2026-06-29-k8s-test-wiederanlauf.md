# Incident/Protokoll: Wiederanlauf k8s-test nach Langzeit-Abschaltung

**Zeitraum:** 2026-06-29 (Start ~16:30 CEST) bis 2026-06-30 (Storage-Finale)
**Umgebung:** k8s-test (k8s-test-21/22/23, K3s v1.35.1+k3s1, embedded etcd)
**Durchgefuehrt von:** Daniel Henke (VM-Power, kubectl) + Claude (kubectl-Steuerung via MCP, Analyse)
**Bezug:**
- Runbook: `docs/runbooks/test-cluster-wiederanlauf.md` (Variante A, zeitfenster-basiert)
- Vorlauf-Incident: `docs/incidents/2026-06-29-cnpg-wal-deadlock-longhorn-kaskade.md`
- Galera-Vorlauf: `docs/incidents/2026-05-11-mariadb-galera-recovery.md`

---

## Ausgangslage

k8s-test war seit dem Longhorn-Rebuild-Sturm (gemeinsam mit k8s-prod) abgeschaltet.
Ziel des Wiederanlaufs: Cluster hochfahren, OHNE erneut eine Rebuild-/IO-Kaskade
auszuloesen. Strategie: Storage-Bremsen vor jeglicher Workload-Last scharf stellen,
dann Schicht fuer Schicht kontrolliert hochfahren (Storage -> DB -> Monitoring/S3 -> Apps).

Beim Start aktiv im persistierten Cluster-State (aus Mai-Incident):
- `concurrentReplicaRebuildPerNodeLimit: 2`
- `replicaReplenishmentWaitInterval: 600`
- `concurrentVolumeBackupRestorePerNodeLimit: 1`

---

## Ablauf (chronologisch)

### Phase 1 - Storage-Cluster hochfahren (Node fuer Node)

1. **k8s-test-22 zuerst** (Single-Node-Antest): k3s `activating` (etcd wartet auf Peers,
   `no route to host` zu .21/.23 - erwartet). Disk-Check sauber (nur EXT4-Mount-Meldungen,
   keine I/O-/Medium-Errors). 501G/18%.
2. **k8s-test-23 dazu** -> etcd-Quorum (2/3), API schreibbar. SOFORT die zwei Bremsen:
   - `argocd-application-controller` -> 0 (StatefulSet)
   - Longhorn `concurrent-replica-rebuild-per-node-limit` -> 0
   Verifiziert: value=0, keine echten Rebuilds (currentState=running + rebuildStatus).
   - WICHTIG: "aktive rebuilds: 3" war anfangs eine Fehlmessung (kaputter stdin durch
     Zeilenrest) bzw. Statusrelikte an gestoppten Engines (currentState=stopped,
     progress=0, alte Pod-IP 10.42.0.111). KEINE echten Rebuilds.
3. **k8s-test-21 zuletzt** (historisches Sorgenkind): Disk sauber, keine I/O-Errors.
   Alle 3 Nodes Ready, Limit haelt auf 0.

**Lehre:** Single-Node-Start ohne Quorum ist als Antest brauchbar, aber NICHT als
Konfig-Fenster (embedded etcd braucht 2/3 fuer schreibbare API). Die Bremsen MUESSEN
direkt nach Quorum-Bildung gesetzt werden. Das hat sauber funktioniert.

### Phase 1b - Longhorn-System entsperren (Cordon-Falle)

Befund: Alle 3 Nodes waren `SchedulingDisabled` (Altzustand). Folge: Longhorn
`instance-manager` fehlte komplett, `longhorn-driver-deployer` haengt im Init
(wartet auf `discover-proc-kubelet-cmdline`, der wegen Cordon nicht schedulen kann).
-> Kette: Cordon -> kein discover -> driver-deployer-Init haengt -> kein instance-manager
-> kein Volume kann attachen.

Loesung: Workloads kontrolliert stilllegen (s. Phase 2-Vorbereitung), DANN node-weise
uncordonen. -23 zuerst -> instance-manager + driver-deployer kamen sauber hoch.
Dann -22, dann -21. Bei jedem Schritt Limit=0 verifiziert, keine Rebuilds.

**Lehre:** `kubectl uncordon` (K8s-Ebene) und Longhorn `node.spec.allowScheduling`
(Longhorn-Ebene) sind ZWEI getrennte Schalter. Cordon blockiert auch Longhorns
eigene DaemonSets (discover, instance-manager) - nicht nur Workloads.

### Phase 2 - Workloads stilllegen VOR dem Uncordonen (ArgoCD-sicher)

Da `argocd-application-controller`=0 (kein Reconcile), konnten direkte Eingriffe
gesetzt werden, ohne dass ArgoCD sie sofort zurueckdreht. Stillgelegt:
- **CNPG:** Operator `cnpg-cloudnative-pg` -> 0 skaliert (Hibernation-Annotation
  `cnpg.io/hibernation=on` wirkte in dieser Version NICHT; `instances:0` ist per
  CRD-Validierung verboten (>=1). Operator-Scale-to-0 + Pending-Pods loeschen war der
  funktionierende Weg.)
- **Galera:** `spec.suspend=true` (Operator-Recovery stoppt) + `statefulset replicas=0`
  (StatefulSet-Controller erzeugt sonst weiter Pods - suspend allein setzt STS NICHT auf 0).
- **Monitoring:** loki/loki-chunks-cache/thanos-storegateway StatefulSet -> 0;
  prometheus + alertmanager ueber ihre CRs `spec.replicas:0` (Operator-verwaltet,
  STS-Scale wird sonst zurueckgesetzt).
- **Garage:** StatefulSet -> 0.
- **Apps:** keycloak/n8n/odoo/openproject(web+worker)/idoit/it-info-versand -> 0
  (verhindert CrashLoop-Last, da DBs noch nicht verfuegbar).
- **CNPG-Backup-CronJobs:** suspend=true (verhindert ins Leere laufende Backup-Jobs).

**Lehre:** Operator-verwaltete Workloads (CNPG, prometheus-operator, mariadb-operator)
lassen sich NICHT zuverlaessig per StatefulSet-Scale stilllegen - der jeweilige Operator
erzeugt sie neu. Korrekt: am Operator-Objekt ansetzen (CR-replicas, Operator-Scale, suspend).

### Phase 3 - DB-Layer kontrolliert hochfahren

WAL-Lage vorab geprueft (Lehre aus WAL-Deadlock-Incident):
- cnpg-erp: Primary erp-4 WAL 6% (entspannt). Replica erp-1 WAL 118% (uebergelaufen!),
  erp-2 87%. ABER: Primary mit leerem WAL startet sauber -> Replicas holen sich Stand
  vom Primary. KEIN Deadlock (anders als DEV, weil sauberer Stop statt Crash).
- cnpg-shared: alle WAL moderat (49/74/56%).

CNPG-Operator wieder auf 1. Beide Cluster kamen parallel hoch (reconciliationLoop-Disable
schlug fehl wg. Webhook-not-ready im Moment des Patches - unkritisch, da beide Primaries
problemlos starteten). **Ergebnis: cnpg-erp + cnpg-shared je 3/3 "Cluster in healthy state".**

### Phase 3b - Galera-Recovery (KOMPLIKATION, ausfuehrlich)

Galera `suspend=false` gesetzt -> Operator-Recovery startete. **Problem:** Operator
waehlte galera-0 als Bootstrap-Node, weil dessen `grastate.dat` zufaellig
`safe_to_bootstrap: 1` trug - obwohl galera-0 DIVERGIERT war:

| Node     | UUID (grastate)      | GCache seqno | Synced | safe_to_bootstrap |
|----------|----------------------|--------------|--------|-------------------|
| galera-0 | b387164d (abweichend)| -1 (leer)    | 0      | 1 (falsch gewaehlt)|
| galera-1 | 603a5885             | 485-491      | 1      | 0                 |
| galera-2 | 603a5885             | 9-486        | 1      | 0                 |

galera-0 crashte beim Bootstrap (libgalera_smm.so -> abort in WSREP-Init), galera-1/2
ebenso (sie bekamen faelschlich `bootstrap option: 1`, scheiterten an safe_to_bootstrap:0).

Korrekt war: Bootstrap von **galera-1** (hoechste seqno 491, gueltige UUID).

**Loesungsweg (mehrere Iterationen, nicht alle noetig - s. Lehren):**
1. `forceClusterBootstrapInPod: mariadb-galera-1` gesetzt (offizieller Operator-Mechanismus
   ab v0.0.30, hier Operator 25.10.4).
2. Operator-Reconcile hing zunaechst ("recovery status not completed" nach zu aggressivem
   `status.galeraRecovery=null`-Reset - FEHLER, der den Operator in Sackgasse brachte).
3. Sauberer Ausweg: MariaDB-CR geloescht (PVCs bleiben, OwnerRef=none verifiziert!) und
   aus Repo-Manifest neu angewandt -> frischer Recovery.
4. Beim frischen Recovery erneut galera-0 gewaehlt (gleiche Ursache). Daher:
   `forceClusterBootstrapInPod: mariadb-galera-1` + gezielter `status.galeraRecovery.bootstrap=null`
   (NUR bootstrap, nicht ganzer Status). -> Operator bootstrappte galera-1.
5. galera-0 + galera-2 traten per SST/IST bei. **Ergebnis nach ~mehreren Minuten:
   alle 3 Galera-Pods 2/2 Running, Event `GaleraClusterHealthy`, ready=True.**
6. `forceClusterBootstrapInPod` wieder ENTFERNT (Doku-Pflicht: sonst zwingt es kuenftige
   Recoverys immer auf galera-1).

Vorab als Sicherheitsnetz: Longhorn-Snapshot `galera-1-pre-sst-recovery` des Volumes
`pvc-4386f037-...` (storage-mariadb-galera-1) erstellt. (Aufraeumen nach Stabilitaet.)

### Phase 4 - Monitoring, Garage, Apps

- Garage StatefulSet -> 3: sauber, 3/3, ueber alle Nodes verteilt.
- Monitoring: loki/loki-chunks-cache/thanos-storegateway STS -> 1; prometheus+alertmanager
  CR-replicas -> 1. Alle Running (prometheus 3/3, alertmanager 2/2, loki 2/2, grafana 3/3).
  Anmerkung: kube-state-metrics zeigte 132 Restarts - historisch ueber 52d akkumuliert,
  letzter = Cluster-Reboot, aktuell stabil ready. Kein Handlungsbedarf, Beobachtung.
- Apps gestaffelt (je einzeln verifiziert): keycloak (Keycloak 26.5.4 started) -> n8n ->
  odoo -> openproject-web (Readiness braucht ~90s) -> openproject-worker -> idoit
  (bestaetigt Galera-DB funktional!) -> it-info-versand. Alle 1/1 Running, 0 Restarts.

Clusterweiter Check: keine nicht-laufenden Pods (ausser bewusst auf 0: ArgoCD-Controller,
CNPG-Backup-CronJobs). Rebuild-Limit durchgehend 0, KEIN Sturm waehrend des gesamten Anlaufs.

### Phase 5 - Storage-Finale (Stand: in Arbeit)

- Longhorn `k8s-test-22 allowScheduling` -> true (war Altzustand false aus Sturm).
  Alle 3 Nodes nun schedulebar.
- Rebuild-Limit 0 -> 1 gesetzt. ABER: Rebuilds starteten zunaechst NICHT, weil
  `replicaReplenishmentWaitInterval: 600` Longhorn 10 min warten laesst, bevor fehlende
  Replicas neu aufgebaut werden. Entscheidung: Geduld, Timer ablaufen lassen (Limit=1
  schliesst Sturm ohnehin aus). Volumes-Stand bei Start: ~18 degraded, ~15 healthy, 2 unknown.
- NOCH OFFEN: nach Rebuild-Abschluss Limit 1->2 (Base-Default), dann ArgoCD-Controller->1,
  CNPG-Backup-CronJobs entsuspenden.

### Phase 5b - SSD-Kaskade beim Rebuild (KRITISCHE LEHRE)

Beim Hochfahren der Rebuilds (Limit 0->1->2) trat das zentrale Problem zutage, das
auch den urspruenglichen Sturm ausgeloest hatte: **clusteruebergreifende IO-Saettigung
auf dem gemeinsamen SSD-Datastore.**

Beobachteter Verlauf:
- Rebuild-Verhalten auf k8s-test war zaeh: viele Volumes mit nur 1 Replica
  (`1 healthy / 1 total`), Rebuilds starteten nicht oder hingen. Ursache teils
  "Geister-Rebuilds": Replica-Objekte als rebuilding markiert, aber ohne echten
  Fortschritt (currentState ohne rebuildStatus), die die Rebuild-Slots (Limit=2)
  dauerhaft belegten. Fix: die haengenden, NICHT-healthy Replicas gezielt loeschen
  (healthyAt-gestempelte = Daten unbedingt behalten!), dann liefen die echten Rebuilds an.
- ABER: Sobald mehrere Rebuilds parallel liefen (v.a. die grossen Monitoring-Volumes
  prometheus ~20Gi, thanos ~30Gi - fast voll), saettigte die IO das gemeinsame Datastore.
- **Folge: k8s-dev (auf demselben Datastore) bekam dadurch selbst degraded Volumes und
  begann zu rebuilden** - exakt die Kaskade des Ur-Incidents.

Sofortmassnahme (durch Daniel live erkannt): **Rebuild-Limit auf BEIDEN Clustern
(test UND dev) sofort auf 0.** Laufende Rebuilds (nicht hart abbrechbar) liefen aus,
neue wurden verhindert. Verifiziert: keine weitere Eskalation, degraded-Zahlen stabil
(test ~5, dev 2). test `replica-replenishment-wait-interval` zurueck auf 600
(zusammen mit Limit=0 = sicherer Ruhezustand: selbst bei Replica-Ausfall kein Rebuild).

Hinweis actualSize>specSize: Ein WAL-Volume (cnpg-erp-1-wal) zeigte actual 6.3G > spec
5.4G. Hier UNKRITISCH (healthy, kein Rebuild) - actualSize zaehlt Snapshots+Head. Das
gefaehrliche Engine-Expansion-Bug (Longhorn KB, "file sizes are not equal" beim
Rebuild-Pruning) lag NICHT vor, da das Volume nicht rebuildete. Bei kuenftigen
Rebuild-Fehlern auf oversized Volumes aber im Blick behalten.

**Strategische Konsequenz (WICHTIG fuer PROD):**
- Rebuilds duerfen NIE auf mehreren Clustern gleichzeitig laufen, solange ein
  gemeinsames SSD-Datastore genutzt wird.
- Selbst Limit=1-2 pro Cluster kann das Datastore saettigen, wenn grosse, volle Volumes
  rebuilden. Redundanz-Wiederherstellung gehoert in eine Low-Traffic-Phase, Volume fuer
  Volume, mit Datastore-IO-Monitoring (iostat %util).
- Die Wiederherstellung der vollen 3-fach-Redundanz auf k8s-test ist daher ein
  EIGENES, geplantes Folgevorhaben - nicht Teil des Akut-Wiederanlaufs.
- Strukturelle Frage fuer die Zukunft: getrennte Datastores pro Cluster wuerden die
  clusteruebergreifende Kaskade strukturell ausschliessen (zu evaluieren).

### Endzustand des Akut-Wiederanlaufs (funktional vollstaendig)

- **k8s-test:** Alle Workloads laufen (CNPG erp/shared 3/3, Galera 3/3, Garage 3/3,
  Monitoring komplett, alle 7 Apps). Jedes Volume hat >=1 gesunde Replica (kein
  Datenverlust). Storage gedrosselt (Limit=0, wait=600). Teil der Volumes noch ohne
  volle Redundanz -> Folgevorhaben.
- **k8s-dev:** Laeuft, Limit=0, 2 Volumes degraded (Kollateral der heutigen Last,
  funktional intakt) -> in Folgevorhaben mit reparieren.
- **k8s-prod:** weiterhin abgeschaltet (separater Wiederanlauf spaeter).

---

## Temporaere Eingriffe - Ruecknahme-Liste (Stand Phase 5b)

| # | Eingriff | Soll-Zustand | Status |
|---|----------|--------------|--------|
| 1 | argocd-application-controller = 0 | 1 | OFFEN (zuletzt) |
| 2 | k8s-test Longhorn rebuild-limit = 0 | 2 | BEWUSST 0 (Ruhezustand, s. 5b); Folgevorhaben |
| 3 | cnpg-cloudnative-pg Operator = 0 | 1 | ERLEDIGT (Phase 3) |
| 4 | Galera suspend / STS=0 | suspend weg, STS 3 | ERLEDIGT (CR-Recreate) |
| 5 | forceClusterBootstrapInPod | nicht gesetzt | ERLEDIGT (entfernt) |
| 6 | Monitoring STS/CR = 0 | 1 | ERLEDIGT (Phase 4) |
| 7 | Garage STS = 0 | 3 | ERLEDIGT (Phase 4) |
| 8 | Apps = 0 (7 Deployments) | 1 | ERLEDIGT (Phase 4) |
| 9 | CNPG-Backup-CronJobs suspend | false | OFFEN |
| 10| Longhorn -22 allowScheduling=false | true | ERLEDIGT (Phase 5) |
| 11| Longhorn-Snapshot galera-1-pre-sst | (aufraeumen) | OFFEN (nach Stabilitaet) |
| 12| k8s-test replenishment-wait (war 30) | 600 | ERLEDIGT (Phase 5b zurueckgesetzt) |
| 13| k8s-DEV rebuild-limit = 0 (war 2) | 2 | BEWUSST 0 (Schutz Kaskade); im Folgevorhaben zurueck |

### Folgevorhaben "Redundanz-Wiederherstellung" (NEU, separat geplant)
- Ziel: alle k8s-test-Volumes auf volle 3-fach-Redundanz; k8s-dev 2 degraded reparieren.
- Methode: pro Volume Detach/Attach (Workload scale 0->1) ODER nicht-healthy Replica
  loeschen; Longhorn rebuildet von gesunder Quelle. Offiziell dokumentierter Weg.
- ZWINGEND: nur EIN Cluster aktiv, Limit=1, Datastore-iostat beobachten, Low-Traffic.
- Danach beide Cluster Limit zurueck auf 2, ArgoCD-Controller test ->1,
  CNPG-Backup-CronJobs entsuspenden, Snapshot galera-1-pre-sst aufraeumen.

---

## Zentrale Lehren (fuer PROD-Wiederanlauf besonders relevant)

1. **Bremsen vor Last:** ArgoCD-Controller=0 + Rebuild-Limit=0 direkt nach etcd-Quorum.
   Ohne ArgoCD-Reconcile lassen sich alle weiteren Stilllegungen ArgoCD-sicher setzen.

2. **Cordon = Doppelfalle:** Hindert auch Longhorn-DaemonSets. Erst Workloads stilllegen,
   dann node-weise uncordonen, damit Longhorn-System isoliert hochkommt.

3. **Operator-Workloads korrekt stilllegen:** Nicht STS-Scale (Operator dreht zurueck),
   sondern Operator-Scale / CR-replicas / suspend. CNPG `instances:0` ist verboten (>=1)
   -> Operator-Scale-to-0 stattdessen.

4. **CNPG-Cold-Start unkritisch bei sauberem Stop:** Selbst uebergelaufenes Replica-WAL
   (118%) ist OK, solange der Primary leeres WAL hat. Primaries starten zuerst, Replicas
   syncen nach. (Anders als DEV-Crash-Deadlock.)

5. **Galera-Recovery - der heikelste Teil:**
   - Operator waehlt Bootstrap nach `safe_to_bootstrap`-Flag, NICHT zuverlaessig nach
     hoechster seqno - kann divergierten/leeren Node waehlen.
   - Echten Bootstrap-Node selbst bestimmen: GCache-Logs der Pods vergleichen
     (`found gapless sequence X-Y`, `Synced: 1`, gemeinsame UUID = gute Daten).
   - `forceClusterBootstrapInPod: <node>` ist der offizielle Hebel - aber er greift nur,
     wenn der Operator NOCH KEINEN Bootstrap gewaehlt hat. Bei bereits gewaehltem Bootstrap
     zusaetzlich `status.galeraRecovery.bootstrap=null` patchen (NUR bootstrap, NICHT den
     ganzen galeraRecovery-Status - das bringt den Operator in eine Sackgasse).
   - Robustester Reset: MariaDB-CR loeschen (PVCs bleiben, OwnerRef pruefen!) + neu anwenden.
   - Nach Erfolg: forceClusterBootstrapInPod ZWINGEND wieder entfernen.
   - Vorher Longhorn-Snapshot des guten Datentraegers als Netz.

6. **replicaReplenishmentWaitInterval=600 wirkt in beide Richtungen:** Schuetzt beim
   Hochfahren (kein voreiliges Rebuild), verzoegert aber auch die gewollten Rebuilds im
   Storage-Finale um bis zu 10 min. Bei Limit=1 unkritisch - Geduld statt Eingriff.

7. **Wiederanlauf zog sich ueber Nacht** (Start 29.06. ~16:30, Storage-Finale 30.06.).
   Der zaehe Galera-Recovery war der Hauptzeitfresser. Fuer PROD entsprechend Zeit einplanen.

8. **SSD-KASKADE - die wichtigste Lehre (s. Phase 5b):** Das gemeinsame SSD-Datastore
   ist der eigentliche Flaschenhals. Rebuild-Last auf EINEM Cluster destabilisiert die
   ANDEREN (test-Rebuilds -> dev wurde degraded). Das ist die Wurzel des Ur-Sturms.
   - Rebuilds NIE clusteruebergreifend parallel. Immer nur ein Cluster aktiv rebuilden.
   - Limit=0 stoppt NEUE Rebuilds sofort; laufende sind nicht hart abbrechbar (laufen aus).
   - "Geister-Rebuilds" (rebuilding-markiert ohne Fortschritt) blockieren Slots -> die
     nicht-healthy Replica loeschen (healthyAt-Replica niemals!).
   - Redundanz-Wiederherstellung = eigenes Vorhaben, Low-Traffic, ein Volume nach dem
     anderen, iostat %util im Blick.
   - Strukturell zu evaluieren: getrennte Datastores pro Cluster.

9. **robustness=healthy != volle Redundanz:** Ein Volume kann "healthy" anzeigen und doch
   nur 1 von 3 Replicas haben (wenn die eine laeuft). Echte Redundanz nur ueber
   Zaehlung der healthyAt-gestempelten Replicas pro Volume pruefbar, nicht ueber die
   robustness-Spalte allein.

---

## Status bei Doku-Erstellung

- k8s-test Nodes: 3 Ready+Schedulable
- CNPG erp + shared: 3/3 healthy
- Galera: 3/3 healthy
- Garage: 3/3
- Monitoring: komplett Running
- Apps: alle 7 Running
- Storage k8s-test: Limit=0 + wait=600 (bewusster Ruhezustand nach SSD-Kaskade, s. 5b).
  Teil der Volumes voll redundant, Rest mit 1 Replica (funktional, kein Datenverlust).
- Storage k8s-dev: Limit=0, 2 Volumes degraded (Kollateral). Beide -> Folgevorhaben.
- Offen (Folgevorhaben "Redundanz-Wiederherstellung", separat, Low-Traffic):
  pro Volume Rebuild (ein Cluster aktiv, Limit=1, iostat) -> dann beide Limit->2,
  ArgoCD-Controller test->1, CronJobs entsuspenden, Snapshot galera-1-pre-sst aufraeumen.

**Strikt getrennt** vom DEV-Backport (Phase 13/14, WAL-Haertung) - das ist ein eigenes
Vorhaben nach stabilem TEST-Anlauf.
