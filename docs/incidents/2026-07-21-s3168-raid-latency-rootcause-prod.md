# Incident: Root-Cause s3168 RAID-Latenz -> Virt-Resets -> Longhorn-Faults k8s-prod-23 (2026-07-21)

**Status:** Root Cause identifiziert und per perccli verifiziert (Diagnose abgeschlossen). Erste gering-invasive Massnahme umgesetzt (Patrol Read auf SSDs deaktiviert, 21.07.). Weitere Massnahmen in Abstimmung.
**Umgebung:** k8s-prod (k8s-prod-23 auf ESXi s3168.eneg.de), PERC H755 Front, ESXi 8.0.3 build-24784735
**Schweregrad:** mittel — kein Datenverlust, aber wiederkehrende Rebuild-Wellen und Storage-Latenzspitzen auf Produktiv-Node.
**Vorlaeufer:** `docs/incidents/2026-07-13-s3168-io-stall-longhorn-faults-prod.md` (dort war die vSphere-/Storage-Ursache als offen markiert; dieses Dokument loest sie auf).

## Zusammenfassung

Die am 13.07. offen gebliebene Storage-Ursache auf ESXi s3168 wurde ueber eine
dreistufige Diagnose (Hardware/iDRAC-Redfish + racadm, Hypervisor/esxtop+vmkernel.log,
Kubernetes/Longhorn) sowie eine 3-Host-Gegenprobe geklaert.

Kernbefund: Es liegt **kein einzelner Hardwaredefekt** vor (Controller, BBU, Firmware,
einzelne SMART-auffaellige Platte alle ausgeschlossen). Die Virt-Resets sind das
Ergebnis **sporadischer Latenz-Spitzen** auf zwei Virtual Disks des PERC H755, die
unter Last (inkl. dauerlaufendem Patrol Read) die Command-Timeout-Schwelle des
Controllers ueberschreiten. ESXi setzt daraufhin device-level Virt-Resets ab; die auf
k8s-prod-23 liegenden Longhorn-Replicas laufen dabei in den Fault -> Rebuild-Wellen
(= das am 13.07. beobachtete Symptom).

## Betroffene Virtual Disks (PERC H755, Controller RAID.SL.3-1)

| VD  | Name              | Layout | ESXi-Target | naa (Kurz) | Virt-Resets/24h |
|-----|-------------------|--------|-------------|------------|-----------------|
| 237 | D07-D15_R6_HDD    | RAID6  | T109        | ...2e2d1ac | ~1984 (81%)     |
| 238 | D02-D05_R10_SSD   | RAID10 | T110        | ...a63fa7  | ~544 (18%)      |
| 239 | D00-D01_R1_BOOT   | RAID1  | T111        | ...857a3f66| ~24 (1%)        |

k8s-prod-23 liegt auf **VD238 (D02-D05_R10_SSD)**. Die dortigen Resets loesen die
Longhorn-Fault-Wellen aus. VD237 (HDD) hat zwar mehr Resets, traegt aber keine
k8s-prod-23-Volumes.

## Ursachenkette (dreistufig belegt)

### Ebene 1 — Hardware (iDRAC-Redfish + racadm)

- Controller PERC H755, FW **52.30.0-6115** = aktueller/empfohlener Dell-Stand
  (kein Update verfuegbar, kein bekannter H755-Bug fuer diese Version).
- Controller-Health, Cache (8192 MB, ProtectedWriteBack) und **BBU: alle OK**.
  -> Controller-/BBU-/Cache-Defekt ausgeschlossen.
- Alle aktiven Platten (Bay 2-5 SSD, Bay 6/8-15 HDD): `Online/OK`, `SmartAlertAbsent`,
  keine PredictiveFailure. -> sterbende Einzelplatte per SMART nicht nachweisbar.
- **Bay 7**: `Foreign / Warning / StandbyOffline`, aber `FailurePredicted: false`.
  Gesunde Platte mit Fremd-Metadaten (nicht Member des aktiven RAID6). Wird wegen
  `PatrolReadUnconfiguredArea = Enabled` bei jedem Patrol Read mitgescannt.
