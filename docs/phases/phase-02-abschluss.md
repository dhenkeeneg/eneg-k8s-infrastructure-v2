# Phase 2: K3s HA-Cluster Installation - Abschlussdokument

**Status:** ✅ Abgeschlossen  
**Abgeschlossen am:** 09.02.2026  
**Dauer:** 1 Tag  
**Umgebung:** DEV (k8s-dev-21, k8s-dev-22, k8s-dev-23)

---

## Zusammenfassung

Phase 2 wurde erfolgreich abgeschlossen. Ein vollständig funktionsfähiger K3s High-Availability-Cluster mit 3 Control-Plane-Nodes läuft in der DEV-Umgebung. Die Installation erfolgt vollständig automatisiert über Ansible mit festen Versionsnummern für maximale Reproduzierbarkeit.

---

## Erreichte Ziele

### Infrastruktur
- ✅ **K3s HA-Cluster:** 3 Control-Plane Nodes mit embedded etcd
- ✅ **Version:** K3s v1.35.0+k3s3 (Kubernetes 1.35)
- ✅ **Nodes:** Alle Ready, vollständig funktionsfähig
- ✅ **Netzwerk:** Calico CNI aktiv und funktionsfähig
- ✅ **Core Services:** CoreDNS und metrics-server laufen

### Automatisierung
- ✅ **Ansible-Playbooks:** Vollständig funktionsfähige Installation
- ✅ **SSH-Key-Management:** 4 Workstations autorisiert
- ✅ **Versions-Management:** Feste Versionen statt Channels
- ✅ **Upgrade-Fähigkeit:** Automatische Versionserkennung implementiert
- ✅ **Idempotenz:** Playbooks können mehrfach ausgeführt werden

### Dokumentation
- ✅ **README.md:** Vollständige Ansible-Nutzungsanleitung
- ✅ **SSH-KEYS.md:** Quick Reference für SSH-Key-Management
- ✅ **SSH-KEY-MANAGEMENT.md:** Umfassende Dokumentation aller SSH-Prozesse

---

## Technische Details

### Cluster-Konfiguration

**Nodes:**
```
NAME         STATUS   ROLES                  AGE     VERSION
k8s-dev-21   Ready    control-plane,etcd     Active  v1.35.0+k3s3
k8s-dev-22   Ready    control-plane,etcd     Active  v1.35.0+k3s3
k8s-dev-23   Ready    control-plane,etcd     Active  v1.35.0+k3s3
```

**IP-Adressen:**
- k8s-dev-21: 192.168.180.21
- k8s-dev-22: 192.168.180.22
- k8s-dev-23: 192.168.180.23

**Deaktivierte Komponenten (für GitOps):**
- Traefik (wird in Phase 4 manuell installiert)
- ServiceLB (wird durch MetalLB ersetzt)
- Local-Storage (wird durch Longhorn ersetzt)

### Ansible-Struktur

```
ansible/
├── ansible.cfg              # Ansible 2.20+ kompatibel
├── README.md                # Nutzungsanleitung
├── SSH-KEYS.md              # Quick Reference
├── inventory/
│   └── dev/
│       ├── hosts.ini        # Inventory (3 Nodes, 2 Gruppen)
│       └── group_vars/
│           ├── all.yml      # K3s-Konfiguration
│           ├── secrets.yml  # SSH-Keys + Token (local only)
│           └── secrets.example.yml
├── playbooks/
│   ├── 01-setup-ssh-keys.yml    # SSH-Key-Distribution
│   └── 02-install-k3s.yml       # K3s HA-Installation
├── roles/
│   ├── common/              # System-Vorbereitung
│   └── k3s/                 # K3s-Installation
└── templates/
    ├── authorized_keys.j2   # SSH-Keys
    └── k3s-config.yaml.j2   # K3s-Konfiguration
```

### kubeconfig

**Speicherort:** `~/git/eneg-k8s-infrastructure-v2/kubeconfig-dev.yaml`

**Verwendung:**
```bash
export KUBECONFIG=~/git/eneg-k8s-infrastructure-v2/kubeconfig-dev.yaml
kubectl get nodes
```

---

## Wichtige Learnings

### 1. K3s Token-Format (KRITISCH!)

**Problem:** K3s verwendet zwei verschiedene Token-Formate:
- **Einfaches Password:** Für ersten Server (64 Zeichen alphanumerisch)
- **K10-Format:** Für zusätzliche Server (aus `/var/lib/rancher/k3s/server/node-token`)

