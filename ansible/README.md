# Ansible Configuration for eNeG K8s Infrastructure v2

## Verzeichnisstruktur

```
ansible/
├── ansible.cfg              # Ansible-Konfiguration
├── inventory/               # Inventories für alle Umgebungen
│   └── dev/
│       ├── hosts.ini        # DEV-Cluster Hosts
│       └── group_vars/
│           ├── all.yml      # Globale Variablen
│           └── secrets.example.yml  # Beispiel für Secrets
├── playbooks/               # Ansible Playbooks
│   ├── 01-setup-ssh-keys.yml     # SSH-Keys verteilen
│   └── 02-install-k3s.yml        # K3s Installation
├── roles/                   # Ansible Rollen
│   ├── common/              # Basis-System-Setup
│   │   └── tasks/
│   │       └── main.yml
│   └── k3s/                 # K3s-Installation
│       ├── tasks/
│       │   └── main.yml
│       ├── handlers/
│       │   └── main.yml
│       └── templates/
└── templates/               # Globale Templates
    ├── authorized_keys.j2
    └── k3s-config.yaml.j2
```

## Vorbereitung

### 1. Secrets-Datei erstellen

```bash
cd inventory/dev/group_vars
cp secrets.example.yml secrets.yml
nano secrets.yml
```

Tragen Sie Ihre tatsächlichen Werte ein:
- SSH Public Keys von allen Arbeitsstationen
- K3s Token (wird automatisch generiert, wenn leer gelassen)

### 2. Hosts-Datei prüfen

Prüfen Sie `inventory/dev/hosts.ini` und passen Sie IPs an falls nötig.

## Verwendung

### SSH-Keys verteilen (einmalig)

```bash
# Auf der Management-VM (k8s-mgmt-10)
cd ~/git/eneg-k8s-infrastructure-v2/ansible

# Test-Verbindung mit Passwort-Authentifizierung
ansible all -i inventory/dev/hosts.ini -m ping --ask-pass

# SSH-Keys verteilen
ansible-playbook -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml --ask-pass
```

Nach diesem Schritt sollte passwortlose SSH-Authentifizierung funktionieren.

### K3s Cluster installieren

```bash
# Verbindung testen (ohne --ask-pass)
ansible all -i inventory/dev/hosts.ini -m ping

# K3s installieren
ansible-playbook -i inventory/dev/hosts.ini playbooks/02-install-k3s.yml

# Mit Tags nur bestimmte Schritte ausführen
ansible-playbook -i inventory/dev/hosts.ini playbooks/02-install-k3s.yml --tags common
ansible-playbook -i inventory/dev/hosts.ini playbooks/02-install-k3s.yml --tags k3s
```

## Nach der Installation

### Kubeconfig abrufen

```bash
# Von k8s-dev-21 (erster Master-Node)
scp k8sadmin@192.168.180.21:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# IP-Adresse im kubeconfig anpassen
sed -i 's/127.0.0.1/192.168.180.21/g' ~/.kube/config
```

### Cluster-Status prüfen

```bash
kubectl get nodes
kubectl get pods -A
```

Alle 3 Nodes sollten "Ready" sein.

## Troubleshooting

### Ansible kann VMs nicht erreichen

```bash
# Ping-Test
ansible all -i inventory/dev/hosts.ini -m ping

# Detaillierte Ausgabe
ansible all -i inventory/dev/hosts.ini -m ping -vvv
```

### K3s startet nicht

```bash
# Auf dem betroffenen Node
ssh k8sadmin@192.168.180.21
sudo systemctl status k3s
sudo journalctl -u k3s -f
```

### Cluster-Bildung schlägt fehl

```bash
# Token vom ersten Master prüfen
ssh k8sadmin@192.168.180.21
sudo cat /var/lib/rancher/k3s/server/node-token
```

## Nützliche Commands

```bash
# Nur bestimmte Hosts ansprechen
ansible k8s_master -i inventory/dev/hosts.ini -m ping

# Befehle auf allen Hosts ausführen
ansible all -i inventory/dev/hosts.ini -a "uptime"

# Fakten sammeln
ansible all -i inventory/dev/hosts.ini -m setup
```

## Wichtige Hinweise

- **Reihenfolge beachten:** Erst `01-setup-ssh-keys.yml`, dann `02-install-k3s.yml`
- **Secrets nicht committen:** `secrets.yml` ist in `.gitignore` eingetragen
- **Token-Generierung:** Wenn `k3s_token` in secrets.yml leer ist, wird automatisch ein Token generiert
- **HA-Setup:** K3s nutzt embedded etcd mit `--cluster-init` für HA über 3 Master-Nodes
