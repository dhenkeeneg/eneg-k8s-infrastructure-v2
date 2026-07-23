# Runbook: RAID6-Member-Tausch s3168 (Toshiba Slot 6 -> Seagate DHS) via Copyback

**Erstellt:** 2026-07-23
**Autor:** Daniel Henke (mit Claude)
**Betroffenes System:** s3168.eneg.de (ESXi-Host fuer k8s-prod-23), PERC H755, iDRAC 192.168.159.60
**Kontext:** Incident `docs/incidents/2026-07-21-s3168-raid-latency-rootcause-prod.md`
**Status:** VORBEREITET - Ausfuehrung im Wartungsfenster ausstehend
**Eingriffstyp:** Schreibender RAID-Eingriff in PROD. NUR im Wartungsfenster. Ausfuehrung durch Daniel.

---

## Ziel

Die einzige nicht-Seagate-Platte im RAID6 (VD237/DG0) - eine Toshiba AL15SEB24EQY auf
Bay 6 - kontrolliert gegen die bereits gesteckte, identische Seagate BL2400MM0159
(Bay 7, aktuell Dedicated Hot Spare) tauschen. Anschliessend eine neue identische
Seagate als neuen DHS einsetzen. Der Verbund wird damit vollstaendig homogen (Seagate).

**Wichtig - Erwartungshaltung:** Dieser Tausch behebt KEIN belegtes Hardwareproblem.
Die perccli-Verifikation (siehe Incident-Doku) zeigt fuer die Toshiba alle Fehlerzaehler
= 0 und identisches Sektorformat (512e) zu den Seagates. Der Tausch ist eine
Homogenisierungs-/Vorsorgemassnahme, kein Defektaustausch. Der 14-s-Latenz-Haenger ist
KEINER Einzelplatte eindeutig zugeordnet.

---

## Methode: replacephysicaldisk (kontrolliertes Copyback)

`racadm storage replacephysicaldisk` fuehrt ein Copyback von einem **gesunden, online**
Member auf eine **Ready**-Zielplatte aus. Der RAID6-Verbund bleibt waehrend des gesamten
Vorgangs **Optimal/redundant** - es gibt KEINEN Parity-Rebuild (der degradieren wuerde).
Voraussetzung laut Dell: Quelle = Teil einer VD + Online; Ziel = Ready-State, passende
Groesse+Typ. Beides ist erfuellt (beide 2235 GB, SAS-HDD).

**Warum nicht perccli:** perccli 007.3208 kennt kein `replace`; `start copyback` ist
fuer den umgekehrten Fall (Spare->neue Platte nach Ausfall) gedacht und auf gesundes
Member nicht dokumentiert unterstuetzt. racadm replacephysicaldisk ist der von Dell
unterstuetzte Pfad fuer genau dieses Szenario.

---

## Verifizierte Bezeichner (Stand 2026-07-23, read-only abgefragt)

| Rolle                     | FQDD                                              | State  | Groesse   |
|---------------------------|---------------------------------------------------|--------|-----------|
| Quelle (Toshiba, raus)    | `Disk.Bay.6:Enclosure.Internal.0-1:RAID.SL.3-1`   | Online | 2235 GB   |
| Ziel (Seagate DHS)        | `Disk.Bay.7:Enclosure.Internal.0-1:RAID.SL.3-1`   | Ready/DHS | 2235 GB |
| RAID6-VD (DG0)            | `Disk.Virtual.237:RAID.SL.3-1`                    | Optimal| 15.278 TB |
| Controller (H755)         | `RAID.SL.3-1`                                      | -      | -         |

Toshiba: SN 13J0A3E2FQYF, FW EF09. Seagate-DHS Bay 7: SN WBM9ZPS3, FW SBSA.

**racadm-Basis (Creds aus ~/.idrac-diag.env sourcen):**
```bash
. ~/.idrac-diag.env
RAC="/opt/dell/srvadmin/bin/idracadm7 -r $IDRAC_HOST -u $IDRAC_USER -p $IDRAC_PW --nocertwarn"
```

---

## Phase 0 - Vorab-Checks (im Wartungsfenster, VOR dem Eingriff)