**Lösung:**
```yaml
# First Server - einfaches Password
generated_k3s_token: "{{ lookup('password', '/dev/null chars=ascii_letters,digits length=64') }}"

# Additional Servers - K10 Token vom First Server
K3S_TOKEN={{ hostvars[groups['k3s_initial_server'][0]]['k3s_cluster_token'] }}
```

**Dokumentation:** https://docs.k3s.io/cli/token#token-format

### 2. Version Pinning statt Channels

**Problem:** K3s-Channels (`stable`, `latest`) können zu unerwarteten Upgrades führen.

**Lösung:** Feste Versionsnummern verwenden:
```yaml
k3s_version: "v1.35.0+k3s3"  # Fest gepinnt
# k3s_channel wird nicht mehr verwendet
```

**Installationsskript:**
```bash
INSTALL_K3S_VERSION={{ k3s_version }}  # Statt INSTALL_K3S_CHANNEL
```

### 3. Upgrade-Erkennung

**Problem:** `creates: /usr/local/bin/k3s` verhindert Upgrades.

**Lösung:** Installierte Version prüfen und vergleichen:
```yaml
- name: Installierte K3s Version prüfen
  ansible.builtin.shell: |
    if [ -f /usr/local/bin/k3s ]; then
      /usr/local/bin/k3s --version | head -n1 | awk '{print $3}'
    else
      echo "not_installed"
    fi
  register: k3s_current_version
  changed_when: false

- name: K3s installieren/upgraden
  when: k3s_current_version.stdout != k3s_version
  ...
```

### 4. Token-Konflikt bei Upgrades

**Problem:** Upgrade von v1.34.3 → v1.35.0 mit neuem Token führte zu:
```
failed to reconcile with local datastore: bootstrap data already found 
and encrypted with different token
```

**Root Cause:** etcd-Datenbank war mit altem Token verschlüsselt.

**Lösung:** Bei Major-Upgrades oder Token-Änderungen:
- Cluster deinstallieren: `/usr/local/bin/k3s-uninstall.sh`
- Frische Installation mit neuem Token

**Präventiv:** Token niemals ändern bei laufendem Cluster!

### 5. Ansible 2.20+ Callback-Plugin

**Problem:** `community.general.yaml callback plugin has been removed`

**Lösung:** `ansible.cfg` anpassen:
```ini
[defaults]
stdout_callback = default
result_format = yaml  # Statt stdout_callback = yaml
```

### 6. Username auf Nodes

**Wichtig:** Der SSH-Username ist **`admin-ubuntu`**, NICHT `k8sadmin`.

Dies gilt für:
- SSH-Zugriff
- Ansible `remote_user`
- kubeconfig-Erstellung

---

## Troubleshooting-Erfahrungen

### Problem: K3s Service startet nicht nach Installation

**Symptom:**
```
Job for k3s.service failed because the control process exited with error code.
```

**Diagnose:**
```bash
sudo journalctl -u k3s -n 50 --no-pager
```

**Häufige Ursachen:**
1. Token-Format falsch
2. Fehlende Kernel-Module
3. etcd-Datenbank-Probleme
4. Port 6443 bereits belegt

### Problem: Upgrade schlägt fehl

**Lösung:** Clean Reinstall bei Token-Änderungen:
```bash
# Auf allen Nodes
sudo /usr/local/bin/k3s-uninstall.sh

# Neu installieren
ansible-playbook -i inventory/dev/hosts.ini playbooks/02-install-k3s.yml
```

---

## Verwendete Versionen

| Komponente | Version | Hinweis |
|------------|---------|---------|
| K3s | v1.35.0+k3s3 | Fest gepinnt |
| Kubernetes | 1.35 | In K3s enthalten |
| Containerd | 2.1.5-k3s1 | In K3s enthalten |
| Ubuntu | 24.04.3 LTS | Kernel 6.8.0-71 |
| Ansible | 2.20.2 (core) | Auf k8s-mgmt-10 |
| kubectl | 1.35.0 | Auf k8s-mgmt-10 |

---

## Nächste Schritte (Phase 3)

**Phase 3: GitOps-Fundament**

