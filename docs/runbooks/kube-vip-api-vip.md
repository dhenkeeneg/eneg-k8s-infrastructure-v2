# Runbook: kube-vip API-Server VIP (Control-Plane HA)

**Kategorie:** Cluster / Control-Plane / Hochverfuegbarkeit
**Erstellt:** 06.07.2026 (DEV-Rollout, vor TEST-Migration auf neuen VMware-Host)
**Stichworte:** kube-vip, API-Server-VIP, tls-san, ARP, Leader-Election, Failover, kubeconfig-Endpoint

---

## Zweck / Problem

Der kubeconfig-Endpoint jeder Umgebung hing fest an der IP von Node 1
(dev=192.168.180.21, test=192.168.179.21, prod=192.168.178.21). Wird Node 1
heruntergefahren (z.B. bei VM-Migration auf einen neuen VMware-Host), verliert
man den kubectl-/k9s-/MCP-Zugriff auf den GESAMTEN Cluster, obwohl Node 2+3
laufen.

Loesung: Eine hochverfuegbare API-Server-VIP via kube-vip. Der kubeconfig-
Endpoint zeigt auf die VIP (bzw. deren DNS-Namen), und ein Node-Ausfall kappt
den Zugriff nicht mehr - die VIP wandert per Leader-Election auf einen
lebenden Node.

## Eckdaten je Umgebung

| Umgebung | VIP             | DNS-Name              | Node-Subnetz      | Interface |
|----------|-----------------|-----------------------|-------------------|-----------|
| DEV      | 192.168.180.20  | k8s-dev-api.eneg.de   | 192.168.180.0/24  | ens160    |
| TEST     | 192.168.179.20  | k8s-test-api.eneg.de  | 192.168.179.0/24  | ens160    |
| PROD     | 192.168.178.20  | k8s-prod-api.eneg.de  | 192.168.178.0/24  | ens160    |

- **kube-vip Version:** v1.2.0
- **Modus:** ARP (Layer 2), alle Nodes je Cluster im selben Subnetz
- **Betriebsart:** nur Control-Plane (cp_enable=true), KEIN Service-LB
- **Deployment:** K3s Auto-Deploy Manifest via Ansible

## WICHTIG - Koexistenz mit MetalLB

MetalLB (L2-Modus) und kube-vip (ARP) nutzen beide Gratuitous ARP. Sie
koexistieren konfliktfrei, SOLANGE sie disjunkte IPs verwalten.

- Die VIP `.20` liegt AUSSERHALB der MetalLB-Pools.
- DEV MetalLB-Pool: `.100` + `.151-.199` -> `.20` ist frei.
- **Die VIP darf NIEMALS in einen MetalLB-IPAddressPool aufgenommen werden.**
- Vor Rollout in TEST/PROD: MetalLB-Pool der Umgebung pruefen, dass `.20` frei ist.

---

## Architektur / Dateien

**kube-vip-Manifest (pro Umgebung):**
`ansible/files/kube-vip/kube-vip-<env>.yaml`
Enthaelt: ServiceAccount + ClusterRole + ClusterRoleBinding + DaemonSet.

**Playbook:**
`ansible/playbooks/10-kube-vip-deploy.yml`
- Play 1: TLS-SAN erweitern (config.yaml sync + rolling K3s-Restart, serial:1)
- Play 2: kube-vip-Manifest nach /var/lib/rancher/k3s/server/manifests/ verteilen
- Play 3: Verifikation (Pods, Lease, VIP-Erreichbarkeit)
Tags: `san` (nur SAN), `kube-vip` (nur Manifest+Verify)

**group_vars (pro Umgebung):** `ansible/inventory/<env>/group_vars/all.yml`
- `k3s_tls_san`: erweitert um VIP-IP + DNS-Name
- `kube_vip_address`, `kube_vip_interface`, `kube_vip_version`, `kube_vip_manifest_src`

**K3s-Config-Template:** `ansible/templates/k3s-config.yaml.j2`
Rendert `tls-san` aus `k3s_tls_san`. Auf den Nodes: `/etc/rancher/k3s/config.yaml`.

## Kritische Design-Entscheidungen (WARUM es so gebaut ist)

### 1. kube-vip nutzt die LOKALE K3s-Kubeconfig, NICHT die ClusterIP

