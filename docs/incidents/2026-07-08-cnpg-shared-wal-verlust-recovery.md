# Incident: cnpg-shared PROD - x509 + WAL-Archivierung nach Neu-Init (2026-07-08)

**Status:** abgeschlossen am 2026-07-08 ca. 19:50 MESZ
**Umgebung:** k8s-prod (k8s-prod-21/22/23, K3s v1.35.1)
**Schweregrad:** hoch - Shared-DB ohne HA und ohne Backup, aber Primary durchgehend
lese-/schreibfaehig (kein Datenverlust)

## Betroffener Workload

- **cnpg-shared** (PostgreSQL 17.9, CloudNativePG v1.28.3, Barman Cloud Plugin
  v0.11.0), Namespace `databases`. Traegt die Rollen n8n, keycloak, it_info_versand.

## Ausgangslage (Stand Sessionbeginn 08.07.)

cnpg-shared war am 08.07. ~11:29 per initdb neu aufgesetzt worden (neue System-ID
`7660117729400840211`, Timeline 1). Der Primary `cnpg-shared-1` lief (2/2, ~288M
Daten, lesen/schreiben OK). Zwei blockierende Probleme:

### Problem 1 - WAL-Archivierung FAILING

- `ContinuousArchiving: False`, `unexpected failure invoking
  barman-cloud-wal-archive: exit status 1`, Stau ab `000000010000000000000001`.
- Ursache: stale S3-Prefix. Der ObjectStore `cnpg-shared-objectstore`
  (`destinationPath s3://k8s-prod-postgres-wal/cnpg-shared/`, serverName implizit
  = Clustername) enthielt noch Alt-Backups eines frueheren cnpg-shared (26.04.-
  08.05.2026). Der neu initialisierte Cluster (neue System-ID, Timeline 1)
  kollidierte beim Archivieren mit dieser Alt-Historie.
- Folge: kein Backup fuer cnpg-shared.

### Problem 2 - nur 1/3 Instanzen + x509

- `spec.instances=3`, aber `readyInstances=1`. Nur PVCs cnpg-shared-1 / -1-wal.
- Operator-Phase: "Instance Status Extraction Error: HTTP communication issue".
  Operator-Log durchgehend: `Get "https://<pod-ip>:8000/pg/status": tls: failed to
  verify certificate: x509: certificate signed by unknown authority` (candidate
  authority "cnpg-shared").
- Ursache: Das Server-Zertifikat des laufenden Pods stammte aus einer frueheren
  CA-Generation der Re-Init-Sequenz und passte nicht zur aktuellen CA im Secret
  `cnpg-shared-ca`. Der Operator konnte keinen Status extrahieren -> kein Scale-up
  auf -2/-3.

## Diagnose (frisch verifiziert)

- Cluster-Spec: plugins mit `barmanObjectName cnpg-shared-objectstore`, kein
  expliziter serverName -> impliziter serverName = cnpg-shared (Kollisionspfad).
- Secret-Chronologie: `cnpg-shared-server` erstellt 11:22:11, `cnpg-shared-ca`
  erstellt 11:22:14 (CA 3s nach Server-Zert). Cluster-Neu-Init ~11:29,
  Pod-Restart ~11:43 - der Pod hielt ein Server-Zert, das nicht zur finalen CA
  passte.
- ObjectStore-Status zeigte `serverRecoveryWindow` fuer serverName cnpg-shared mit
  Alt-Backups 04-05/2026 (Bestaetigung stale Prefix).
- Rescue-PVCs (cnpg-shared-rescue-data, -rescue-dump) als fremde Absicherung
  identifiziert und durchgehend NICHT angefasst.

## Sanierungsschritte (chronologisch)

Reihenfolge bewusst: erst TLS (Problem 2), dann WAL (Problem 1). Begruendung:
Ohne Status-Extraction reconciled der Operator den Cluster nicht sauber (kein
Scale-up, verzoegerte Plugin-Reaktion). Sauberer TLS-Zustand ist Voraussetzung.

### Schritt A - TLS heilen (Problem 2), minimalinvasiv

1. Secret `cnpg-shared-server` per kubectl geloescht (Kubernetes MCP,
   context=k8s-prod). Owner-Reference = Cluster -> Operator regeneriert sofort.
2. Operator stellte `cnpg-shared-server` um 14:16:54 gegen die aktuelle CA neu aus
   (neue uid, resourceVersion 24102713). KEIN Pod-Restart von -1 noetig - der
   Instance-Manager uebernahm das projizierte Zert.
3. Zeitgleich (14:16:54) begann der Operator zu reconcilen: Status-Extraction OK
   -> `cnpg-shared-2-join` -> PVCs cnpg-shared-2/-2-wal -> Pod -2 (k8s-prod-23),
   danach -3 (k8s-prod-22).