- RAID6-Verbund ist **gemischt bestueckt**: Bay 6 = TOSHIBA AL15SEB24EQY (Bj. 2023),
  Bay 8-15 = SEAGATE BL2400MM0159 (Bj. 2025). Bay 6 ist die einzige technisch
  abweichende Platte (anderer Hersteller/Firmware/Alter) -> Hauptverdaechtiger fuer
  die HDD-Latenzspitzen, aber per Redfish/racadm nicht abschliessend verifizierbar
  (Media/Other-Error-Zaehler in dieser iDRAC-FW nicht exponiert -> perccli noetig).

### Ebene 2 — Hypervisor (esxtop + vmkernel.log)

- vmkernel.log: ausschliesslich **device-level Virt-Resets** (mfi_TaskMgmt/mfi_VirtReset
  auf einzelne Targets), **kein** Controller-Hard-Reset (mfi_HardReset/adapter reset/
  FW-Fault) -> Controller-weiter Reset ausgeschlossen.
- Reset-Verteilung stark ungleich (T109 >> T110 >> T111) -> kein controllerweites Problem.
- Reset-Haeufigkeit rund um die Uhr, keine Tag/Nacht-Korrelation mit Nutzerlast.
- **Latenz-Beweis (esxtop-Sampling):**
  - VD238 (SSD, k8s-prod-23): meist ~0,04 ms DAVG, aber Spike bis **810 ms DAVG /
    1379 ms GAVG** (20.07. 13:05:51). DAVG (Disk-HW), nicht KAVG (Queue) -> physische
    SSD-Latenz, kein ESXi-Queue-Problem.
  - VD237 (HDD): Median ~0,65 ms DAVG, aber Spike bis **14350 ms DAVG (14 s!) /
    QAVG 559568 ms** (20.07. 15:22:16) bei quasi Leerlast (3 cmd/s). -> einzelne Platte
    haengt sporadisch, KEIN Ueberlast-/Queue-Saturationsproblem (QAVG normalerweise 0).

### Ebene 3 — Kubernetes (Longhorn)

- Fault-/Rebuild-Wellen **ausschliesslich auf k8s-prod-23** (instance-manager
  10.42.2.199). k8s-prod-21/22 seit Tagen/Wochen stabil (kein Rebuild).
- Betroffene Volumes = die Dauer-Schreiber: Prometheus TSDB, Loki, garage-meta-0/2,
  Grafana. Ruhende Volumes bemerken die kurzen Resets nicht.
- Kausalitaet bestaetigt: Longhorn ist **Symptomtraeger**, nicht Ursache. Die
  Rebuild-Last verschaerft die SSD-Latenz zusaetzlich (Teufelskreis).

## 3-Host-Gegenprobe (RAID-Level-Hypothese)

Alle drei PROD-Hosts: identischer PERC H755, identische WD-Red-SA500-SSD-Modelle,
identischer ESXi-Build, durch gleichmaessige Longhorn-Verteilung praktisch identisches
Workload-Profil. Einziger Unterschied: RAID-Level des SSD-Volumes.

| Host   | Node       | SSD-Layout | Virt-Resets/24h | Longhorn-Rebuilds |
|--------|------------|------------|-----------------|-------------------|
| S2842  | k8s-prod-21| RAID1      | **0**           | keine (stabil)    |
| S2843  | k8s-prod-22| RAID1      | **0**           | keine (stabil)    |
| S3168  | k8s-prod-23| **RAID10** | **544**         | mehrmals taeglich |

Schlussfolgerung: RAID10 ist der ausloesende Unterschied — nicht weil RAID10 "schlechter"
ist, sondern weil 4 statt 2 Consumer-SSDs die Wahrscheinlichkeit eines Latenz-Spikes je
Stripe-Write erhoehen und (vermutlich) mehr aggregierte Last auf dem grossen Volume liegt.
RAID1 maskiert das SSD-Grundproblem (Consumer-SSD ohne PLP), RAID10 hebt es ueber die
Timeout-Schwelle.

## Patrol-Read-Analyse (Dauer-Verstaerker)

- Konfiguration (Werksdefault, unveraendert): alle Hintergrundraten = **30%**
  (PatrolRead, Rebuild, BGI, CheckConsistency, Reconstruct). PatrolReadMode=Automatic
  (woechentlich, Start Fr ~05:02). `PatrolReadUnconfiguredArea = Enabled`.