kube-vip darf NICHT ueber die ClusterIP `10.43.0.1` auf die Leader-Lease
zugreifen (das ist der `--inCluster`-Default). Grund: Bei Node-Ausfall wird
die ClusterIP-Aufloesung (kube-proxy) instabil - genau dann, wenn kube-vip
den Failover koordinieren muss. Ergebnis waere: KEIN Leader-Wechsel, VIP
bleibt weg. (Siehe Stolperstein 1.)

Loesung: Der Pod mountet `/etc/rancher/k3s/k3s.yaml` (world-readable dank
`write-kubeconfig-mode: "0644"`) read-only nach `/etc/kubernetes/admin.conf`
(der Pfad, den kube-vip im Container erwartet). Damit spricht jede Instanz
mit IHREM lokalen API-Server.

### 2. hostAlias `kubernetes` -> 127.0.0.1

kube-vip spricht den API-Server intern ueber den Hostnamen `kubernetes` an.
Ohne Aufloesung schlaegt das fehl (`lookup kubernetes ... server misbehaving`)
-> kube-vip wird nicht Leader -> VIP wird nicht aufgelegt. (Siehe Stolperstein 2.)

Loesung: `hostAliases` mappt `kubernetes` auf `127.0.0.1`. Da der Pod
`hostNetwork: true` nutzt, ist das der lokale API-Server des Nodes.

### 3. Lease-Timings 5/3/1 (statt Default 15/10/2)

`vip_leaseduration: 5`, `vip_renewdeadline: 3`, `vip_retryperiod: 1`.
Ergibt Failover in wenigen Sekunden statt >15s. Erprobt und stabil.

### 4. Nur Control-Plane, kein Service-LB

kube-vip macht ausschliesslich `cp_enable: true`. Service-LoadBalancing
bleibt bei MetalLB. Klare Trennung, keine Ueberschneidung der Zustaendigkeiten.

---

## Rollout-Prozedur (erprobt in DEV, gleich fuer TEST/PROD)

**Absolute Regel:** Erst DEV komplett, dann TEST, dann PROD. Niemals mehrere
Umgebungen gleichzeitig.

**Vorbereitung (pro Umgebung, einmalig):**
1. DNS-A-Record `k8s-<env>-api.eneg.de` -> VIP `.20` anlegen (im internen DNS).
2. Pruefen: VIP `.20` liegt ausserhalb des MetalLB-Pools der Umgebung.
3. Node-Interface bestaetigen (`ip -brief addr show` -> `ens160`).
4. kube-vip-Manifest `kube-vip-<env>.yaml` aus DEV-Vorlage ableiten
   (VIP-IP + ggf. Interface anpassen).
5. `k3s_tls_san` in `inventory/<env>/group_vars/all.yml` um VIP + DNS erweitern.
6. kube_vip_*-Variablen in derselben group_vars ergaenzen.

**Etappe 1 - TLS-SAN erweitern (rolling):**
```bash
cd ~/git/eneg-k8s-infrastructure-v2/ansible
# Trockenlauf (aendert NICHTS):
ansible-playbook -i inventory/<env>/hosts.ini playbooks/10-kube-vip-deploy.yml --tags san --check --diff
# Scharf (node-fuer-node K3s-Restart, serial:1):
ansible-playbook -i inventory/<env>/hosts.ini playbooks/10-kube-vip-deploy.yml --tags san
```
Zwischenverifikation:
```bash
# SAN im Zertifikat (auf einem Node, mit hostname-Check!):
echo | openssl s_client -connect <node1-ip>:6443 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
# -> muss VIP-IP + k8s-<env>-api.eneg.de enthalten
nslookup k8s-<env>-api.eneg.de   # -> VIP .20
```

**Etappe 2 - kube-vip verteilen:**
```bash
ansible-playbook -i inventory/<env>/hosts.ini playbooks/10-kube-vip-deploy.yml --tags kube-vip
```
Verifikation:
```bash
kubectl --context k8s-<env> -n kube-system get pods -l app.kubernetes.io/name=kube-vip-ds -o wide
kubectl --context k8s-<env> -n kube-system get lease plndr-cp-lock
# Logs des Leaders: "Successfully acquired lease" + "layer 2 broadcaster starting IP=.20"
# NICHT enthalten sein duerfen: "10.43.0.1 connection refused", "lookup kubernetes ... server misbehaving"
```

