# Runbook: vSphere/vCenter-Metriken via OpenTelemetry vcenter-Receiver in Alloy

**Kategorie:** Monitoring / OpenTelemetry / vSphere / Kapazitaetsplanung
**Erstellt:** 03.07.2026 (DEV-Rollout abgeschlossen)
**Stichworte:** Alloy, otelcol.receiver.vcenter, vCenter, ESXi, Host-Latenz, Kapazitaet, remote_write, VMCA, CA-Bundle

---

## Wann dieses Runbook?

- Ausrollen der vCenter-Metrik-Instanz in einer neuen Umgebung (TEST/PROD)
- Fehlersuche, wenn vcenter_*-Metriken fehlen oder nicht in Prometheus ankommen
- Erneuerung des vCenter-Monitoring-Users oder des VMCA-CA-Bundles
- Verstaendnis der Architektur (warum dedizierte Instanz, warum remote_write)

## Ziel / Motivation

ESXi-/vCenter-Metriken (Host-CPU/RAM, Datastore-Kapazitaet und -Latenz,
VM-Ready-Time, Ballooning/Swap) nach Prometheus/Thanos bringen, damit
Migrationsentscheidungen auf Host-Ebene datengestuetzt sind. Zwei Kernfragen:
1. Datastore-/Disk-Latenz sichtbar machen (strukturelles ~200ms-Problem)
2. Host-Auslastung (CPU/RAM-Headroom): wo koennen weitere K8s-Nodes platziert werden?

## Architektur (Kernentscheidungen)

- **Dedizierte Alloy-Instanz** (Release `alloy-vcenter`, Deployment, replicas 1),
  GETRENNT vom Log-Forwarding-DaemonSet (Release `alloy`). Grund: ein DaemonSet
  wuerde vCenter von jedem Node aus pollen -> mehrfache Last + Duplikat-Metriken.
- **Zwei vCenter in einer Instanz**: 2x `otelcol.receiver.vcenter` (vcenter_a +
  vcenter_b), gemeinsamer Batch/Export-Pfad.
- **Muster P = remote_write** (Push): Alloy pusht an den kube-prometheus-stack
  Prometheus (`enableRemoteWriteReceiver: true`). Kein ServiceMonitor.
  Alternative (verworfen): ServiceMonitor-Scrape - komplexere Alloy-interne
  Verdrahtung, da otelcol.exporter.prometheus KEINEN HTTP-Endpoint exponiert,
  sondern nur ein OTLP->Prometheus-Konverter ist.
- **TLS via CA-Bundle**: Beide vCenter nutzen self-signed VMCA-Zertifikate
  (vsphere.local) und liefern die Root NICHT mit. Daher clientseitiges CA-Bundle
  (beide VMCA-Roots) als Secret, gemountet nach /etc/vcenter-ca/ca.crt -> ca_file.
