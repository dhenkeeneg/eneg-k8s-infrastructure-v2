# Wartung: ESXi s3168 RAID-Umbau RAID10 -> 2x RAID1 (k8s-prod-23), 2026-07-25

**Status:** Abgeschlossen. Umbau erfolgreich, k8s-prod-23 seit 25.07. 13:48 UTC auf neuem
RAID1 in Betrieb, alle Longhorn-Volumes healthy (Stand 28.07. 06:50 UTC).
**Umgebung:** k8s-prod, ESXi s3168.eneg.de (Dell PowerEdge R760, Service Tag 4X32B94),
PERC H755 Front, ESXi 8.0.3. Nur dieser eine Host wurde umgebaut.
**Schweregrad:** geplante Wartung, kein Datenverlust.
**Vorlaeufer:** `docs/incidents/2026-07-21-s3168-raid-latency-rootcause-prod.md` (Root Cause)
**Vorherige Wartung:** `docs/maintenance/2026-07-21-esxi-s3168-wartung-drain-k8s-prod-23.md`

## Zusammenfassung

Umsetzung der in der Root-Cause-Analyse vom 21.07. abgeleiteten Massnahme: das
SSD-RAID10 ueber vier WD Red SA500 (VD238, D02-D05) wurde aufgeloest und durch zwei
unabhaengige RAID1-Verbuende ersetzt. Ziel war, die Topologie an die beiden stabilen
Referenzhosts s2842/s2843 anzugleichen (dort RAID1, 0 Virt-Resets) und die
fsync-lastigen Kubernetes-Workloads von den Windows-VMs zu trennen.

Der Umbau lief **ohne ESXi-Reboot** (Uptime durchgaengig seit 21.07. 14:55 UTC,
verifiziert 28.07.: 6 Tage 15:50 h). k8s-prod-23 wurde dafuer heruntergefahren,
zwischenzeitlich auf das HDD-RAID6 ausgelagert und nach Abschluss der Background
Initialization auf das neue SSD-RAID1 zurueckgeschoben.

**Wichtige Einschraenkung zur Wirksamkeit:** Ein belastbarer Wirksamkeitsnachweis
liegt noch NICHT vor. Die Virt-Reset-Zahlen waren bereits vor dem Umbau durch die
Massnahme vom 21.07. (Patrol Read auf SSDs deaktiviert) auf nahe null gefallen, und
k8s-prod-23 trug zwischen 25.07. und 28.07. faktisch keine DB-Last (siehe Abschnitt
"Wirksamkeitsauswertung"). Die aussagekraeftige Messung beginnt ab 28.07. 06:47 UTC.

## Aenderung der RAID-Konfiguration

### Vorher

| VD  | Name              | Layout | Disks    | Groesse   | Belegung                     |
|-----|-------------------|--------|----------|-----------|------------------------------|
| 238 | D02-D05_R10_SSD   | RAID10 | Slot 2-5 | 7,28 TB   | k8s-prod-23 + Windows-VMs    |

### Nachher

| VD  | Name              | Layout | Disks      | Groesse   | Datastore          | Belegung                 |
|-----|-------------------|--------|------------|-----------|--------------------|--------------------------|
| 236 | D04-D05_R1_SSD2   | RAID1  | Slot 4 + 5 | 3,638 TB  | S3168_SSD_02_K8s   | k8s-prod-23 (allein)     |
| 238 | D02-D03_R1_SSD1   | RAID1  | Slot 2 + 3 | 3,638 TB  | S3168_SSD_01_VMS   | SQL01, STREIT3, TS02     |

Der Datastore-Name `S3168_SSD_01_VMS` wurde wiederverwendet, bezeichnet jetzt aber ein
anderes Device (VD238) und traegt die Windows-VMs. k8s-prod-23 liegt allein auf dem neu
benannten `S3168_SSD_02_K8s` (VD236). Verifiziert via `esxcli storage vmfs extent list`
und `vim-cmd vmsvc/getallvms` am 28.07.

Unveraendert: VD237 (D07-D15_R6_HDD, RAID6, 15,278 TB) und VD239 (D00-D01_R1_BOOT,
RAID1, 558,375 GB). Dedicated Hot Spare auf Slot 7 blieb korrekt an DG0 gebunden.

