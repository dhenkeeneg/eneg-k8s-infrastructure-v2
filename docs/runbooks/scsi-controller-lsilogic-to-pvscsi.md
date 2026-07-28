# Runbook: SCSI-Controller LSI Logic Parallel -> VMware Paravirtual (PVSCSI)

**Erstellt:** 2026-07-28
**Gilt fuer:** alle neun K3s-Nodes (k8s-dev-21..23, k8s-test-21..23, k8s-prod-21..23)
**Status:** freigegeben, Umsetzung ausstehend

---

## 1 Zweck

Umstellung des virtuellen SCSI-Controllers aller K8s-Nodes von
`lsilogic` (LSI Logic Parallel, Treiber `mptspi`) auf
`pvscsi` (VMware Paravirtual, Treiber `vmw_pvscsi`).

Begruendung: PVSCSI hat eine eigene Queue pro Controller und deutlich
geringeren CPU-Overhead pro I/O. Die Workloads auf diesen Nodes sind
fsync-lastig (CNPG WAL, MariaDB Galera, Loki, Prometheus) und laufen ueber
Longhorn, also ueber einen zusaetzlichen Storage-Layer. Der Legacy-Controller
ist hier die falsche Wahl.

Die Umstellung wird mit dem noch offenen Rolling-OS-Update kombiniert, weil
beide Massnahmen denselben Node-Zyklus brauchen (cordon, drain, Node aus).

---

## 2 Ausgangslage und Ursache

Alle neun Nodes liefen auf `scsi0.virtualDev = "lsilogic"`. Ursachenkette:

1. `packer/ubuntu-24.04/ubuntu-24.04.pkr.hcl` setzte kein
   `disk_controller_type`. Der vsphere-iso-Builder faellt dann auf seinen
   Default `lsilogic` zurueck.
2. `terraform/modules/vm/main.tf` erbte den Wert mit
   `scsi_type = data.vsphere_virtual_machine.template.scsi_type`.

Beides ist mit dem Commit vom 2026-07-28 behoben:

- Packer setzt jetzt `disk_controller_type = ["pvscsi"]`.
- Das VM-Modul setzt `scsi_type = var.scsi_type` mit Default `"pvscsi"`,
  also explizit statt geerbt. Das ist wichtig: solange das Template noch
  `lsilogic` ausliefert, wuerde ein geerbter Wert die manuell umgestellten
  Nodes bei jedem Plan zurueckdrehen wollen.

**Boot-Risiko: keines.** Fuer alle neun Nodes ist geprueft, dass `vmw_pvscsi`
in der initramfs jedes installierten Kernels liegt (`MODULES=most`), Root
ueber LVM `dm-uuid` und `/boot` bzw. `/boot/efi` per UUID gemountet werden.
Der Ansible-Ablauf prueft das trotzdem erneut pro Node, weil das APT-Upgrade
im selben Lauf einen neuen Kernel mit frisch gebauter initramfs installieren
kann.

---

## 3 Voraussetzungen

Vor dem ersten Wartungsfenster:

- [ ] Commit mit Packer- und Terraform-Aenderung ist gepusht
- [ ] Commit mit erweitertem Health-Gate und `shutdown_for_hw_change.yml`
      ist gepusht, auf k8s-mgmt-10 gepullt
- [ ] Unit-Tests von `hg_cnpg_timeline.py` durchgelaufen
- [ ] `HG_CTX=k8s-<env> bash health_gate_check.sh` liefert `HEALTHY`
- [ ] `ansible-playbook ... --syntax-check` ist sauber
- [ ] Velero-Backup der Zielumgebung nicht aelter als 26 h
      (prueft der Pre-Flight-Check selbst)
- [ ] Zugriff auf vcenter-a.eneg.de offen, VM-Ordner der Umgebung bekannt

Nur fuer PROD zusaetzlich:

