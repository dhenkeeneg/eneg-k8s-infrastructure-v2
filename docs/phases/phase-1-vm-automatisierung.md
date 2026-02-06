# Phase 1: Ubuntu-Template & VM-Automatisierung

**Status:** ✅ Abgeschlossen  
**Zeitraum:** 05.02.2026 - 06.02.2026  
**Bearbeiter:** D. Henke / Claude AI

---

## Ziel

Automatisierte Erstellung von Ubuntu 24.04 VM-Templates und Deployment der DEV-Cluster-VMs auf zwei unterschiedlichen vCenter-Umgebungen.

---

## Erreichte Ergebnisse

### Packer Templates

| Template | vCenter | ESXi Version | VM Version | Datastore |
|----------|---------|--------------|------------|-----------|
| ubuntu-24.04-k8s-template | vcenter.eneg.de | 6.7 | 14 | S2842_D08-10_R5_SSD_K8s |
| ubuntu-24.04-k8s-template | vcenter-a.eneg.de | 8.0 | 21 | S2843_SSD_01_VMS |

### DEV-Cluster VMs

| VM | Host | vCenter | IP | Status |
|----|------|---------|-----|--------|
| k8s-dev-21 | s2842.eneg.de | vcenter.eneg.de | 192.168.180.21 | ✅ Läuft |
| k8s-dev-22 | s2843.eneg.de | vcenter-a.eneg.de | 192.168.180.22 | ✅ Läuft |
| k8s-dev-23 | s3168.eneg.de | vcenter-a.eneg.de | 192.168.180.23 | ✅ Läuft |

### VM-Spezifikationen (DEV)

- **OS:** Ubuntu 24.04 LTS
- **vCPU:** 4
- **RAM:** 12 GB
- **Disk:** 384 GB (Thin Provisioned, LVM)
- **Netzwerk:** VT 180 - K8s Dev (VLAN 180)

---

## Erstellte Dateien

```
packer/
└── ubuntu-24.04/
    ├── ubuntu-24.04.pkr.hcl              # Packer Template
    ├── variables-vcenter-a.pkrvars.hcl   # Variablen für vCenter-A (ESXi 8.0)
    ├── variables-vcenter-legacy.pkrvars.hcl  # Variablen für vCenter Legacy (ESXi 6.7)
    ├── credentials.example.pkrvars.hcl   # Beispiel für Credentials
    ├── http/
    │   └── user-data.pkrtpl.hcl          # Cloud-init Autoinstall Template
    └── scripts/
        └── cleanup.sh                     # Template Cleanup Script

terraform/
├── modules/
│   └── vm/
│       ├── main.tf                       # VM-Ressource mit Clone & Customization
│       ├── variables.tf                  # Modul-Variablen
│       ├── outputs.tf                    # Modul-Outputs
│       └── README.md                     # Modul-Dokumentation
└── environments/
    └── dev/
        ├── main.tf                       # Dual-Provider Konfiguration
        ├── variables.tf                  # Environment-Variablen
        ├── vms.tf                        # VM-Definitionen (3 Nodes)
        ├── folders.tf                    # vCenter Folder-Struktur
        ├── outputs.tf                    # Cluster-Info Output
        └── credentials.example.tfvars    # Beispiel für Credentials
```

---

## Kritische Learnings

### 1. VMware Guest Customization + Ubuntu 24.04

**Problem:** `hwclock` fehlt seit Ubuntu 23.10 → Guest Customization schlägt fehl mit Exit Code 251

**Lösung:** Paket `util-linux-extra` im Template installieren (NICHT `util-linux`!)

```yaml
# In user-data.pkrtpl.hcl
packages:
  - open-vm-tools
  - util-linux-extra  # Enthält hwclock!
  - perl
```