**Hinweis zur VD-Nummerierung:** Der Controller vergibt keine Nummern ab 0. Die alte
RAID10-VD hiess ebenfalls 238; die Nummer wurde nach dem Loeschen neu vergeben.
perccli-Abfragen daher immer mit `/c0/v236` bzw. `/c0/v238`, nicht `/c0/v0`.

### NAA-IDs (Zuordnung VD <-> ESXi-Device)

| VD  | Name            | SCSI NAA Id                        | Datastore          |
|-----|-----------------|------------------------------------|--------------------|
| 236 | D04-D05_R1_SSD2 | 6c0470e0e4613e0031f73855de95a323   | S3168_SSD_02_K8s   |
| 238 | D02-D03_R1_SSD1 | 6c0470e0e4613e0031f737261ac43758   | S3168_SSD_01_VMS   |

Die alte RAID10-VD hatte `6c0470e0e4613e0030cea9109aa63fa7` (nach Detach vollstaendig
aus der Geraeteliste verschwunden, kein `detached remove` noetig).

## Gewaehlte VD-Einstellungen (beide RAID1 identisch)

| Einstellung              | Wert                  | Begruendung                              |
|--------------------------|-----------------------|------------------------------------------|
| Layout                   | RAID-1                | Angleich an Referenzhosts s2842/s2843    |
| Stripe-Elementgroesse    | 128 KB                | bei RAID1 kaum wirksam, Mittelweg        |
| Leseregel                | Adaptives Vorauslesen | Mischlast random + sequenziell (Rebuilds)|
| Schreibregel             | Rueckschreiben (WB)   | BBU gesund, entschaerft fsync-Latenz     |
| Festplatten-Cache-Regel  | Aktiviert (pdcache=on)| USV-Absicherung vorhanden, siehe unten   |
| Sicherheit               | Deaktiviert           | SA500 sind keine SED ("Nicht faehig")    |
| Initialisierung          | Fast Initialize       | VDs frisch, Full Init unnoetige Schreiblast |

Effektive Cache-Flags nach dem Anlegen (perccli): **RWBD** bei beiden VDs, also
Read Ahead / WriteBack / Direct IO. Kein `AWB`/`FWB` (Force WriteBack) - bewusst, damit
der Controller bei BBU-Ausfall automatisch auf WriteThrough zurueckfaellt.

**Zur Leseregel:** iDRAC bietet "Adaptives Vorauslesen" weiterhin an, die Firmware
mappt es aber auf Read Ahead (ADRA ist bei Broadcom abgekuendigt). Faktisch steht
daher `R` (Read Ahead Always) statt adaptiv. Unkritisch.

**Zur Festplatten-Cache-Regel:** Die WD Red SA500 haben keine Power-Loss-Protection.
Aktivierter Laufwerks-Cache kann bei ploetzlichem Stromverlust der Platten bereits
quittierte Schreibvorgaenge verlieren (nicht bei OS-Crash oder PSOD - dort bleiben die
Platten bestromt). Entscheidung fuer "Aktiviert" auf Basis: sehr grosse USV mit
Pufferung, redundante Netzteile im R760, Veeam-Backups der Windows-VMs, sowie
anwendungsseitige Replikation ueber drei Hosts bei den K8s-Workloads (CNPG 3 Instanzen,
Galera 3 Knoten, Longhorn Multi-Replica). Jederzeit im laufenden Betrieb reversibel via
`perccli64 /c0/vXXX set pdcache=off`.

**Abweichung beim Anlegen (korrigiert):** VD236 wurde zunaechst mit "Standardeinstellung"
(`Disk Cache Policy = Disk's Default`, PDC-Spalte `dflt`) erstellt, VD238 dagegen mit
`Enabled`. Nachtraeglich per `perccli64 /c0/v236 set pdcache=on` angeglichen und
verifiziert. Lehre: die Festplatten-Cache-Regel im iDRAC-Assistenten pro Durchlauf
explizit setzen, sie wird nicht vom vorherigen Durchlauf uebernommen.

## Ablauf (reboot-frei)