- [ ] `-e post_uncordon_gate_timeout_seconds=7200` eingeplant. Am 25.07.2026
      waren nach Rueckkehr von k8s-prod-23 rund 152 GB Longhorn-Rebuild
      faellig (prometheus TSDB ~77,6 GB, thanos-compactor ~50 GB,
      loki ~21 GB). Der Default von 3600 s reicht dafuer nicht.

---

## 4 Reihenfolge

Strikt sequenziell, eine Umgebung pro Wartungsfenster:

| Schritt | Ziel | Besonderheit |
|---|---|---|
| 1 | DEV, alle drei Nodes | Erstdurchlauf. Kernel wird erstmals aktualisiert, das Rolling-Update lief hier noch nie durch |
| 2 | TEST, alle drei Nodes | Kernel 6.8.0-136 ist installiert, Reboot stand aus |
| 3 | k8s-prod-21 einzeln | Kernel 6.8.0-136 installiert, Reboot stand aus |
| 4 | k8s-prod-22 einzeln | Kernel 6.8.0-136 installiert, laeuft noch auf 6.8.0-111 |
| 5 | k8s-prod-23 isoliert | **erst ab 04.08.2026**, nach der 7-Tage-Messung. Laeuft bereits auf 6.8.0-136 |

Innerhalb einer Umgebung arbeitet Play 3 mit `order: reverse_sorted`, also
Node 23 zuerst, dann 22, dann 21.

**Terminierung k8s-prod-23 - entschieden am 28.07.2026:** Umstellung **ab
04.08.2026**, also unmittelbar nach der 7-Tage-Nachmessung des RAID-Umbaus vom
25.07.2026.

Der Node ist Messobjekt fuer die Wirksamkeit dieses Umbaus (RAID10 auf vier
Consumer-SATA-SSDs ohne PLP zu zwei unabhaengigen RAID1), dokumentiert in
`docs/maintenance/2026-07-25-esxi-s3168-raid-umbau-2xraid1-k8s-prod-23.md`.
Daraus folgt eine **harte Vorbedingung**:

> Die 7-Tage-Messung muss erhoben und dokumentiert sein, **bevor** der
> Controller umgestellt wird. Sie ist der einzige saubere Wirksamkeitsnachweis
> fuer den RAID-Umbau.

Die 30-Tage-Messung wird damit eine Mischmessung aus RAID-Umbau und
Controller-Wechsel. Das ist bewusst akzeptiert, weil die Alternative bedeutet
haette, prod-23 rund vier Wochen als einzigen Node auf dem Legacy-Controller
zu belassen. Aus der 30-Tage-Messung darf entsprechend **keine kausale Aussage
ueber den RAID-Umbau allein** abgeleitet werden. Ein Hinweis dazu steht bei
den offenen Punkten des Wartungsdokuments, damit die Zahl spaeter nicht
falsch gelesen wird.

Bis zum 04.08. bleibt prod-23 als einziger Node auf `lsilogic` - das ist
gewollt und kein Fehler.

---

## 5 Ablauf

### 5.1 Ganze Umgebung (DEV, TEST)

Auf k8s-mgmt-10:

```bash
cd ~/git/eneg-k8s-infrastructure-v2/ansible
git pull

ansible-playbook -i inventory/dev/hosts.ini playbooks/08-rolling-os-update.yml \
  -e target_env=dev \
  -e node_power_action=shutdown
```

Fuer TEST analog mit `inventory/test/hosts.ini` und `-e target_env=test`.

### 5.2 Einzelner Node (PROD)

`--limit` muss **localhost mit einschliessen**, sonst werden Play 1
(Pre-Flight-Checks) und Play 4 (Post-Checks) uebersprungen:

```bash
ansible-playbook -i inventory/prod/hosts.ini playbooks/08-rolling-os-update.yml \
  -e target_env=prod \
  -e node_power_action=shutdown \
  -e post_uncordon_gate_timeout_seconds=7200 \
  --limit "k8s-prod-21,localhost"
```

### 5.3 Was das Playbook pro Node macht

