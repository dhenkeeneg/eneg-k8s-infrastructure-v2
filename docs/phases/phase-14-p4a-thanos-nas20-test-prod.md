# P4a: Thanos S3-Migration NAS10 -> NAS20 (TEST + PROD)

**Status:** VOLLSTAENDIG ABGESCHLOSSEN (TEST + PROD, 16.07.2026).
**Kontext:** Drift-Angleich DEV -> TEST/PROD, Prioritaet P4a (nur Thanos).
**Scope-Entscheidung:** OF-8 = P4a ausschliesslich Thanos. P4b (CNPG-backup,
MariaDB-physical, Garage, Odoo, i-doit NAS10->NAS20) folgt separat.
**Bearbeiter:** Daniel Henke
**Vorlage:** Phase 14 (Loki 14b TEST + Thanos 14a DEV), erprobtes CA-Bundle-Muster.

---

## 1. Ausgangslage (verifiziert 16.07.2026)

| Cluster | endpoint | insecure | ca_file | CA-Mounts | bucket |
|---------|----------|----------|---------|-----------|--------|
| DEV  | nas20:8010 | false | gesetzt | compactor+storegateway+sidecar | k8s-dev-thanos |
| TEST | nas10:8010 | true  | -       | keine | k8s-test-thanos |
| PROD | nas10:8010 | true  | -       | keine | k8s-prod-thanos |

Thanos-Komponenten je Cluster identisch: Deployment/thanos-compactor,
Deployment/thanos-query, StatefulSet/thanos-storegateway (v0.39.2) +
Thanos-Sidecar im Prometheus-Pod (kube-prometheus-stack thanos.enabled).

**Wichtiger Vereinfacher:** CA-Bundle-Secret `eneg-s3-ca` (NS monitoring,
Sectigo R36+R46) existiert in TEST (seit 06.07.) und PROD (seit 07.07.) BEREITS
- angelegt durch die Loki-Migration (tracking-id loki-secrets). Thanos referenziert
es nur als Mount (verwaltet es nicht). Kein neues Secret/Template noetig - exakt
wie in DEV, wo Loki + Thanos dasselbe eneg-s3-ca teilen.

## 2. Datenstrategie-Entscheidung

Anders als Loki 14b (Clean Cutover ohne Datenkopie) wurde fuer Thanos entschieden:
**Bloecke NAS10 -> NAS20 kopieren** (volle Historie erhalten), mit Compactor-Pause
waehrend der Kopie. Grund: Thanos haelt die Langzeit-Historie; ein Clean Cutover
haette die Historie ueber den 15d-Sidecar-Horizont hinaus verloren.

## 3. Split-Brain-sichere Schrittfolge (TEST, durchgefuehrt 16.07.2026)

Sidecar, Compactor, Storegateway und Query nutzen alle dasselbe
thanos-objstore-config Secret. Sobald es auf NAS20 zeigt, brauchen alle
gleichzeitig den CA-Mount, sonst x509. Daher:

**Phase (a) - Compactor pausieren:**
- `compactor.enabled: false` in environments/test/monitoring-thanos/values-override.yaml.
- **LEHRE:** `compactor.replicaCount: 0` greift beim bitnami-Chart NICHT (Compactor
  ist Singleton, Template zieht Replicas nicht aus diesem Value). Der erste Versuch
  mit replicaCount blieb wirkungslos (Deployment blieb 1/1). `enabled: false` ist
  der wirksame Schalter - entfernt Deployment + PVC (ArgoCD prune).
- Verifiziert: Compactor-Deployment + Pod entfernt, query + storegateway laufen
  weiter (Lesen von NAS10, kein Monitoring-Ausfall).

**Phase (b) - Datenkopie NAS10 -> NAS20:**
- rclone copy k8s-test-thanos NAS10 -> NAS20, Bloecke immutable.
- Storegateway/Query lesen waehrenddessen weiter von NAS10 (kein Ausfall).
- size-Werte NAS10 ~= NAS20 verifiziert.