- Patrol-Read-Historie (aus LCL via racadm):
  - 04.07 05:02 -> 07.07 23:54 (~3 T 19 h)
  - 11.07 05:02 -> 15.07 12:20 (~4 T 07 h)
  - 18.07 05:02 -> 21.07 10:30 (~3 T 05 h)
- Dauer konstant hoch (3-4 Tage), **nicht zunehmend** -> spricht eher fuer strukturell
  langsam (30%-Rate + Kapazitaet + Dauerlast + Mitscan der Foreign-Bay-7) als fuer eine
  zunehmend sterbende Platte.
- Effekt: Patrol Read laeuft ~3-4 von 7 Tagen, legt also fast durchgehend Zusatzlast auf
  beide grenzwertigen Verbuende -> erklaert das "rund um die Uhr"-Reset-Muster.
- Disk-Reset Bay 5 (SSD) am 17.07 02:25 fiel in einen laufenden Patrol Read.

## Ausgeschlossene Ursachen (Zusammenfassung)

- Controller-Defekt (iDRAC OK, kein HardReset im vmkernel.log)
- BBU-/Cache-Defekt (Health OK, ProtectedWriteBack aktiv)
- Firmware-Bug (52.30.0-6115 aktuell, kein bekannter H755-Bug)
- Einzelne SMART-auffaellige Platte (alle SmartAlertAbsent)
- Degradiertes/nicht-redundantes RAID (alle VDs Health OK)
- Slot 7 als aktiver Bus-Stoerer (perccli: Slot 7 = Dedicated Hot Spare, KEIN
  Foreign, Seagate BL2400MM0159, alle Fehlerzaehler 0; bedient keine reg. I/Os)
- RAID6-Ueberlast/Queue-Saturation (QAVG=0, Spike bei Leerlast)
- Platten-Fehlerakkumulation (perccli /eall/sall: alle 16 PD Media/Other/Predictive/
  Shield-Counter = 0, S.M.A.R.T alert = No, Temp 28-35C)

## Root Cause (Fazit)

Zwei getrennte, strukturelle Probleme auf s3168, verstaerkt durch den Dauer-Patrol-Read:

1. **VD238 SSD-RAID10 (k8s-prod-23):** WD Red SA500 = Consumer-SATA-SSD ohne
   Power-Loss-Protection. Unter fsync-Dauerlast (PostgreSQL-WAL, MariaDB-Galera, Loki,
   Prometheus, Garage) Latenz-Spikes bis 810 ms -> Command-Timeout -> Virt-Reset ->
   Longhorn-Fault-Welle. RAID10 (4 SSDs) verstaerkt vs. RAID1 (Gegenprobe: 0 Resets).

2. **VD237 HDD-RAID6:** Sporadischer 14-s-Latenz-Haenger einer Einzelplatte bei
   Leerlast. Leicht heterogener Verbund: Slot 6 (Toshiba AL15SEB24EQY, Bj. 2023, FW EF09)
   ist die einzige nicht-Seagate-Platte gegenueber den homogenen Seagate BL2400MM0159
   (Slot 8-15, FW SBSA). perccli bestaetigt: Toshiba ist aktives RAID6-Member
   (DriveGroup:0, Row:8), alle Fehlerzaehler 0. WICHTIG: Sektorformat ist NICHT
   abweichend - Toshiba und Seagate sind beide Logical 512B / Physical 4 KB (512e),
   verifiziert via perccli. Damit bleibt als Unterschied nur Modell/Hersteller, FW und
   Baujahr. -> Verdacht auf die Toshiba ist SCHWACH und nicht durch harte Fakten belegt;
   der 14-s-Haenger ist aktuell KEINER Einzelplatte eindeutig zuzuordnen (alle Zaehler 0,
   keine Sektor-Heterogenitaet).

## perccli-Verifikation (21.07., nach s3168-Reboot aufgeloest)