- **Label-Erhalt via transform-Processor**: otelcol.processor.transform hebt die
  vCenter-resource_attributes (Host-/Datastore-/Cluster-Name) auf Datapoint-Ebene,
  damit sie als Prometheus-Labels erhalten bleiben. Vermeidet den Alloy-Label-Bug
  (#2026) UND die Kardinalitaets-Explosion von resource_to_telemetry_conversion.

## Versionen (Stand 03.07.2026)

- Alloy Helm-Chart: **1.10.0** (aus grafana.github.io/helm-charts)
- Alloy-Binary: **v1.17.x** (vom Chart mitgeliefert)
- WICHTIG: Chart-Version IMMER gegen index.yaml des Helm-Repos pruefen, NICHT
  gegen GitHub-Releases. Chart 1.10.1 existiert nur als GitHub-Release, nicht im
  publizierten Helm-Index -> ArgoCD-Fehler "chart not found".
  Pruefskript: scripts/list-alloy-versions.ps1
- vcenter-Receiver ist EXPERIMENTAL -> `alloy.stabilityLevel: "experimental"` Pflicht.
- Unterstuetzte vSphere-Versionen: 7.0 und 8. (eNeG: vcenter-a 8.0.3, vcenter-b 8.0.2)

---

## Schritt 1 - vCenter Service-Account (einmalig, gilt fuer beide vCenter)

AD-User (gemeinsame Identity-Source beider vCenter):
- UPN: `svc-otel-vcenter@eneg.de`
- Kontooptionen: Passwort laeuft nie ab, User kann PW nicht aendern, kein
  interaktiver Login noetig. Nur Mitglied "Domain Users".

vCenter-Rolle (in JEDEM vCenter anlegen: vcenter-a UND vcenter-b):
- Name: `OTel-ReadOnly-Monitoring`
- Basis: eingebaute Rolle "Read-only" klonen
- Zusaetzlich: `Performance -> Modify intervals` (Performance.ModifyIntervals)
  -> erlaubt dem Receiver, das Statistik-Sammelintervall zu setzen (noetig fuer
     volle Metrikabdeckung, u.a. Disk-Latenz). KEIN Schreibrecht auf Infrastruktur.

Berechtigung zuweisen (in JEDEM vCenter):
- Am ROOT-Objekt (vCenter-Server oben in der Inventory-Hierarchie)
- Tab Permissions -> Add: User `ENEG\svc-otel-vcenter`, Rolle
  `OTel-ReadOnly-Monitoring`, "Propagate to children" AKTIVIEREN (zwingend).

Verifikation (rein lesend, von einem Host mit Netzzugriff):
```powershell
# scripts/verify-vcenter-user.ps1 (PowerShell 7)
$env:VC_PASS = "<passwort>"   # oder sicher via Read-Host -AsSecureString
.\verify-vcenter-user.ps1 -VCenter vcenter-a.eneg.de -UserUpn svc-otel-vcenter@eneg.de
.\verify-vcenter-user.ps1 -VCenter vcenter-b.eneg.de -UserUpn svc-otel-vcenter@eneg.de
Remove-Item Env:\VC_PASS
```
Erwartet: LOGIN OK + Hosts/Datastores > 0 bei beiden.

## Schritt 2 - VMCA Root-CAs beschaffen und Bundle bauen

Beide vCenter liefern nur das Leaf-Zert (VMCA self-signed). Root separat holen:
```powershell
# scripts/fetch-vmca-roots.ps1 laedt /afd/vecs/ca (DER-Format, anonym)
pwsh -File scripts/fetch-vmca-roots.ps1 -VCenter vcenter-a.eneg.de -OutDir <tmp>
pwsh -File scripts/fetch-vmca-roots.ps1 -VCenter vcenter-b.eneg.de -OutDir <tmp>
# DER -> PEM (scripts/convert-ca.cmd), dann beide PEM zu einem Bundle concat.
```
Verifikation: Leaf-Issuer MUSS == Root-Subject sein (pro vCenter).
- vcenter-a Root: CN=CA, ...vsphere.local, O=vcenter-a.eneg.de (bis 12.12.2035)
- vcenter-b Root: CN=vcenter-b, ...vsphere.local, O=vcenter-b.eneg.de (bis 14.04.2036)

Bundle als base64 ins Secret `vcenter-ca-bundle` (data.ca.crt). Da OEFFENTLICHE
CA-Zertifikate: KEIN SOPS noetig, normales Secret im Repo. Renewal-Monitoring:
Root-Ablauf 2035/2036 (unkritisch), Leafs 2027/2028.

## Schritt 3 - Repo-Struktur (Beispiel DEV)

```
kubernetes/base/monitoring/alloy-vcenter/values.yaml          # Basis (Deployment, experimental, Mounts)
kubernetes/environments/dev/alloy-vcenter/values.yaml         # River-Config (2 Receiver, transform, remote_write)
kubernetes/environments/dev/alloy-vcenter-secrets/
  vcenter-ca-bundle.yaml                                       # CA-Bundle (kein SOPS)
  vcenter-credentials.yaml.template                            # Vorlage
  vcenter-credentials.enc.yaml                                 # SOPS-verschluesselt (User+PW)
  secret-generator.yaml, kustomization.yaml
kubernetes/environments/dev/infrastructure/
  alloy-vcenter-secrets-app.yaml                               # ArgoCD-App, sync-wave 1
  alloy-vcenter-app.yaml                                       # ArgoCD-App, sync-wave 4
kubernetes/environments/dev/monitoring/values-override.yaml   # enableRemoteWriteReceiver: true
kubernetes/environments/dev/monitoring-alerts/
  vsphere-hosts-dashboard-cm.yaml                              # Grafana-Dashboard (DEV-only)
```

## Schritt 4 - Secret verschluesseln (auf mgmt-10) und Rollout

WICHTIG: Zwei-Etappen-Push (secret-first), damit ArgoCD nicht ohne Credentials startet.

Etappe 1: Alle Dateien AUSSER den ArgoCD-Apps pushen. Dann auf mgmt-10:
```bash
cd ~/git/eneg-k8s-infrastructure-v2/kubernetes/environments/<env>/alloy-vcenter-secrets
cp vcenter-credentials.yaml.template vcenter-credentials.yaml
# VCENTER_PASSWORD eintragen
sops --encrypt --encrypted-regex '^(data|stringData)$' \
  --age age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm \
  vcenter-credentials.yaml > vcenter-credentials.enc.yaml
rm vcenter-credentials.yaml
# Drei-Gate-Verifikation:
test -s vcenter-credentials.enc.yaml && echo "Gate1 OK"
grep -q "sops:" vcenter-credentials.enc.yaml && echo "Gate2 OK"
sops --decrypt vcenter-credentials.enc.yaml | grep -E "VCENTER_(USERNAME|PASSWORD)"
git add vcenter-credentials.enc.yaml && git commit -m "..." && git push
```
Etappe 2: ArgoCD-Apps pushen. Danach ggf. Hard-Refresh der App-of-Apps
(dev-infrastructure) und der Instanz-App.

Der remote-write-receiver-Change (monitoring/values-override.yaml) loest EINEN
Prometheus-Pod-Neustart aus (StatefulSet-Rollout). In DEV unkritisch.

## Schritt 5 - Verifikation nach Rollout

```
# Secrets vorhanden?
kubectl --context k8s-<env> -n monitoring get secret vcenter-credentials vcenter-ca-bundle
# Pod laeuft, Image v1.17.x, experimental-Flag?
kubectl --context k8s-<env> -n monitoring get pods -l app.kubernetes.io/instance=alloy-vcenter
# Logs: kein TLS-/Auth-Fehler? (vSAN-UUID-Hinweise sind harmlos)
kubectl --context k8s-<env> -n monitoring logs <pod> -c alloy --tail=60
```
Metriken in Prometheus (erster Performance-Counter-Zyklus dauert bis ~5-10 min):
```
count(vcenter_host_cpu_usage_MHz) by (vcenter)     # -> a:3, b:3
vcenter_host_cpu_utilization_percent               # -> Label vcenter_host gesetzt?
vcenter_host_disk_latency_avg_milliseconds         # -> Latenz (kommt spaeter als CPU/RAM)
```

## Metrik-Referenz (Auswahl, fuer Kapazitaetsplanung)

- Host-CPU: vcenter_host_cpu_capacity_MHz, _usage_MHz, _utilization_percent
- Host-RAM: vcenter_host_memory_capacity_mebibytes (Default AUS -> aktiviert!),
  _usage_mebibytes, _utilization_percent
- "RAM frei fuer neue Nodes" = capacity_mebibytes - usage_mebibytes
- Overcommit: vcenter_vm_cpu_readiness_percent (Ready-Time),
  vcenter_vm_memory_ballooned_mebibytes, vcenter_vm_memory_swapped_mebibytes
- Latenz: vcenter_host_disk_latency_avg_milliseconds / _max_milliseconds
  (Labels: vcenter_host, direction=read/write, object=LUN/NAA-ID)
- Datastore: vcenter_datastore_disk_utilization_percent, _usage_bytes
- Cluster: vcenter_cluster_cpu_effective_MHz, _memory_effective_bytes

Zusatz-Labels (via transform + external_labels): vcenter (a/b), vcenter_host,
vcenter_datastore, vcenter_cluster, vcenter_vm, env, source=alloy-vcenter.

## Troubleshooting

- **ArgoCD "chart not found"**: Chart-Version nicht im Helm-Index. Verfuegbare
  Versionen mit scripts/list-alloy-versions.ps1 pruefen, targetRevision anpassen.
- **Pod CrashLoop / Auth-Fehler**: Secret vcenter-credentials fehlt oder falsches
  PW. Reihenfolge (secret-first) pruefen.
- **x509 / TLS-Fehler**: CA-Bundle falsch/unvollstaendig. Beide VMCA-Roots im
  Bundle? Endpoint via FQDN (nicht IP), da Zert auf FQDN ausgestellt (SAN).
- **Metriken ohne Host-Label**: transform-Processor greift nicht. Syntax pruefen:
  set(datapoint.attributes[...], resource.attributes["vcenter.host.name"]).
- **Latenz-Metriken fehlen**: Braucht einen vollen Performance-Counter-Zyklus
  (bis ~10 min nach Start). Wenn dauerhaft fehlend: vCenter-Statistiklevel pruefen
  (Configure > General > Statistics, Level >=2) oder Performance.ModifyIntervals
  am User pruefen.
- **vSAN-UUID-Log ("couldn't determine UUID...")**: harmlos, Cluster ohne vSAN.
- **Style-Warn "paths modified to include context prefix"**: transform-Statements
  auf datapoint.attributes[...] umstellen (nicht attributes[...]).

## Rollout-Status

- DEV: abgeschlossen 03.07.2026 (beide vCenter, ~40 Metriken, Dashboard live)
- TEST: offen
- PROD: offen