1. vSphere-Snapshot per govc
2. Pre-Drain-Health-Gate - wartet bis der Cluster voll gesund ist
3. CNPG-Primary-Switchover, falls der Primary auf diesem Node liegt
4. Maintenance-Modes: CNPG `nodeMaintenanceWindow`, Longhorn
   `node-drain-policy`, Galera-PDB
5. Cordon und Drain
6. APT Update und Upgrade
7. **initramfs-Assert** - `vmw_pvscsi` muss in jeder `/boot/initrd.img-*`
   liegen. Schlaegt das fehl, wird **nicht** ausgeschaltet, die VM laeuft
   unveraendert weiter
8. Node herunterfahren, warten bis Port 22 weg ist
9. **Playbook wartet passiv bis zu 1800 s** auf die SSH-Rueckkehr

### 5.4 Deine manuellen Schritte in Phase 9

Das Playbook gibt einen Kasten mit genau dieser Aufforderung aus:

1. vSphere (vcenter-a.eneg.de) -> VM -> Einstellungen bearbeiten
2. SCSI-Controller 0 -> Typ: **VMware Paravirtual**
3. OK, dann VM einschalten

Kein Enter druecken, kein Prompt. Sobald SSH antwortet, laeuft das Playbook
von selbst weiter.

### 5.5 Was danach automatisch passiert

10. Treiber-Verifikation: `/sys/class/scsi_host/host*/proc_name` muss
    `vmw_pvscsi` enthalten. Vorher-Nachher-Vergleich und dmesg-Auszug werden
    protokolliert. Assert - bleibt der Controller unveraendert, stoppt das
    Update und der Node bleibt cordoned
11. Warten bis der Node aus Cluster-Sicht `Ready` ist
12. Uncordon, Pod-Pruefung, CNPG-Phasen-Pruefung
13. **Post-Uncordon-Health-Gate** - wartet bis der Cluster wieder voll gesund
    ist, inklusive abgeschlossener Longhorn-Rebuilds
14. Maintenance-Modes zuruecknehmen
15. Snapshot loeschen
16. Cooldown, dann naechster Node

---

## 6 Gate-Meldungen und ihre Bedeutung

Beide Gates geben genau eine Zeile aus: `HEALTHY` oder `WAIT: <grund>`.
Ansible pollt bis `HEALTHY` oder bis der Timeout laeuft, dann Abbruch.

| WAIT-Meldung | Bedeutung | Handlung |
|---|---|---|
| `Node X nicht Ready` | Node aus Cluster-Sicht weg | abwarten, bei Dauer Journal des Nodes pruefen |
| `Node X ist cordoned (SchedulingDisabled) - Restcordon aus einem frueheren Lauf?` | Ein Node ist noch aus einem abgebrochenen Lauf gesperrt | `kubectl uncordon X`, dann erneut starten |
| `CNPG ns/name nur X/Y ready` | Eine Instanz fehlt oder ist nicht ready | Pod-Status pruefen, ggf. Rebuild |
| `CNPG ns/name: Switchover laeuft` | `currentPrimary != targetPrimary` | abwarten, dauert normal Sekunden |
| `CNPG ns/name: Timeline-Divergenz zwischen Instanzen -> TL22=... TL24=...` | **Der Schadensfall.** Eine Replica haengt auf einer alten Timeline | Nicht abwarten. Siehe Abschnitt 8.2 |
| `CNPG ns/name: nur 2 von 3 Instanzen melden Status` | Eine Instanz meldet nichts, meist CrashLoop | Pod-Logs pruefen |
| `CNPG ns/name: instancesReportedState leer` | Operator hat noch keinen Status geschrieben | kurz abwarten, sonst Operator pruefen |
| `Galera nur X/Y ready` | StatefulSet nicht vollstaendig | Galera-Pods pruefen |
| `Longhorn-Volume V ist FAULTED` | Volume defekt | Nicht abwarten, Longhorn-UI pruefen |
| `Longhorn-Volume V attached, aber robustness=degraded (Rebuild steht ggf. noch aus, replicaReplenishmentWaitInterval)` | Normalzustand direkt nach Node-Rueckkehr | **Abwarten. Kann bis zu 20 Minuten stehen, bevor der Rebuild ueberhaupt startet.** Das ist korrektes Verhalten, kein Haenger |
| `N aktive(r) Longhorn-Rebuild(s) laufen noch` | Rebuild laeuft | abwarten, in PROD ggf. lange |
| `Pod ns/name ist Pending und nicht schedulebar (PodScheduled=False)` | Scheduler findet keinen Platz | meist Folge eines Restcordons |
| `python3 auf dem Ansible-Controller nicht gefunden` | Umgebung auf mgmt-10 kaputt | python3 pruefen, Gate laeuft sonst blind |