Die Reihenfolge ist entscheidend. Wird die VD im iDRAC geloescht, waehrend ESXi das
Device noch haelt, laeuft der Host in einen APD/PDL-Zustand - und genau dann braucht es
den Reboot, den man vermeiden will.

1. **Vorpruefung:** Datastore `S3168_SSD_01_VMS` restlos leer (VMs, Templates, ISOs,
   Snapshot-Reste, Content Library). HA-Heartbeat-Datastore, Scratch, Syslog, Coredump
   und Swap-to-host-cache zeigten nicht dorthin.
2. **k8s-prod-23 herunterfahren** (Guest OS Shutdown, kein Power Off) - siehe Abschnitt
   "Vorbereitung Kubernetes".
3. **VM auslagern:** Cold Migration auf `S3168_HDD_01_VMS` (RAID6). Bewusst NICHT dort
   eingeschaltet (Begruendung siehe unten).
4. **vCenter - Datenspeicher loeschen** (nicht nur "Bereitstellung aufheben", sonst
   bleibt ein verwaistes Objekt im Inventar zurueck).
5. **vCenter - Speichergeraet trennen** (dt. Oberflaeche: "TRENNEN" = Detach; Achtung,
   das ist NICHT Unmount, das liegt eine Ebene hoeher am Datenspeicher).
6. **iDRAC:** alte VD238 loeschen, zwei neue RAID1 anlegen, beide in einem Vorgang mit
   "Jetzt anwenden" (RealTime-Konfiguration des H755, kein Host-Neustart).
7. **vCenter - Speicher erneut pruefen** (Rescan). Beide neuen Devices erschienen
   korrekt als Laufwerktyp `Flash`, kein manuelles "Als Flash markieren" noetig.
8. **Zwei Datastores anlegen:** VMFS 6, gesamtes Device (3725,5 GB), Blockgroesse 1 MB,
   Rueckgewinnungs-Granularitaet 1 MB, Prioritaet "Niedrig" (haelt automatisches UNMAP
   aktiv, ohne Lastspitzen).
9. **BGI abwarten** (siehe unten), dann k8s-prod-23 auf `S3168_SSD_02_K8s` (VD236)
   zurueckmigrieren, Format Thick Provision Eager Zeroed.
10. **Einschalten** 25.07. ca. 13:48 UTC.

### Background Initialization

Der Controller startet BGI bei neuen VDs automatisch. Start 08:58 (VD238) bzw. 09:03
(VD236), Abschluss zwischen 11:00 und 11:54 UTC - also rund 2,5 bis 3 Stunden bei
unveraenderter Default-Rate von 30 %. Eine Beschleunigung auf `bgirate=80` wurde
erwogen, aber bewusst nicht durchgefuehrt (Stabilitaet vor Geschwindigkeit).

**Wichtige perccli-Korrektur:** BGI-Fortschritt wird mit `show bgi` abgefragt, NICHT mit
`show init`. `show init` bezieht sich auf die manuell ausgeloeste Vordergrund-
Initialisierung und meldet bei laufender BGI faelschlich "Not in progress".

```
/opt/perccli/bin/perccli64 /c0/vall show bgi
```

Abschlusssignal alternativ ueber `/c0 show`: Spalte `Consist` springt von `No` auf `Yes`,
Spalte `BT` (Background Task) in der TOPOLOGY von `Y` auf `N`.

## Vorbereitung Kubernetes (25.07.)

Vor dem Shutdown wurde der Cluster geprueft und ein Altlast-Befund bereinigt.

**Bereinigt:** Fuenf verwaiste Longhorn-Replicas ohne `nodeID` und ohne
`dataDirectoryName`, alle um 07:28:09 UTC entstanden, `hardNodeAffinity=k8s-prod-21`,
`rebuildRetryCount=5`. Sie liessen fuenf Volumes dauerhaft mit
`Scheduled=False / LocalReplicaSchedulingFailure` stehen (cnpg-erp-3, cnpg-erp-3-wal,
cnpg-shared-1, cnpg-shared-1-wal, storage-mariadb-galera-0). Einzelnes Loeschen der
Replica-CRs loeste es sofort auf - gleiches Verfahren wie im DEV-Fall vom 05.07.

