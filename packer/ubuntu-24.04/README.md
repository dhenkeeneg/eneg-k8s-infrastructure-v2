# Ubuntu 24.04 Packer Template

Dieses Verzeichnis enthält die Packer-Konfiguration für das Ubuntu 24.04 LTS VM-Template.

## Dateien

| Datei | Beschreibung |
|-------|--------------|
| `ubuntu-24.04.pkr.hcl` | Haupt-Packer-Konfiguration |
| `variables.pkrvars.hcl` | Variablen (nicht-sensitiv) |
| `credentials.example.pkrvars.hcl` | Beispiel für Credentials |
| `http/user-data.pkrtpl.hcl` | Cloud-Init Autoinstall Konfiguration |
| `http/meta-data` | Cloud-Init Meta-Daten |

## Voraussetzungen

- Packer >= 1.10.0
- vSphere Plugin für Packer
- Zugang zu vCenter-A (vcenter-a.eneg.de)
- Ubuntu 24.04 ISO im Datastore

## Verwendung

### 1. Credentials-Datei erstellen

```bash
cd packer/ubuntu-24.04
cp credentials.example.pkrvars.hcl credentials.auto.pkrvars.hcl
# Datei bearbeiten und echte Werte eintragen
nano credentials.auto.pkrvars.hcl
```

### 2. Packer initialisieren

```bash
packer init ubuntu-24.04.pkr.hcl
```

### 3. Template validieren

```bash
packer validate -var-file=variables.pkrvars.hcl ubuntu-24.04.pkr.hcl
```

### 4. Template bauen

```bash
packer build -var-file=variables.pkrvars.hcl ubuntu-24.04.pkr.hcl
```

## Was das Template enthält

- Ubuntu 24.04 LTS (minimale Server-Installation)
- Deutsche Tastatur und Locale
- open-vm-tools (VMware Integration)
- Kernel-Module für Kubernetes (overlay, br_netfilter)
- Sysctl-Parameter für Container-Networking
- Benutzer: admin-ubuntu (sudo ohne Passwort)
- SSH-Server aktiviert

## Nach dem Build

Das Template wird automatisch als VM-Template in vCenter konvertiert:
- Name: `ubuntu-24.04-k8s-template`
- Ort: `eNeG-VM-Vorlagen/`
- Datastore: `S2843_HDD_00_BOOT`

## Sicherheitshinweise

- Die Datei `credentials.auto.pkrvars.hcl` enthält sensitive Daten
- Diese Datei ist in `.gitignore` und wird NICHT committed
- Passwörter sollten in 1Password gespeichert werden