perccli 007.3208.0000.0000-02 ist nach dem s3168-Reboot aktiv (Komponente Status
`host`). Binary-Pfad: **`/opt/perccli/bin/perccli64`** (nicht `/opt/lsi/...`, wie
urspruenglich vermutet). Ausfuehrung read-only via ESXi-SSH-Diag-User.

**Physische Slot-Belegung (perccli `/c0 show all`, deckungsgleich mit iDRAC):**

| Slot | Modell            | Typ      | DG / Rolle                    | Log/Phys Sektor |
|------|-------------------|----------|-------------------------------|-----------------|
| 0,1  | HUC101860CSS204   | SAS-HDD  | DG2 Boot-RAID1 (VD239)        | 512B / 512B     |
| 2-5  | WD Red SA500 4TB  | SATA-SSD | DG1 RAID10 (VD238)=k8s-prod-23| 512B / 512B     |
| 6    | AL15SEB24EQY (Toshiba) | SAS-HDD | DG0 RAID6-Member (Row 8)  | 512B / 4 KB     |
| 7    | BL2400MM0159 (Seagate) | SAS-HDD | **DHS** (Ded. Hot Spare)  | 512B / 4 KB     |
| 8-15 | BL2400MM0159 (Seagate) | SAS-HDD | DG0 RAID6-Member (Row 0-7)| 512B / 4 KB     |

Anmerkung: iDRAC zeigt die *logische* Blockgroesse (512B, bei allen Platten einheitlich).
Die *physische* Sektorgroesse ist bei allen HDDs (Toshiba UND Seagate) 4 KB, bei den SSDs
und Boot-HDDs 512B. Es gibt somit KEINE Sektor-Heterogenitaet zwischen Toshiba und Seagate
im RAID6 - beide sind 512e (Logical 512B / Physical 4 KB).

**Korrekturen gegenueber der urspruenglichen Redfish/racadm-Lesart (13.07.):**
- Slot 7 ist **kein Foreign**, sondern ein sauberer **Dedicated Hot Spare** (Seagate).
  Der fruehere "Foreign/Warning/StandbyOffline"-Befund war eine Fehlinterpretation des
  DHS-Zustands durch iDRAC-Redfish. -> These "PatrolReadUnconfiguredArea scannt
  Foreign-Bay-7 mit" entfaellt.
- Der Verbund enthaelt **4 SSDs** (Slot 2-5), nicht 5. Slot 6 ist eine HDD (Toshiba).
- Toshiba = **Slot 6**, aktives RAID6-Member (bestaetigt via `Drive position =
  DriveGroup:0, Span:0, Row:8`). Einzige nicht-Seagate-Platte im Verbund - unterscheidet
  sich aber NUR in Modell/Hersteller, FW (EF09 vs. SBSA) und Baujahr (2023 vs. 2025).
  Sektorformat identisch zu den Seagates (Logical 512B / Physical 4 KB). Die zuvor
  vermutete "512B vs. 4K"-Heterogenitaet war ein Auswertungsfehler und ist widerlegt.

**Per-PD-Fehlerzaehler (`/c0 /eall /sall show all`) — alle 16 Platten:**
- Media Error Count = 0, Other Error Count = 0, Predictive Failure Count = 0
- Shield Counter = 0, S.M.A.R.T alert = No, Last Predictive Failure Event = 0
- Drive Temperature 28-35C (unauffaellig)
- Ergebnis: **keine per-Platte-Fehlerakkumulation** auf irgendeiner Platte, auch nicht
  auf der verdaechtigten Toshiba (Slot 6). Der 14-s-Haenger ist damit kein
  "sterbende Platte"-Fall. (Hinweis: H755/perccli exponiert keinen separaten
  "Command Timeout"-Zaehler; Timeouts wuerden als Other Error Count erscheinen = 0.)

**Patrol-Read-Status nach Reboot (`/c0 show patrolread`):**
- PR Mode = Auto, Reoccurrence/Execution Delay = 168 h (woechentlich)
- PR Current State = Stopped (Reboot hat den Dauerlauf unterbrochen)
- PR Next Start = 25.07.2026, 03:00
- PR iterations completed = 50, MaxConcurrentPd = 240, Excluded VDs = None
- **PR on SSD = Enabled** (Ausgangszustand) -> Patrol Read scannte auch VD238-SSDs
- Hintergrundraten unveraendert 30 % (Rebuild/BGI/Reconstruction/PR), Cache Flush 4 s
- VD-Cache-Policies (VD237 + VD238 identisch): WriteBack, Strip 256 KB,
  Disk Cache Policy = Disk's Default, Cachebypass Intelligent