**Phase (c) - Cutover (Secret + alle Mounts + Compactor reaktiviert):**
- thanos-objstore-config.yaml.template: endpoint nas20, insecure:false,
  http_config.tls_config.ca_file:/etc/ca/ca.crt.
- monitoring-thanos/values-override.yaml: CA-Mount (eneg-s3-ca -> /etc/ca) an
  compactor + storegateway, enabled:false entfernt (Compactor wieder aktiv).
- monitoring/values-override.yaml: prometheusSpec.volumes (s3-ca) +
  thanos.volumeMounts (/etc/ca) fuer den Sidecar.
- SOPS-Verschluesselung auf mgmt-10, Secret-first-Sync-Reihenfolge.

**Phase (d) - Rollout + Verifikation:**
- monitoring-secrets zuerst syncen, Secret-resourceVersion-Anstieg verifiziert.
- thanos + monitoring syncen (Hard-Refresh, Helm-Sub-Map).
- Pod-Neustarts: storegateway + compactor (Secret als Volume, Config nur bei
  Start gelesen -> Neustart noetig).

## 4. Stolpersteine (TEST, 16.07.2026)

**S1 - replicaCount wirkungslos (s.o. Phase a):** Compactor-Pause nur ueber
`enabled: false` moeglich, nicht replicaCount. Fuer PROD direkt enabled:false nutzen.

**S2 - ArgoCD "Synced" ohne echten Apply:** Mehrfach zeigte eine App nach
Hard-Refresh-Annotation `Synced` gegen den neuen Commit, ohne den Sync tatsaechlich
ausgefuehrt zu haben (operationState/history noch auf altem Commit). Loesung:
expliziter Sync (UI/CLI), Annotation allein genuegt nicht. Bei kubectl/argocd CLI
IMMER --context k8s-{env} angeben.

**S3 - falscher secret_key (analog Loki 14b InvalidAccessKeyId):** Erster
Cutover-Versuch: Storegateway TLS OK (kein x509 - CA-Mount griff), aber
"The AWS Access Key Id you provided does not exist in our records". Ursache:
falscher secret_key im Secret. Korrektur via sops decrypt->tmp->edit->encrypt->rm.
Access-Key-Format NAS20: `s3-k8s-test:<key>` (User-Prefix, wie Loki-TEST).
LEHRE: Access-Key-Teil muss mit funktionierendem loki-s3-credentials (selber
NAS20-User) uebereinstimmen - vor Cutover abgleichen.

**S4 - Push-Problem:** Reaktivierungs-Commit fehlte zunaechst auf origin (Push
schlug fehl). thanos-App synchronisierte gegen alten Commit (Compactor noch
enabled:false, tauchte nicht im syncResult auf). Nach erneutem Push + Hard-Refresh
korrekt. LEHRE: nach jedem Sync pruefen, ob die erwarteten Ressourcen im
syncResult erscheinen.

## 5. Verifikation TEST (16.07.2026)

- **Storegateway:** 15 Bloecke von NAS20 geladen, "bucket store ready" in 1,88s,
  status=ready, kein x509/AccessKey-Fehler.
- **Compactor:** laeuft gegen NAS20, Cleanup-Zyklus (aborted partial uploads +
  blocks marked for deletion) sauber abgeschlossen, ready.
- **Prometheus-Sidecar:** CA-Volume (s3-ca) im Pod gemountet, ready, kein x509.
  Upload nach NAS20 beim naechsten regulaeren 2h-Block-Cut (Admin-API deaktiviert,
  manueller Block-Cut bewusst nicht erzwungen). Upload-Pfad logisch verifiziert
  (identische objstore-Config wie Storegateway, der nachweislich NAS20 liest).
- **Query:** Storegateway als Store uebernommen (endpointset "adding new store"),
  NAS20-Historie abfragbar.