Folgende Komponenten werden in Phase 3 installiert:
- [ ] ArgoCD für GitOps-Deployments
- [ ] SOPS + Age für Secret-Verschlüsselung
- [ ] GitHub Repository-Integration
- [ ] Base-Struktur für Kubernetes-Manifests

**Vorbereitung:**
- ✅ K3s-Cluster läuft stabil
- ✅ kubectl-Zugriff funktioniert
- ✅ Git-Repository vorhanden
- ✅ SSH-Keys für GitHub Deploy-Key bereit

---

## Wichtige Dateien und Pfade

### Auf Management-VM (k8s-mgmt-10)

**Repository:**
```
~/git/eneg-k8s-infrastructure-v2/
```

**kubeconfig:**
```
~/git/eneg-k8s-infrastructure-v2/kubeconfig-dev.yaml
```

**Ansible:**
```
~/git/eneg-k8s-infrastructure-v2/ansible/
```

### Auf K8s-Nodes

**K3s Binary:**
```
/usr/local/bin/k3s
```

**K3s Service:**
```
/etc/systemd/system/k3s.service
```

**K3s Daten:**
```
/var/lib/rancher/k3s/
```

**K3s Konfiguration:**
```
/etc/rancher/k3s/config.yaml
```

**Token (nur first server):**
```
/var/lib/rancher/k3s/server/node-token
```

---

## Kommandos Cheat Sheet

### Cluster-Status

```bash
# Nodes anzeigen
kubectl get nodes -o wide

# Pods aller Namespaces
kubectl get pods -A

# Cluster-Info
kubectl cluster-info

# K3s Version auf Node
ssh admin-ubuntu@192.168.180.21 '/usr/local/bin/k3s --version'
```

### Ansible

```bash
# SSH-Keys verteilen (einmalig)
cd ~/git/eneg-k8s-infrastructure-v2/ansible
ansible-playbook -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml --ask-pass

# K3s installieren/upgraden
ansible-playbook -i inventory/dev/hosts.ini playbooks/02-install-k3s.yml

# Node-Erreichbarkeit testen
ansible -i inventory/dev/hosts.ini all -m ping
```

### K3s Service

```bash
# Status prüfen
ssh admin-ubuntu@192.168.180.21 'sudo systemctl status k3s'

# Logs anzeigen
ssh admin-ubuntu@192.168.180.21 'sudo journalctl -u k3s -f'

# Service neu starten
ssh admin-ubuntu@192.168.180.21 'sudo systemctl restart k3s'

# Deinstallieren
ssh admin-ubuntu@192.168.180.21 'sudo /usr/local/bin/k3s-uninstall.sh'
```

---

## Git Commits (Phase 2)

Alle Änderungen wurden sauber committed und gepusht:

1. `46fb3d9` - Fix Ansible 2.20+ callback plugin configuration
2. `619a849` - Fix K3s token format (single colon)
3. `b70ef86` - Fix K3s token format (simple password for first server)
4. `eac8ab2` - Fix inventory group name (k3s_initial_server)
5. `b1a7365` - Fix additional servers token (use K10 from first server)
6. `e6239c2` - Fix token hostvars delegation
7. `74d5012` - Change K3s channel from stable to latest for K8s 1.35+
8. `fd0b4a2` - Pin K3s to version v1.35.0+k3s3
9. `89e3e8b` - Enable K3s upgrades by checking installed version

**Dokumentation:**
- `ansible/README.md` - Vollständige Nutzungsanleitung
- `ansible/SSH-KEYS.md` - Quick Reference
- `docs/SSH-KEY-MANAGEMENT.md` - Umfassende SSH-Dokumentation

---

## Lessons Learned Summary

**DO:**
- ✅ Feste Versionen verwenden (kein `latest` oder `stable`)
- ✅ Token niemals bei laufendem Cluster ändern
- ✅ Ansible-Playbooks idempotent gestalten
- ✅ Upgrade-Logik implementieren (Versions-Vergleich)
- ✅ Umfassende Dokumentation schreiben
- ✅ Learnings direkt dokumentieren (nicht später!)

**DON'T:**
- ❌ Token-Format verwechseln (Simple vs. K10)
- ❌ `creates` für Upgrades verwenden
- ❌ Upgrades ohne Token-Prüfung durchführen
- ❌ Channels ohne Version-Pinning nutzen
- ❌ SSH-Username vergessen (admin-ubuntu!)

---

**Ende Phase 2 - Bereit für Phase 3!** 🚀