4. Ergebnis 14:18:24: 3/3 healthy, `ConsistentSystemID: True`, `Ready: True`,
   sauber ueber 3 Nodes verteilt, Timeline 1.

### Schritt B - WAL-Archivierung heilen (Problem 1), kollisionsfreier serverName

Analog zur cnpg-erp-Recovery (frischer serverName statt Loeschen des Alt-Archivs):

1. File-Edit in `kubernetes/environments/prod/cnpg-cluster/cnpg-shared.yaml`:
   plugins.parameters um `serverName: cnpg-shared-v2` ergaenzt (mit Kommentar).
   Alt-Historie unter serverName cnpg-shared bleibt als Netz erhalten.
2. git commit + push (Daniel).
3. ArgoCD Hard-Refresh (Annotation per kubectl) + `argocd app sync cnpg-cluster`
   (Daniel). Hard-Refresh noetig, damit die Plugin-Sub-Map als Diff materialisiert
   (bekanntes Verhalten bei Sub-Maps).
4. Live-Spec uebernahm serverName cnpg-shared-v2 (generation 2). Neuer
   Archiv-Pfad: `s3://k8s-prod-postgres-wal/cnpg-shared/cnpg-shared-v2/`.
5. `ContinuousArchiving: True` ("Continuous archiving is working") ab 14:24:03.

### Schritt C - erstes Base-Backup

1. On-Demand-Backup (Backup-CR, method plugin, barman-cloud) per kubectl apply.
2. `phase: completed` (backupId 20260708T174720), ausgefuehrt vom Replica
   cnpg-shared-2, online, Timeline 1. Cluster damit PITR-faehig
   (Base-Backup + laufende WAL-Archivierung).

## Endzustand (verifiziert 2026-07-08 ~19:50)

- cnpg-shared: **3/3**, "Cluster in healthy state", Primary cnpg-shared-1
  (+ -2, -3), Timeline 1, System-ID 7660117729400840211
- ConsistentSystemID: True, Ready: True, ContinuousArchiving: True
- Erstes Backup unter cnpg-shared-v2: completed (20260708T174720)
- ArgoCD: cnpg-shared Synced/Healthy (Revision d163964); cnpg-shared-objectstore
  und cnpg-shared-full (ScheduledBackup) Synced
- Rescue-PVCs unangetastet

## Lessons Learned

- **LL-1: Nach initdb-Neu-Init kann ein Pod ein Server-Zert aus einer frueheren
  CA-Generation halten.** Symptom: Operator-x509 "signed by unknown authority
  <cluster>" beim :8000/pg/status-Abruf, Status-Extraction-Error, Scale-up
  blockiert. Fix minimalinvasiv: Secret `<cluster>-server` loeschen -> Operator
  regeneriert gegen aktuelle CA, Instance-Manager laedt neu (i.d.R. ohne
  Pod-Restart). CA/Replication-Secrets erst anfassen, wenn das nicht reicht.
- **LL-2: TLS vor WAL.** Ohne Status-Extraction reconciled der Operator nicht
  sauber. Erst TLS heilen, dann Archivierung/Replicas - sonst Symptombehandlung.
- **LL-3: Stale S3-Prefix nach Cluster-Neuaufsatz -> frischer serverName statt
  Loeschen.** serverName-vN (hier cnpg-shared-v2) vermeidet Kollision mit der
  Alt-Historie und behaelt sie als Netz. Gleiche Loesung wie bei cnpg-erp
  (serverName cnpg-erp-v2). Archiv liegt verschachtelt unter
  destinationPath/serverName/.
- **LL-4: Plugin-Sub-Map-Aenderungen brauchen ArgoCD Hard-Refresh**, damit der
  Diff (hier serverName in plugins.parameters) ueberhaupt materialisiert.

## Offene Punkte / Follow-ups

- **cnpg-erp bleibt kosmetisch OutOfSync** in der App cnpg-cluster (bootstrap
  immutable, Operator normalisiert Felder; autoHealAttemptsCount hoch). Kein
  Handlungsbedarf, betrifft nicht cnpg-shared.
- **Alte cnpg-shared-Historie (serverName cnpg-shared, 04-05/2026)** verbleibt im
  Bucket als Netz. Cleanup optional zu einem spaeteren Zeitpunkt (QNAP-GUI).
- **Rescue-PVCs** (cnpg-shared-rescue-data, -rescue-dump) weiterhin aufheben, bis
  der neue Stand ausreichend erprobt ist; danach separat abraeumen.
- Einordnung in die uebergreifende PROD-Reaktivierung: cnpg-shared-Recovery
  abgeschlossen; offene Reaktivierungspunkte (i-doit Auto-Sync, abhaengige Apps)
  laufen getrennt weiter.