Ursache der Waisen: k8s-prod-21 war um 07:28:09 UTC fuer rund 40 Sekunden
`NodeStatusUnknown` und um 07:28:49 wieder `Ready`. Longhorn versuchte in diesem Fenster
die Single-Replica-`strict-local`-Volumes zu replenishen, konnte nicht, und liess die
Platzhalter zurueck. **Dieser Aussetzer ist bis heute ungeklaert** (siehe Offene Punkte).

**Kein Drain noetig:** Auf k8s-prod-23 lagen ausschliesslich drei DB-Pods (cnpg-erp-1,
cnpg-shared-2, mariadb-galera-2 - alle Replicas, keine Primary) sowie neun
DaemonSet-/Longhorn-Pods. Keine zustandslosen Deployment-Pods. Es wurde daher nur
`kubectl cordon` gesetzt und der VM ein sauberer Guest-OS-Shutdown gegeben, damit CNPG
und Galera kontrolliert stoppen konnten.

## Entscheidung: VM waehrend der HDD-Zwischenlagerung ausgeschaltet lassen

Die Zwischenlagerung auf dem RAID6 dauerte mehrere Stunden. Die VM wurde bewusst NICHT
dort eingeschaltet. Begruendung:

- Beim Wiederanlauf muessen 15 degradierte Multi-Replica-Volumes auf k8s-prod-23
  rebuildet werden, zum damaligen Stand rund **152 GB** (Prometheus TSDB ~77,6 GB,
  thanos-compactor ~50,0 GB, storage-loki-0 ~21,0 GB, 12 kleinere ~3,9 GB). Ein Anlauf
  auf HDD haette diesen Rebuild einmal auf Spindeln erzeugt und beim Rueckschieben auf
  SSD ein zweites Mal - doppelte Last, die erste Haelfte davon verworfen.
- etcd ist fsync-latenzkritisch. Ein Member auf HDD kann durch langsamen WAL-fsync
  Leader-Election-Unruhe ausloesen; ein abwesender Member ist harmloser als ein
  quaelend langsamer.
- Verifiziert: `replica-soft-anti-affinity=false`. Mit nur zwei verfuegbaren Nodes kann
  Longhorn fuer ein 3-Replica-Volume keine dritte Replica platzieren. Der Cluster sitzt
  im ausgeschalteten Zustand also **ruhig degraded**, ohne Ersatz-Rebuild-Versuche.
- Gegenrechnung DB-Resync: Galera-SST ~740 MB, CNPG-Neuklon ~730 MB bzw. ~610 MB - also
  zusammen unter 3 % des Longhorn-Rebuilds. Kein Grund zur Eile.

Bewusst in Kauf genommenes Restrisiko: waehrend der Downtime hingen etcd-Quorum und
Galera-Primary-Component an k8s-prod-21 + k8s-prod-22, bei ungeklaertem prod-21-Aussetzer
vom selben Morgen.

## Wiederanlauf und Verifikation

Nach dem Einschalten am 25.07. 13:48 UTC kamen Node und Volumes hoch. **Der Uncordon
wurde jedoch versehentlich nicht durchgefuehrt** - siehe naechster Abschnitt.

Nach dem Uncordon am 28.07. 06:40 UTC verlief der Wiederanlauf vollstaendig sauber:

| Pruefung                        | Ergebnis                                      |
|---------------------------------|-----------------------------------------------|
| cnpg-erp / cnpg-shared          | 3/3 ready, "Cluster in healthy state"         |
| MariaDB Galera                  | Ready=True, GaleraReady=True, Running         |
| Longhorn Volumes                | 33/33 attached + healthy                      |
| ArgoCD Applications             | 57/57 Synced/Healthy                          |
| Pods ausserhalb Running/Succeeded | 0                                           |

Alle fuenf `strict-local`-Replicas auf k8s-prod-23 hatten vor dem Uncordon intaktes
`dataDirectoryName` und kein `failedAt`. Die Daten waren vollstaendig - deshalb konnten
beide CNPG-Cluster ohne Neuklon aufholen und Galera trat ohne SST wieder bei. Lediglich
`galera-mariadb-galera-2` (11-MB-Config-Volume) hatte seine prod-23-Replica verloren und
wurde automatisch nachgebaut.