Einzelnen Check gezielt abschalten, falls ein Gate faelschlich blockiert:

```bash
-e health_gate_check_longhorn_robustness=false
-e health_gate_check_cnpg_timeline=false
-e health_gate_check_nodes=false
-e health_gate_check_pending_pods=false
-e health_gate_allow_cordoned=k8s-prod-23
```

Das ist ein Notausgang, keine Routine. Wer einen Check abschaltet, sollte im
Wartungsprotokoll notieren, warum.

---

## 7 Abschlusspruefung eines Wartungsfensters

Ein Fenster gilt erst als geschlossen, wenn **alle** Punkte erfuellt sind.
Der Punkt mit dem Cordon ist die Lehre aus dem RAID-Umbau: k8s-prod-23 blieb
drei Tage cordoned, wodurch drei DB-Pods dauerhaft Pending waren.

```bash
# 1 Kein Node mehr SchedulingDisabled
kubectl --context k8s-<env> get nodes

# 2 Alle Nodes auf dem Zielkernel
kubectl --context k8s-<env> get nodes \
  -o custom-columns=NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion

# 3 Kein Pod ausserhalb Running/Succeeded
kubectl --context k8s-<env> get pods -A --field-selector status.phase!=Running \
  | grep -v Succeeded

# 4 CNPG-Cluster gesund, gleiche Timeline pro Cluster
kubectl --context k8s-<env> get clusters.postgresql.cnpg.io -A
kubectl --context k8s-<env> get clusters.postgresql.cnpg.io -A \
  -o 'jsonpath={range .items[*]}{.metadata.name}: {.status.instancesReportedState}{"\n"}{end}'

# 5 Longhorn ohne degraded/faulted
kubectl --context k8s-<env> -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROB:.status.robustness \
  --no-headers | grep -v healthy

# 6 Health-Gate von Hand als Gesamturteil
HG_CTX=k8s-<env> bash ~/git/eneg-k8s-infrastructure-v2/ansible/roles/rolling_os_update/files/health_gate_check.sh

# 7 Treiber auf jedem umgestellten Node
#    (pro Node, per SSH oder Ansible ad-hoc)
cat /sys/class/scsi_host/host*/proc_name

# 8 Keine vSphere-Snapshots uebrig
```

Zu Punkt 5: `detached`-Volumes melden `robustness: unknown`, das ist deren
Normalzustand und kein Befund. Nur `attached` plus nicht-`healthy` sowie
`faulted` sind relevant.

---

## 8 OpenTofu-Driftkontrolle

Die Umstellung geschieht manuell in vSphere (Variante A1). OpenTofu wird
ausschliesslich als **Kontrolle** genutzt, nie mit `apply` in diesem Kontext.

Nach jedem umgestellten Node:

```bash
cd ~/git/eneg-k8s-infrastructure-v2/terraform/environments/<env>
tofu plan
```

Erwartung: fuer den gerade umgestellten Node darf `scsi_type` **nicht mehr**
im Plan auftauchen. Solange in derselben Umgebung noch Nodes auf `lsilogic`
laufen, zeigt der Plan fuer **diese** Nodes weiterhin
`scsi_type: "lsilogic" -> "pvscsi"`. Das ist erwartet und kein Problem.

Erst wenn eine Umgebung vollstaendig umgestellt ist, muss der Plan bezueglich
`scsi_type` vollstaendig leer sein.