**Etappe 3 - kubeconfig umstellen (mit Sicherheitsnetz):**
```bash
# Backup:
cp ~/.kube/config ~/.kube/config.backup-$(date +%Y%m%d-%H%M%S)
# Test OHNE Umstellung (temporaere Kopie):
sed 's|https://<node1-ip>:6443|https://k8s-<env>-api.eneg.de:6443|' ~/.kube/config > /tmp/kubeconfig-viptest.yaml
KUBECONFIG=/tmp/kubeconfig-viptest.yaml kubectl get nodes   # -> muss klappen
# Echte Umstellung (nur die <env>-Zeile!):
sed -i 's|https://<node1-ip>:6443|https://k8s-<env>-api.eneg.de:6443|' ~/.kube/config
kubectl config use-context k8s-<env> && kubectl get nodes
rm -f /tmp/kubeconfig-viptest.yaml
```

**Etappe 4 - Failover-Test (der eigentliche Beweis):**
```bash
# Aktuellen Leader ermitteln:
kubectl --context k8s-<env> -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
# Poll-Schleife (Fenster B, ueber VIP):
while true; do echo -n "$(date +%H:%M:%S): "; kubectl get nodes --request-timeout=2s -o name 2>&1 | tr '\n' ' '; echo; sleep 1; done
# Fenster A - auf dem LEADER-Node (hostname-Check PFLICHT!):
hostname   # MUSS der Leader-Node sein
sudo systemctl stop k3s
# Beobachten: kurze Luecke, dann Zugriff wieder da (VIP gewandert). >=60s laufen lassen.
# Danach Node zurueckholen:
hostname   # MUSS derselbe Node sein
sudo systemctl start k3s
```
Erfolgskriterium: `leaseTransitions` erhoeht sich, `holderIdentity` wechselt,
Zugriff ueber VIP funktioniert waehrend des Ausfalls durchgehend (nach kurzer Luecke).

---

## Stolpersteine (in DEV aufgetreten und geloest)

### Stolperstein 1: Kein Failover - "10.43.0.1:443 connection refused"

**Symptom:** kube-vip laeuft, VIP wird aufgelegt, aber bei Node-Ausfall wandert
die VIP NICHT. Lease `plndr-cp-lock` bleibt beim ausgefallenen Node kleben
(`leaseTransitions: 0`). Zugriff ueber VIP bricht komplett weg.

**Log-Signatur (auf einem ueberlebenden Node):**
```
Error retrieving lease lock err="Get https://10.43.0.1:443/.../leases/plndr-cp-lock:
  dial tcp 10.43.0.1:443: connect: connection refused"
```

**Ursache:** kube-vip im `--inCluster`-Modus greift ueber die ClusterIP
`10.43.0.1` auf die Lease zu. Bei Node-Ausfall ist die ClusterIP-Aufloesung
instabil - genau dann, wenn Failover noetig ist. Henne-Ei-Problem.

**Behebung:** kube-vip auf lokale K3s-Kubeconfig umstellen (Design-Entscheidung 1):
volumeMount `/etc/kubernetes/admin.conf` + hostPath auf `/etc/rancher/k3s/k3s.yaml`.

### Stolperstein 2: VIP wird nicht aufgelegt - "lookup kubernetes server misbehaving"

**Symptom:** Nach Umstellung auf lokale kubeconfig legt kube-vip die VIP GAR
NICHT mehr auf. `no route to host` auf die VIP. Kein Leader.

**Log-Signatur:**
```
Error retrieving lease lock err="Get https://kubernetes:6443/.../plndr-cp-lock:
  dial tcp: lookup kubernetes on <dns-ip>:53: server misbehaving"
```

**Ursache:** kube-vip spricht den API-Server ueber den Namen `kubernetes` an.
Dieser Name ist ausserhalb des Cluster-DNS nicht aufloesbar (der Pod nutzt
mit hostNetwork den Node-Resolver, nicht CoreDNS).

**Behebung:** `hostAliases` mappt `kubernetes` -> `127.0.0.1` (Design-Entscheidung 2).

**Merke:** Beide Fixes gehoeren ZUSAMMEN. Erst lokale kubeconfig, dann der
hostAlias. Ohne den Alias fuehrt die lokale kubeconfig zu Stolperstein 2.

## Rollback

kube-vip laesst sich rueckstandsfrei entfernen. Der Cluster bleibt ueber die
direkten Node-IPs jederzeit erreichbar (kube-vip liegt nur "obendrauf").