Der komplette Rebuild (~152 GB) lief in **unter 10 Minuten** auf dem neuen RAID1 durch,
gedrosselt auf 2 parallele Rebuilds. Zum Vergleich: veranschlagt waren mehrere Stunden.

## Nachgelagerter Fehler: Cordon drei Tage lang nicht aufgehoben

**Zeitraum:** 25.07. 13:48 UTC bis 28.07. 06:40 UTC (ca. 2 Tage 17 h)

Das vor dem Shutdown gesetzte `kubectl cordon k8s-prod-23` wurde nach der Migration
nicht wieder aufgehoben. Der Uncordon war als Schritt 1 der Wiederanlauf-Verifikation
geplant, die Sitzung endete aber nach dem Einschalten.

**Auswirkung:** Die drei DB-Pods blieben durchgehend `Pending`. Scheduler-Meldung:

```
0/3 nodes are available: 1 node(s) were unschedulable,
2 node(s) didn't match PersistentVolume's node affinity.
```

Das Cordon plus die `strict-local`-Bindung der Volumes an k8s-prod-23 liessen keinen
Ausweichknoten zu. Folgesymptome: CNPG beide Cluster 2/3, Galera Ready=False, 15
Longhorn-Volumes dauerhaft degraded, 6 detached, ArgoCD `cnpg-cluster` und
`mariadb-cluster` auf Progressing. Longhorn spiegelte das Cordon zusaetzlich in den
eigenen Node-Status (`Schedulable=False`).

**Behebung:** `kubectl uncordon k8s-prod-23`. Alle Symptome loesten sich innerhalb
weniger Minuten auf. Kein Datenverlust.

**Lehre:** Der Uncordon gehoert verbindlich in die Abschlusspruefung eines
Wartungsfensters. Ein Node in `Ready,SchedulingDisabled` faellt bei einer reinen
`kubectl get nodes`-Sichtpruefung leicht durch, weil "Ready" dominiert.

## Wirksamkeitsauswertung Virt-Resets

Erhebung am 28.07. 06:48 UTC ueber ESXi-SSH (read-only Diag-User), Auswertung von
`/scratch/log/vmkernel.log` und `vmkernel.0.gz` bis `vmkernel.7.gz`:

```
zcat /scratch/log/vmkernel.[0-7].gz | grep -i virt-reset | cut -c1-10 | sort | uniq -c
grep -i virt-reset /scratch/log/vmkernel.log | cut -c1-10 | sort | uniq -c
```

| Datum      | Virt-Resets | Kontext                                            |
|------------|-------------|----------------------------------------------------|
| 2026-07-10 | 130         | Ausgangslage                                       |
| 2026-07-11 | 2920        |                                                    |
| 2026-07-12 | 3684        | Maximum                                            |
| 2026-07-13 | 2082        | Incident-Aufnahme I/O-Stall                        |
| 2026-07-14 | 2276        |                                                    |
| 2026-07-15 | 3452        |                                                    |
| 2026-07-16 | 1151        |                                                    |
| 2026-07-17 | 131         |                                                    |
| 2026-07-18 | 217         |                                                    |
| 2026-07-19 | 194         |                                                    |
| 2026-07-20 | 232         |                                                    |
| 2026-07-21 | 40          | Host-Reboot 14:55, Patrol Read auf SSD deaktiviert |
| 2026-07-22 | 0           |                                                    |
| 2026-07-23 | 0           |                                                    |
| 2026-07-24 | 2           |                                                    |
| 2026-07-25 | 15          | **RAID-Umbau** (Treffer stammen aus der Migration) |
| 2026-07-26 | 0           |                                                    |
| 2026-07-27 | 0           |                                                    |
| 2026-07-28 | 0           | bis 06:48 UTC, inkl. 152-GB-Longhorn-Rebuild       |

Log-Signatur durchgaengig identisch, damit ueber den Zeitraum vergleichbar:

```
FS3DM: 3016: status IO was aborted by VMFS via a virt-reset on the device
zeroing 1 extents (NNNNN each)
```

### Einordnung (bewusst zurueckhaltend)

Die Zahlen sehen eindeutig aus, tragen die Schlussfolgerung "RAID-Umbau hat es geloest"
aber **nicht**. Drei Einschraenkungen:

1. **Der Rueckgang begann vor dem Umbau.** Von ~200/Tag (17.-20.07.) auf 40 (21.07.) und
   dann auf 0 (22./23.07.) - zu diesem Zeitpunkt lag k8s-prod-23 noch auf dem alten
   RAID10. Der Umbau am 25.07. traf also bereits auf eine ruhige Baseline. Der Rueckgang
   faellt zeitlich mit dem Host-Reboot und der Deaktivierung von Patrol Read auf den SSDs
   am 21.07. zusammen (Massnahme aus der Root-Cause-Doku).

2. **Die 15 Treffer am 25.07. sind selbstverursacht.** Zeitstempel 09:26 UTC,
   FS3DM-Zeroing-Abbrueche im Zuge unserer eigenen Datastore-/Migrationsarbeiten
   (Eager Zeroed). Kein Hardware-Latenzsignal.

3. **Der Zeitraum 25.-28.07. ist kein gueltiger Lasttest.** Durch das nicht aufgehobene
   Cordon trug k8s-prod-23 in diesen knapp drei Tagen faktisch keine Datenbanklast - die
   drei DB-Pods waren durchgehend `Pending`. Auf dem Node liefen nur DaemonSets. Genau die
   fsync-Dauerlast (PostgreSQL-WAL, Galera, Loki, Prometheus), die historisch die
   Latenz-Spitzen ausloeste, fehlte vollstaendig.

**Der einzige belastbare Datenpunkt bisher:** Am 28.07. ab 06:40 UTC lief der Rebuild von
rund 152 GB auf das neue RAID1 - in unter 10 Minuten, mit **0 Virt-Resets**. Historisch
waren genau die Longhorn-Rebuild-Wellen der Haupttrigger (siehe Root-Cause-Doku,
"Teufelskreis"). Das ist ein gutes Zeichen, aber ein Einzelereignis.

**Fazit:** Die aussagekraeftige Messung beginnt ab 28.07. 06:47 UTC, seit die DB-Pods
wieder auf k8s-prod-23 laufen. Empfehlung: nach 7 und nach 30 Tagen Dauerlast erneut
zaehlen und hier nachtragen. Erst dann laesst sich der Umbau als wirksam bewerten oder
verwerfen.

**Unveraendert gueltig:** Der Umbau beseitigt nicht die fehlende Power-Loss-Protection der
WD Red SA500. Die nachhaltige Loesung bleibt der Wechsel auf Enterprise-SSDs mit PLP
(recherchiert: Kingston DC600M 3,84 TB ~2.314 EUR, Samsung PM893 ~2.070 EUR bei JACOB).

## BBU-Status (Grundlage der WriteBack-Entscheidung)

Geprueft am 25.07. via `perccli64 /c0/bbu show all`:

| Indikator                        | Wert            |
|----------------------------------|-----------------|
| Battery State                    | Optimal         |
| Is SOH Good                      | Yes             |
| Relative State of Charge         | 100 %           |
| Remaining / Full Charge Capacity | 480 / 480 mAh   |
| Max Error                        | 0 %             |
| Replacement required             | No              |
| Learn Cycle Status               | OK              |
| Temperatur                       | 26-27 C         |

Die Nullwerte im Block `BBU_Design_Info` (`Date of Manufacture 00/00/0`, `Design Capacity
0 mAh`) und `Absolute State of charge 0%` sind beim H755-Cache-Offload-Modul normal und
kein Defektindiz. Ebenso `Charging Status: None` - das Modul ist voll, nicht ladefaul.

## Offene Punkte

1. **k8s-prod-21 NodeStatusUnknown am 25.07. 07:28:09-07:28:49 UTC (40 s) - ungeklaert.**
   Kein Reboot (Kernel unveraendert 6.8.0-134), also vermutlich k3s-Service-Neustart.
   Seither ueber drei Tage durchgehend stabil (`Ready-since 2026-07-25T07:28:49Z`).
   Journals sind inzwischen vermutlich ueberrollt. Bei Wiederholung sofort sichern.