**Referenz:** [Broadcom KB 313422](https://knowledge.broadcom.com/external/article/313422)

### 2. SSH Host Keys nach Clone

**Problem:** SSH-Dienst startet nicht, weil Host-Keys im Template gelöscht wurden

**Lösung:** Systemd-Service der Keys beim ersten Boot regeneriert:

```yaml
# In user-data.pkrtpl.hcl (late-commands)
- |
  cat > /target/etc/systemd/system/regenerate-ssh-host-keys.service << 'SVCEOF'
  [Unit]
  Description=Regenerate SSH Host Keys
  Before=ssh.service
  ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

  [Service]
  Type=oneshot
  ExecStart=/usr/bin/ssh-keygen -A

  [Install]
  WantedBy=multi-user.target
  SVCEOF
- curtin in-target -- systemctl enable regenerate-ssh-host-keys.service
```

### 3. Netplan Konfigurationskonflikt

**Problem:** VMware Guest Customization erstellt eigene Netplan-Config, aber alte Config aus Template existiert noch → "Conflicting default route" Fehler

**Lösung:** Alle Netplan-Configs im Template Cleanup löschen:

```bash
# In cleanup.sh oder Packer shell provisioner
sudo rm -f /etc/netplan/*.yaml
```

### 4. VM Hardware Version (ESXi Kompatibilität)

**Problem:** ESXi 6.7 unterstützt maximal VM Version 14, ESXi 8.0 unterstützt bis Version 21

**Lösung:** Variable `vm_version` in Packer für jede Umgebung setzen:

```hcl
# variables-vcenter-legacy.pkrvars.hcl
vm_version = 14

# variables-vcenter-a.pkrvars.hcl  
vm_version = 21
```

### 5. vCenter Ressourcen-Namen sind case-sensitive

**Problem:** `S2843.eneg.de` funktioniert nicht, `s2843.eneg.de` schon

**Lösung:** Exakte Schreibweise mit `govc` verifizieren:

```bash
govc ls /eNeG-Datacenter/host/
```

### 6. DNS Search Domain

**Problem:** `ping k8s-dev-22` funktioniert nicht (nur FQDN)

**Lösung:** `dns_suffix_list` im OpenTofu VM-Modul setzen:

```hcl
dns_suffix_list = ["eneg.de"]
```

---

## Befehle Referenz

### Packer Template bauen

```bash
cd ~/git/eneg-k8s-infrastructure-v2/packer/ubuntu-24.04

# vCenter Legacy (ESXi 6.7)
packer build -force \
  -var-file="credentials.auto.pkrvars.hcl" \
  -var-file="variables-vcenter-legacy.pkrvars.hcl" \
  ubuntu-24.04.pkr.hcl

# vCenter-A (ESXi 8.0)
packer build -force \
  -var-file="credentials.auto.pkrvars.hcl" \
  -var-file="variables-vcenter-a.pkrvars.hcl" \
  ubuntu-24.04.pkr.hcl
```

### OpenTofu DEV-VMs deployen

```bash
cd ~/git/eneg-k8s-infrastructure-v2/terraform/environments/dev

# Initialisieren (einmalig)
tofu init

# Plan prüfen
tofu plan

# Anwenden
tofu apply

# Einzelne VM neu erstellen
tofu destroy -target=module.k8s_dev_21
tofu apply -target=module.k8s_dev_21
```

### SSH-Zugriff testen

```bash
ssh admin-ubuntu@192.168.180.21
ssh admin-ubuntu@192.168.180.22
ssh admin-ubuntu@192.168.180.23
```

---

## Offene Punkte für spätere Phasen

| Punkt | Beschreibung | Geplant in Phase |
|-------|--------------|------------------|
| SSH-Key Only | Passwort-Login deaktivieren, nur SSH-Keys | Phase 2 |
| TEST/PROD VMs | Environments für TEST und PROD erstellen | Phase 8 |
| Template Updates | Prozess für regelmäßige Template-Aktualisierung | Phase 10 |

---

## Credentials (nicht im Git!)

Folgende Dateien müssen manuell erstellt werden:

```bash
# Packer
packer/ubuntu-24.04/credentials.auto.pkrvars.hcl

# OpenTofu
terraform/environments/dev/credentials.auto.tfvars
```

Werte sind in 1Password unter "K8s Infrastructure v2" gespeichert.

---

## Änderungshistorie

| Datum | Änderung |
|-------|----------|
| 06.02.2026 | Phase 1 abgeschlossen, Dokumentation erstellt |
| 05.02.2026 | Packer Templates und OpenTofu Konfiguration erstellt |