```bash
# 1. kubeconfig zurueck auf Node-IP (falls schon umgestellt):
sed -i 's|https://k8s-<env>-api.eneg.de:6443|https://<node1-ip>:6443|' ~/.kube/config

# 2. Manifest auf allen Nodes entfernen (SSH, hostname-Check pro Node!):
sudo rm /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
#    -> K3s de-deployt das DaemonSet automatisch. VIP verschwindet.

# 3. Reste aufraeumen (einmalig, ueber einen Node):
kubectl -n kube-system delete daemonset kube-vip-ds --ignore-not-found
kubectl -n kube-system delete lease plndr-cp-lock --ignore-not-found

# 4. Optional: tls-san-Erweiterung ist rein additiv und kann bleiben (schadet nie).
```

**Wichtig bei Node-Ausfall waehrend Betrieb:** kube-vip macht KEIN automatisches
Failback. Kommt der Ex-Leader zurueck, bleibt die VIP beim aktuellen Leader.
Das ist gewollt (keine unnoetige Unterbrechung).

## Diagnose-Schnellreferenz

```bash
# Wer haelt die VIP?
kubectl --context k8s-<env> -n kube-system get lease plndr-cp-lock \
  -o jsonpath='Holder={.spec.holderIdentity} Transitions={.spec.leaseTransitions}{"\n"}'

# Laufen alle kube-vip-Pods?
kubectl --context k8s-<env> -n kube-system get pods -l app.kubernetes.io/name=kube-vip-ds -o wide

# Leader-Logs (ARP-Broadcast bestaetigen):
kubectl --context k8s-<env> -n kube-system logs <leader-pod> --tail=15
#   Gut:    "layer 2 broadcaster starting IP=.20 device=ens160"
#   Schlecht: "10.43.0.1 connection refused" | "lookup kubernetes ... server misbehaving"

# VIP netzwerkseitig erreichbar?
kubectl --context k8s-<env> get nodes   # ueber VIP-kubeconfig -> muss Nodes listen
```

## Verwandte Themen

- kube-vip Doku: https://kube-vip.io/docs/
- K3s + kube-vip (Control-Plane): https://kube-vip.io/docs/usage/k3s/
- TEST-Cluster-Migration auf neuen VMware-Host: Voraussetzung fuer diese Migration
  war der kube-vip-Fix (sonst Verlust der kubectl-/MCP-Sicht beim Verschieben von Node 1).
- Runbook `test-cluster-wiederanlauf.md` (verwandter Kontext TEST-Cluster).
- Ansible K3s-Install: `playbooks/02-install-k3s.yml`, Template `templates/k3s-config.yaml.j2`.

## Voraussetzung / Nebenbefund: inotify-Limits (TEST-Rollout 06.07.2026)

Beim TEST-Failover-Test warf `systemctl stop k3s` auf k8s-test-21
`Failed to allocate directory watch: Too many open files`. Ursache: Die
inotify-Limits standen auf Ubuntu-24.04-Defaults (`max_user_instances=128`,
`max_user_watches` kernel-berechnet ~124126) statt der eNeG-Zielwerte
(`8192` / `524288`). Das Ansible-Playbook `06-sysctl-inotify-limits.yml`
(Phase 9a) war auf TEST nie erfolgreich gelaufen (Nodes aelter als der Fix,
Playbook lief waehrend TEST-Deaktivierung nicht nach).

**Wichtig vor jeder Node-Migration / kube-vip-Rollout:** inotify-Limits
pruefen und ggf. `06-sysctl-inotify-limits.yml` ausfuehren:
```bash
# Pruefen (pro Node, mit hostname-Check):
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
# Erwartung: 8192 / 524288. Falls Defaults -> Playbook ausfuehren:
ansible-playbook -i inventory/<env>/hosts.ini playbooks/06-sysctl-inotify-limits.yml
```
Status je Umgebung (06.07.2026): DEV OK, TEST heute gefixt, PROD offen
(Nodes aus; Packer-Template + Playbook vorhanden, Live-Pruefung bei
Reaktivierung noetig).

## Rollout-Status

| Umgebung | TLS-SAN | kube-vip | kubeconfig | Failover-Test | Datum       |
|----------|---------|----------|------------|---------------|-------------|
| DEV      | OK      | OK       | OK         | OK            | 06.07.2026  |
| TEST     | OK      | OK       | OK         | OK            | 06.07.2026  |
| PROD     | offen   | offen    | offen      | offen         | -           |