- Alle Pods 1/1, thanos-App Synced/Healthy.

## 6. Offener Nebenbefund (NICHT P4a - fuer spaeter dokumentiert)

**Thanos-Query Sidecar-Discovery greift ins Leere (alle drei Cluster):**
base/monitoring/thanos/values.yaml konfiguriert
`query.dnsDiscovery.sidecarsService: kube-prometheus-stack-thanos-discovery`.
Dieser Service existiert in KEINEM der drei Cluster (DEV/TEST/PROD verifiziert) -
der reale headless-Service heisst `prometheus-operated` (Port 10901/gRPC).
Folge: Query findet den Sidecar-Store nicht ueber DNS-SRV
(`failed to lookup SRV records ... no such host`), bezieht die Historie aber
vollstaendig ueber den Storegateway. Die jeweils aktuellsten ~2h (nur im Sidecar
vor Upload) sind in Query nicht direkt sichtbar.
- **Charakter:** vorbestehend, cluster-uebergreifend, migrations-unabhaengig
  (nichts mit NAS10/NAS20 zu tun).
- **Scope:** NICHT Teil von P4a (OF-8). Eigener Fix in separatem Chat:
  sidecarsService auf `prometheus-operated` korrigieren (base-Change, wirkt alle
  drei Cluster), dann Query-Neustart. Vorher pruefen, ob prometheus-operated die
  gRPC-Endpoints (10901) mit passenden SRV-Records liefert.

## 7. PROD (14c-analog) - ABGESCHLOSSEN 16.07.2026

Gleiche Schrittfolge mit prod-Overlays, bucket k8s-prod-thanos, eneg-s3-ca in
PROD bereits vorhanden (Loki-Migration 07.07.). prod-infrastructure ohne Auto-Sync
-> Child-Apps aktiv gesynct.

**Ablauf (ohne Stolpersteine - TEST-Lehren griffen):**
- Phase (a): compactor.enabled:false -> Compactor-Deployment+Pod entfernt (Sync
  griff direkt, kein "Synced-ohne-Apply").
- Phase (b): rclone-Kopie k8s-prod-thanos NAS10->NAS20, size-Werte plausibel gleich.
- Phase (c): Template (nas20/insecure:false/ca_file) + CA-Mounts (compactor/
  storegateway/sidecar) + Compactor reaktiviert; secret_key diesmal korrekt
  (Access-Key s3-k8s-prod:<key>, mit loki-s3-credentials abgeglichen -> KEIN
  InvalidAccessKeyId). Secret-first: monitoring-secrets zuerst, App-Sync real
  verifiziert (operationState synced-rev == compared-rev, finishedAt aktuell).
- Phase (d): thanos + monitoring gesynct. Verifiziert: Storegateway laedt 9 Bloecke
  von NAS20 (ready in 9,5s, kein x509), Compactor Cleanup sauber + regelmaessige
  Metadata-Syncs (returned=47), Sidecar ready mit CA-Mount (kein x509, Upload beim
  naechsten 2h-Cut), Query laeuft. Alle Pods 1/1 stabil.

**Nebenbefund (identisch zu TEST):** Query sidecarsService-Discovery greift auch
in PROD ins Leere (real: prometheus-operated:10901) - Historie via Storegateway,
migrations-unabhaengig, eigener base-Fix spaeter.

## 8. Status P4a gesamt

- **TEST:** erledigt 16.07.2026.
- **PROD:** erledigt 16.07.2026.
- **P4a damit VOLLSTAENDIG.** Alle drei Cluster (DEV/TEST/PROD) Thanos auf NAS20.
- Offen: P4b (CNPG-backup, MariaDB-physical, Garage, Odoo, i-doit NAS10->NAS20,
  separater Chat), Query-Discovery-Fix (base, separater Chat), Sidecar-Upload-
  Bestaetigung am NAS20-Bucket beim naechsten 2h-Cut (TEST + PROD).