**0.1 Backup-Absicherung.** Velero-Backup fuer k8s-prod-23-Workloads aktuell? CNPG- und
Galera-Backups gruen? (Auch wenn kein Rebuild: bei PROD-RAID-Eingriff immer Backup-Stand
verifizieren.) Pruefung ueber die ueblichen Wege (ArgoCD/Velero-Status).

**0.2 Ausgangszustand dokumentieren (read-only):**
```bash
$RAC storage get vdisks -o | grep -A6 "Disk.Virtual.237"
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.6:"
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.7:"
```
Erwartet: VD237 = Optimal; Bay 6 = Online; Bay 7 = Ready + Hotspare=Dedicated.

**0.3 Keine laufenden Hintergrundoperationen.** Sicherstellen, dass KEIN Patrol Read,
BGI, CC oder Rebuild aktiv ist (sonst konkurrieren die I/O):
```bash
$RAC storage get controllers -o | grep -i -E "Patrol|Background|Job"
$RAC jobqueue view
```
Falls Patrol Read laeuft: abwarten oder stoppen, bevor Copyback startet.

---

## Phase 1 - DHS-Bindung pruefen / ggf. loesen

Die Zielplatte (Bay 7) ist aktuell **Dedicated Hot Spare** fuer VD237. Ein DHS ist
"reserviert" - `replacephysicaldisk` kann verlangen, dass das Ziel ein reines "Ready"
ohne Spare-Bindung ist.

**1.1 Erst OHNE Loesen versuchen** (Phase 2). Wenn racadm dort einen Fehler wie
"destination not in ready state" / "reserved as hotspare" liefert -> DHS zuerst loesen:

**1.2 Fallback - DHS-Zuweisung von Bay 7 aufheben:**
```bash
$RAC storage hotspare:Disk.Bay.7:Enclosure.Internal.0-1:RAID.SL.3-1 -assign no
```
Danach Job anwenden (siehe Muster in Phase 2.2) und verifizieren:
```bash
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.7:"
```
Erwartet danach: Bay 7 State = Ready, Hotspare = NO. Dann weiter mit Phase 2.

> Hinweis: Nach Aufheben der DHS-Bindung ist VD237 voruebergehend OHNE Hot Spare.
> Das ist fuer die kurze Dauer des Copybacks akzeptabel (Verbund bleibt Optimal), sollte
> aber bewusst sein. Die neue Seagate wird in Phase 4 als neuer DHS gesetzt.

---

## Phase 2 - Copyback starten (Toshiba Bay 6 -> Seagate Bay 7)

**2.1 Replace-Kommando absetzen:**
```bash
$RAC storage replacephysicaldisk:Disk.Bay.6:Enclosure.Internal.0-1:RAID.SL.3-1 -dstpd Disk.Bay.7:Enclosure.Internal.0-1:RAID.SL.3-1
```
Das erzeugt typischerweise einen **Pending Job** auf dem Controller (kein sofortiger
Start). racadm gibt eine Job-ID (JID_...) zurueck.

**2.2 Job anwenden** (falls als Pending angelegt - bei realtime-faehigen Ops entfaellt das,
aber sicherheitshalber pruefen):
```bash
$RAC jobqueue view
```
Wenn ein Pending/Scheduled Job existiert und ein "apply"/realtime noetig ist, folgt der
Controller-Job automatisch (H755 unterstuetzt Realtime-Config). Andernfalls Job-Status
beobachten.

**2.3 Copyback-Fortschritt verfolgen (read-only, wiederholen):**
```bash
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.6:"
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.7:"
```
Erwarteter Verlauf:
- Bay 7 geht in State **"Copyback"** / OperationState zeigt Fortschritt (%).
- Bay 6 bleibt zunaechst Online (Daten werden kopiert, nicht rekonstruiert).
- VD237 bleibt durchgehend **Optimal** (KEIN "Degraded" - das ist der Beleg, dass es
  ein Copyback und kein Rebuild ist!).

Alternativ perccli read-only (zeigt Copyback sauber als "CBShld"/Cpybck):
```bash
/opt/perccli/bin/perccli64 /c0/e252/s6 show
/opt/perccli/bin/perccli64 /c0/e252/s7 show
/opt/perccli/bin/perccli64 /c0/dall show
```