2. **Wirksamkeitsnachweis Virt-Resets** nach 7 und 30 Tagen Dauerlast nachtragen.
3. **UNMAP/TRIM-Durchreichung ungeklaert.** Beide VDs melden `Unmap Enabled = N/A`. Ob
   der PERC UNMAP an die SSDs weitergibt, ist offen - langfristig relevant fuer Write
   Amplification. VMFS-seitig ist Space Reclamation aktiv (Prioritaet Niedrig).
4. **Patrol Read auf RAID6 (DG0) laeuft weiterhin.** Am 25.07. zeigte die TOPOLOGY bei
   allen neun RAID6-Platten `BT = Y`. Kein Blocker, bremst aber Operationen auf dem
   HDD-Datastore.
5. **VD237 Mixed-Vendor-RAID6** (Toshiba Slot 6 gegen Seagate Slot 8-15) mit sporadischem
   14-s-Latenzhaenger - unveraendert offen. Copyback-Runbook liegt bereit:
   `docs/runbooks/s3168-raid6-member-copyback-tausch.md`.
6. **Enterprise-SSD-Beschaffung** als nachhaltige Loesung weiterhin offen.

## Lessons Learned

1. **Uncordon gehoert in die Abschlusspruefung.** `Ready,SchedulingDisabled` sieht bei
   fluechtiger Sichtpruefung wie ein gesunder Node aus. Wartungsfenster erst schliessen,
   wenn `kubectl get nodes` keinen `SchedulingDisabled` mehr zeigt UND alle Pods laufen.
2. **perccli: `show bgi` statt `show init`.** `show init` meldet bei laufender
   Background Initialization irrefuehrend "Not in progress".
3. **VD-Nummern nicht raten.** Der H755 nummeriert nicht ab 0. `/c0 show` liefert die
   tatsaechlichen Nummern, `SCSI NAA Id` aus `/c0/vXXX show all` ist die Bruecke zum
   ESXi-Device (der VD-Name wird ESXi nie mitgeteilt).
4. **Deutsche vCenter-Oberflaeche:** "TRENNEN" in der Speichergeraete-Ansicht ist
   **Detach**, nicht Unmount. Unmount heisst "Bereitstellung aufheben" und liegt am
   Datenspeicher. Reihenfolge Datastore loeschen -> Device trennen -> dann erst iDRAC.
5. **Festplatten-Cache-Regel pro Assistenten-Durchlauf explizit setzen** - sie wird nicht
   uebernommen und fuehrt sonst zu ungewollt unterschiedlich konfigurierten VDs.
6. **Bei Node-Downtime nichts ueberstuerzen:** mit `replica-soft-anti-affinity=false` und
   nur zwei verbleibenden Nodes bleibt der Cluster ruhig degraded. Ein Zwischenstart auf
   langsamem Storage haette den Rebuild verdoppelt und auf HDD verlagert.
7. **Rebuild-Aufwand vorher beziffern.** Die Summe der `status.actualSize` aller
   degradierten Volumes ist die Entscheidungsgrundlage dafuer, ob sich ein
   Zwischenschritt lohnt.
8. **Wirksamkeit sauber von Begleitmassnahmen trennen.** Der Virt-Reset-Rueckgang war
   hier nicht dem Umbau zuzuordnen, weil die Patrol-Read-Massnahme vier Tage vorher lag
   und die Last waehrend des Beobachtungszeitraums fehlte. Bei kausalen Aussagen immer
   pruefen, ob Last und Zeitfenster den Vergleich ueberhaupt hergeben.

## Referenzen

- Root Cause: `docs/incidents/2026-07-21-s3168-raid-latency-rootcause-prod.md`
- Vorherige Wartung: `docs/maintenance/2026-07-21-esxi-s3168-wartung-drain-k8s-prod-23.md`
- Vorlaeufer-Incident: `docs/incidents/2026-07-13-s3168-io-stall-longhorn-faults-prod.md`
- DEV-Praezedenzfall verwaiste Replicas: `docs/incidents/2026-07-05-longhorn-orphan-diskpressure-dev.md`
- Copyback-Runbook RAID6: `docs/runbooks/s3168-raid6-member-copyback-tausch.md`
- SSD-Vergleich: `docs/incidents/2026-07-21-s3168-ssd-ersatz-vergleich.xlsx`