## Umgesetzte Massnahme (21.07.)

**Patrol Read auf SSDs deaktiviert** (gering-invasiv, reversibel, kein Datenrisiko):
```
perccli64 /c0 set patrolread includessds=off
```
- Vorher: `PR on SSD = Enabled`; nachher verifiziert: `PR on SSD = Disabled`.
- Wirkung: Ab naechstem PR-Lauf (25.07. 03:00) werden die 4 Consumer-SSDs (VD238,
  k8s-prod-23) nicht mehr patrol-gelesen -> nimmt Dauer-Zusatzlast von den SSDs.
- Reversierbefehl: `perccli64 /c0 set patrolread includessds=on` (oder `=onlymixed`).
- **Erwartung (ehrlich):** Reset-Frequenz auf VD238 sinkt, verschwindet aber
  voraussichtlich NICHT vollstaendig — die fsync-Latenz-Spikes der Consumer-SSDs ohne
  PLP treten auch ohne Patrol Read unter DB-/WAL-Dauerlast auf. Nachhaltige Loesung
  bleibt Enterprise-SSD mit PLP.
- Ausfuehrung: durch Daniel (schreibender Controller-Eingriff), Verifikation read-only
  durch Claude. Kein GitOps-Pfad moeglich (Controller-Einstellung).

## Handlungsoptionen (nach Eingriffstiefe; noch nicht entschieden)

**Gering-invasiv:**
- [ERLEDIGT 21.07.] Patrol Read auf SSDs deaktiviert (`includessds=off`) -> siehe
  Abschnitt "Umgesetzte Massnahme".
- Alert auf `vcenter_host_disk_latency_max_milliseconds` je ESXi-Host (aus 13.07.-Doku
  uebernommen, weiterhin empfohlen).

**Mittel:**
- Patrol-Read-Rate / Zeitfenster anpassen (aktuell 30% Default; ggf. hoehere Rate in
  Ruhefenster, damit Laeufe kuerzer werden und nicht dauerhaft ueberlappen). Test im
  Wartungsfenster.
- Last-/Volume-Umverteilung: schreibstaerkste Workloads (DB-WAL) von der Consumer-SSD
  entlasten.

**Nachhaltig:**
- WD Red SA500 (Consumer, kein PLP) -> Enterprise-SSD mit PLP auf s3168. Loest das
  SSD-Grundproblem RAID-Level-unabhaengig.
- RAID6-Verbund vereinheitlichen (Slot 6 Toshiba durch passende Seagate ersetzen, damit
  der Verbund homogen 4K wird; der Seagate-DHS auf Slot 7 steht bereits als Ersatz bereit).

## Diagnose-Zugaenge (eingerichtet, fuer Wiederverwendung)

- ESXi-SSH (read-only Diag-User svc-esxi-diag-claude) jetzt auf **allen drei** Hosts
  (s3168, s2842, s2843) per ECDSA-Key `~/.ssh/id_ecdsa_esxi`. Ausfuehrung via WSL.
- iDRAC-Redfish s3168 (192.168.159.60), ReadOnly-User svc-diag-claude,
  Credentials in WSL `~/.idrac-diag.env` (chmod 600).
- racadm (idracadm7 11.4.0.0) in WSL installiert (Remote-Modus, read-only genutzt).
- perccli 007.3208 auf s3168 aktiv (Binary `/opt/perccli/bin/perccli64`). Diag-User
  hat auch Schreibrechte auf Controller-Properties (fuer `set patrolread` genutzt).

## Referenzen

- Vorlaeufer: `docs/incidents/2026-07-13-s3168-io-stall-longhorn-faults-prod.md`
- Verwandt: `docs/incidents/2026-06-29-cnpg-wal-deadlock-longhorn-kaskade.md`
- Longhorn-Gegenmassnahme (engineReplicaTimeout 16s): `kubernetes/base/longhorn/values.yaml`