**2.4 ABBRUCH-Kriterium:** Falls VD237 in "Degraded" wechselt (statt Optimal zu bleiben),
handelt es sich NICHT um ein sauberes Copyback. Dann NICHT die Toshiba ziehen. Situation
dokumentieren und bewerten, bevor weitergemacht wird. (Bei Degraded laeuft ein echter
Rebuild - der ist zwar auch sicher, erzeugt aber die I/O-Last, die wir vermeiden wollten.)

---

## Phase 3 - Copyback-Abschluss verifizieren

Copyback dauert je nach Fuellstand/Last typ. 1-4 h fuer 2.18 TB. Nach Abschluss:
```bash
$RAC storage get vdisks -o | grep -A6 "Disk.Virtual.237"
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.6:"
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.7:"
```
Erwarteter Endzustand:
- VD237 = **Optimal**
- Bay 7 (Seagate) = **Online**, jetzt aktives RAID6-Member (Row 8 uebernommen)
- Bay 6 (Toshiba) = **Ready** (aus dem Verbund entlassen, keine VD-Zugehoerigkeit mehr)

perccli-Gegencheck: `/c0/dall show` -> Bay 7 (252:7) sollte jetzt als Onln-Member in DG0
gelistet sein, Bay 6 (252:6) nicht mehr.

---

## Phase 4 - Toshiba entfernen + neue Seagate als DHS

**4.1 Toshiba (Bay 6) physisch ziehen.** Erst NACHDEM Phase 3 den Endzustand bestaetigt
hat (Bay 6 = Ready, nicht mehr Member). Platte beschriften (SN 13J0A3E2FQYF, FW EF09),
als "aus PROD-RAID6 s3168 entnommen, gesund" archivieren.

**4.2 Neue Seagate BL2400MM0159 in Bay 6 einsetzen.** Sollte als "Unconfigured Good" /
"Ready" erkannt werden:
```bash
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.6:"
```
Erwartet: State = Ready, Size 2235 GB. Falls "Foreign": Foreign-Config clearen (separat
zu bewerten - nur wenn noetig).

**4.3 Neue Seagate (Bay 6) als Dedicated Hot Spare fuer VD237 zuweisen:**
```bash
$RAC storage hotspare:Disk.Bay.6:Enclosure.Internal.0-1:RAID.SL.3-1 -assign yes -type dhs -vdkey:Disk.Virtual.237:RAID.SL.3-1
```

**4.4 Endzustand verifizieren:**
```bash
$RAC storage get pdisks -o | grep -A9 "Disk.Bay.6:"
$RAC storage get vdisks -o | grep -A6 "Disk.Virtual.237"
/opt/perccli/bin/perccli64 /c0/dall show
```
Erwarteter finaler Zustand:
- VD237 = Optimal, homogener Seagate-Verbund (Bay 7 + Bay 8-15)
- Bay 6 (neue Seagate) = Ready + Dedicated Hot Spare fuer VD237
- Kein Toshiba mehr im System

---

## Rollback-/Notfall-Betrachtung

- **Waehrend Copyback (Phase 2):** Kein echtes Rollback noetig, da Verbund Optimal bleibt.
  Copyback kann bei Bedarf ueber Controller gestoppt werden (perccli `stop`), Toshiba
  bleibt dann Member.
- **Datenverlustrisiko:** Sehr gering, da RAID6 durchgehend redundant und kein Rebuild.
  Doppelter Plattenausfall waehrend Copyback waere erforderlich fuer Datenverlust
  (RAID6 vertraegt 2 Ausfaelle) - daher Phase 0.1 Backup-Check.
- **Falls replacephysicaldisk gar nicht startet:** DHS-Bindung loesen (Phase 1.2) und
  erneut versuchen. Wenn dann immer noch nicht: Vorgang abbrechen, Zustand dokumentieren,
  Alternativweg (echter Rebuild via forceoffline Bay 6) NUR nach erneuter Abstimmung.

---

## Post-Eingriff

- Incident-Doku `2026-07-21-s3168-raid-latency-rootcause-prod.md` um Durchfuehrung
  ergaenzen (Datum, tatsaechlicher Verlauf, End-SMART-Werte).
- Beobachtung: Tritt der 14-s-VD237-Haenger nach der Homogenisierung weiter auf? Das ist
  der eigentliche Test, ob die Toshiba (unwahrscheinlich) doch beteiligt war.
- Entnommene Toshiba als Kaltreserve/Diagnoseobjekt aufbewahren.