**Kein `tofu apply`** waehrend dieser Aktion. Ein Apply wuerde versuchen, den
Controller bei laufender VM zu aendern, und ausserdem alle anderen Drifts in
einem Rutsch mitziehen.

---

## 9 Rollback

### 9.1 Node bootet nach der Umstellung nicht

Sehr unwahrscheinlich, weil der initramfs-Assert vor dem Ausschalten greift.
Falls doch:

1. VM in vSphere ausschalten
2. SCSI-Controller 0 zurueck auf **LSI Logic Parallel**
3. VM einschalten
4. Node kommt mit dem alten Treiber zurueck, Daten unveraendert
5. `kubectl uncordon <node>` nicht vergessen

Das Playbook ist an dieser Stelle bereits mit einem Fehler ausgestiegen. Der
Node bleibt cordoned, bis er von Hand freigegeben wird.

### 9.2 Timeline-Divergenz einer CNPG-Replica

Wenn ein Gate `Timeline-Divergenz` meldet, ist das Datenverzeichnis dieser
Replica in der Regel nicht mehr reparabel. Der Kontrollpunkt in ihrer
`pg_control` liegt auf dem abgeschnittenen Ast der alten Timeline, und das
S3-Archiv enthaelt fuer diesen LSN-Bereich nur die Variante der neuen
Timeline. Warten hilft nicht.

Vorgehen: Instanz verwerfen und neu aufbauen lassen.

```bash
kubectl cnpg --context k8s-<env> destroy <cluster> <instanz-serial> -n databases
```

Der Operator legt eine neue Instanz mit dem naechsten freien Serial an und
zieht sie per `pg_basebackup` vom Primary.

Danach aufraeumen, weil die StorageClass `longhorn-db` auf
`reclaimPolicy: Retain` steht. **Reihenfolge ist wichtig: erst PV, dann
Longhorn-Volume**, sonst bleibt ein PV zurueck, das auf ein nicht mehr
existierendes Volume zeigt.

```bash
kubectl --context k8s-<env> get pv | grep Released
kubectl --context k8s-<env> delete pv <pv-name-pgdata> <pv-name-wal>
kubectl --context k8s-<env> -n longhorn-system delete volumes.longhorn.io <pv-name-pgdata> <pv-name-wal>
```

Referenzfall: cnpg-shared-3 in DEV am 2026-07-28 (Serial 3 verworfen, Serial 7
neu aufgebaut, 28 GB freigeraeumt).

### 9.3 Letztes Mittel: Snapshot

Der vSphere-Snapshot aus Schritt 1 existiert nur waehrend des Laufs und wird
bei Erfolg geloescht. Fuer PROD kann er behalten werden:

```bash
-e snapshot_delete_on_success=false
```

Ein Snapshot-Revert rollt auch die Longhorn-Replicadaten dieses Nodes zurueck
und loest anschliessend Rebuilds aus. Nur einsetzen, wenn der Node anders
nicht mehr startfaehig ist. Snapshots niemals parallel ueber mehrere Nodes
loeschen - sequenziell pro Node mit Konsolidierungs-Wartezeit, sonst
I/O-Sturm und K3s-Liveness-Fehler.

---

## 10 Fallstricke

**Zeitbudget 1200 s.** Zwischen Shutdown und wieder-`Ready` sollten unter
1200 s liegen, das ist Longhorns `replicaReplenishmentWaitInterval`. Danach
beginnt Longhorn mit Replica-Replenishment, waehrend der Node aus ist. Der
`scsi_type`-Wechsel selbst dauert unter einer Minute - in diesem Fenster
nichts anderes am Host machen.

**`--limit` ohne localhost.** Play 1 (Pre-Flight) und Play 4 (Post-Checks)
laufen auf localhost. Ohne `--limit "<node>,localhost"` fallen beide
stillschweigend weg, inklusive Velero-Backup-Alter und ArgoCD-Sync-Check.

