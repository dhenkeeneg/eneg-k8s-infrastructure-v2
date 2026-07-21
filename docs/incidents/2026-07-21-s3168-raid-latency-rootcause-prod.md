# Incident: Root-Cause s3168 RAID-Latenz -> Virt-Resets -> Longhorn-Faults k8s-prod-23 (2026-07-21)

**Status:** Root Cause identifiziert (Diagnose abgeschlossen bis auf perccli-Einzelplatten-Verifikation nach naechstem s3168-Reboot). Massnahmen noch offen (Entscheidung ausstehend).
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
- Bay-7-Foreign-Platte als aktiver Bus-Stoerer (Platte gesund; nicht Member)
- RAID6-Ueberlast/Queue-Saturation (QAVG=0, Spike bei Leerlast)

## Root Cause (Fazit)

Zwei getrennte, strukturelle Probleme auf s3168, verstaerkt durch den Dauer-Patrol-Read:

1. **VD238 SSD-RAID10 (k8s-prod-23):** WD Red SA500 = Consumer-SATA-SSD ohne
   Power-Loss-Protection. Unter fsync-Dauerlast (PostgreSQL-WAL, MariaDB-Galera, Loki,
   Prometheus, Garage) Latenz-Spikes bis 810 ms -> Command-Timeout -> Virt-Reset ->
   Longhorn-Fault-Welle. RAID10 (4 SSDs) verstaerkt vs. RAID1 (Gegenprobe: 0 Resets).

2. **VD237 HDD-RAID6:** Sporadischer 14-s-Latenz-Haenger einer Einzelplatte bei
   Leerlast. Gemischter Verbund; Bay 6 (Toshiba 2023) weicht als einzige ab ->
   Hauptverdaechtiger. Verifikation via perccli nach Reboot ausstehend.

## Offene Verifikation (nach s3168-Reboot)

perccli 007.3208.0000.0000-02 (BCM, VMwareAccepted) wurde am 21.07. **gestaged**
(`esxcli software component apply`, Reboot Required=true, NICHT rebootet). Wird nach
dem naechsten regulaeren s3168-Reboot aktiv. Damit dann:
- `perccli /c0 /eall /sall show all` -> Media/Other-Error-Count + Command-Timeouts pro
  Platte -> definitive Identifikation der haengenden HDD (Verdacht Bay 6 vs. Bay 7).
- Patrol-Read-Fortschritt/Dauer pro Platte pruefen.

## Handlungsoptionen (nach Eingriffstiefe; noch nicht entschieden)

**Gering-invasiv:**
- Bay 7 Foreign-Config bereinigen (Clear Foreign) -> entfaellt Mitscan durch Patrol Read;
  Platte danach als Ready/Hot-Spare nutzbar. (Aenderung am Controller -> Freigabe noetig.)
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
- RAID6-Verbund vereinheitlichen (Bay 6 Toshiba durch passende Seagate ersetzen; Bay 7
  sauber integrieren oder ziehen).

## Diagnose-Zugaenge (eingerichtet, fuer Wiederverwendung)

- ESXi-SSH (read-only Diag-User svc-esxi-diag-claude) jetzt auf **allen drei** Hosts
  (s3168, s2842, s2843) per ECDSA-Key `~/.ssh/id_ecdsa_esxi`. Ausfuehrung via WSL.
- iDRAC-Redfish s3168 (192.168.159.60), ReadOnly-User svc-diag-claude,
  Credentials in WSL `~/.idrac-diag.env` (chmod 600).
- racadm (idracadm7 11.4.0.0) in WSL installiert (Remote-Modus, read-only genutzt).
- perccli 007.3208 auf s3168 gestaged (aktiv nach Reboot).

## Referenzen

- Vorlaeufer: `docs/incidents/2026-07-13-s3168-io-stall-longhorn-faults-prod.md`
- Verwandt: `docs/incidents/2026-06-29-cnpg-wal-deadlock-longhorn-kaskade.md`
- Longhorn-Gegenmassnahme (engineReplicaTimeout 16s): `kubernetes/base/longhorn/values.yaml`