**Das Gate haengt nicht, es wartet.** Ein `WAIT` mit
`robustness=degraded (Rebuild steht ggf. noch aus)` kann bis zu 20 Minuten
unveraendert stehen, bevor der Rebuild ueberhaupt startet, und danach je nach
Volumengroesse deutlich laenger. Das ist der Sinn des Checks.

**Nur ein Fenster pro Umgebung.** Nie zwei Umgebungen im selben Fenster. Die
Cluster teilen sich vSphere-Datastores und Controller-Layer, Longhorn-Rebuilds
kaskadieren darueber.

**Die Ansible-Rolle ist nicht environment-spezifisch.** Eine Aenderung an der
Rolle gilt nach dem Push sofort fuer alle drei Umgebungen. Der DEV-Durchlauf
ist deshalb Freigabekriterium fuer TEST und PROD.

---

## 11 Offene Punkte zur Nachbereitung

Nicht Teil dieses Runbooks, aber im selben Themenfeld:

1. **Template-Neubau mit Packer.** Erst danach bekommen neu ausgerollte Nodes
   PVSCSI von Anfang an. `scsi_type` bleibt im VM-Modul trotzdem explizit -
   der Zielzustand soll im Code stehen, nicht aus dem Template geraten werden.
2. **UUID-Kollision.** Alle Nodes einer Template-Linie teilen identische
   LVM-VG- und Dateisystem-UUIDs. Linie A = dev-21/22/23,
   Linie B = test-21/22/23 plus prod-21/22/23, also quer ueber TEST und PROD.
   Im Betrieb harmlos, kritisch nur beim Anhaengen einer fremden VMDK zur
   Datenrettung. Loesung im Template ueber einen First-Boot-Service analog
   `extend-lvm.service`, nicht nachtraeglich an bestehenden Nodes.
   `vgimportclone` als Pflichtschritt ins Recovery-Runbook.
3. **`disk_thin_provisioned` vs. Ist-Zustand.** Das Packer-Template setzt
   `disk_thin_provisioned = true`, k8s-prod-23 wurde bei der Migration am
   25.07. aber als Thick Eager Zeroed angelegt. Inkonsistenz klaeren.
4. **Projektplanung Zeile 142** behauptet, s3168 trage k8s-dev-23,
   k8s-test-23 und k8s-prod-23. Tatsaechlich ist dort nur k8s-prod-23
   registriert, verifiziert per `vim-cmd vmsvc/getallvms`. Richtigstellen.
5. **k8s-prod-21 NodeStatusUnknown** am 25.07. zwischen 07:28:09 und
   07:28:49 UTC, 40 s, kein Reboot. Ursache ungeklaert, Journals vermutlich
   ueberrollt. Bei Wiederholung sofort sichern.

---

## 12 Referenzen

- `packer/ubuntu-24.04/ubuntu-24.04.pkr.hcl` - `disk_controller_type`
- `terraform/modules/vm/main.tf`, `variables.tf` - `scsi_type`
- `ansible/roles/rolling_os_update/tasks/shutdown_for_hw_change.yml`
- `ansible/roles/rolling_os_update/files/health_gate_check.sh`
- `ansible/roles/rolling_os_update/files/hg_cnpg_timeline.py`
- `docs/maintenance/2026-07-25-esxi-s3168-raid-umbau-2xraid1-k8s-prod-23.md`
- `docs/incidents/2026-07-21-s3168-raid-latency-rootcause-prod.md`
- `docs/incidents/2026-07-23-dev-os-update-rebuild-storm.md`

---

## 13 Aenderungshistorie

| Datum | Aenderung |
|---|---|
| 2026-07-28 | Erstfassung. Packer und Terraform umgestellt, Health-Gate um Timeline-, Robustness-, Node- und Pending-Checks erweitert, Shutdown-Modus eingefuehrt. |
| 2026-07-28 | Terminierung k8s-prod-23 entschieden: ab 04.08.2026 nach der 7-Tage-Messung. Mischmessung bei 30 Tagen bewusst akzeptiert, Hinweis im Wartungsdokument ergaenzt. |
