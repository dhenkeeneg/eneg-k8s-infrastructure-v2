# Ubuntu 24.04 Packer Template

Dieses Verzeichnis enthält die Packer-Konfiguration für das Ubuntu 24.04 LTS VM-Template.

**Letzter erfolgreicher Build:** 05.02.2026 (Build-Zeit: ~5 Minuten)

## Dateien

| Datei | Beschreibung |
|-------|--------------|
| `ubuntu-24.04.pkr.hcl` | Haupt-Packer-Konfiguration |
| `variables-vcenter-a.pkrvars.hcl` | Variablen für vCenter-A (HOST2, HOST3) |
| `variables-vcenter-legacy.pkrvars.hcl` | Variablen für vCenter Legacy (HOST1) |
| `credentials.example.pkrvars.hcl` | Beispiel für Credentials |
| `credentials.auto.pkrvars.hcl` | Echte Credentials (in .gitignore, nicht committed!) |
| `http/user-data.pkrtpl.hcl` | Cloud-Init Autoinstall Konfiguration |
| `http/meta-data` | Cloud-Init Meta-Daten (leer) |

## Zwei vCenter-Umgebungen

Da die Infrastruktur auf zwei vCenter verteilt ist, gibt es zwei Variablen-Dateien:

| vCenter | Variablen-Datei | Hosts | Template-Datastore |
|---------|-----------------|-------|-------------------|
| vCenter-A (vcenter-a.eneg.de) | `variables-vcenter-a.pkrvars.hcl` | s2843, s3168 | S2843_HDD_00_BOOT |
| vCenter Legacy (vcenter.eneg.de) | `variables-vcenter-legacy.pkrvars.hcl` | s2842 | S2842_D08-10_R5_SSD_K8s |

**Hinweis:** Templates können nicht zwischen den vCentern kopiert werden (unterschiedliche ESXi-Versionen). Daher muss in jedem vCenter ein eigenes Template erstellt werden.

## Voraussetzungen

- Packer >= 1.10.0
- vSphere Plugin für Packer
- Zugang zu vCenter-A (vcenter-a.eneg.de) und/oder vCenter Legacy (vcenter.eneg.de)
- Ubuntu 24.04 ISO im jeweiligen Datastore hochgeladen
- Netzwerkzugang von der Build-Maschine zum vCenter und zur temporären Build-IP (192.168.180.9)

## Verwendung

### 1. Credentials-Datei erstellen

```bash
cd ~/git/eneg-k8s-infrastructure-v2/packer/ubuntu-24.04
cp credentials.example.pkrvars.hcl credentials.auto.pkrvars.hcl
nano credentials.auto.pkrvars.hcl
```

Folgende Werte eintragen:
- `vcenter_username` - vCenter Benutzername
- `vcenter_password` - vCenter Passwort
- `ssh_password` - Klartext-Passwort für SSH-Verbindung während Build
- `ssh_password_hash` - SHA-512 Hash des Passworts für Ubuntu autoinstall

**SSH-Passwort-Hash generieren:**
```bash
# Option 1: Mit mkpasswd (empfohlen)
mkpasswd -m sha-512 "IhrPasswort"

# Option 2: Mit openssl
openssl passwd -6 "IhrPasswort"

# Option 3: Mit Python
python3 -c 'import crypt; print(crypt.crypt("IhrPasswort", crypt.mksalt(crypt.METHOD_SHA512)))'
```

### 2. Packer initialisieren

```bash
packer init ubuntu-24.04.pkr.hcl
```

### 3. Template validieren (optional)

```bash
# Für vCenter-A (HOST2, HOST3):
packer validate -var-file="credentials.auto.pkrvars.hcl" -var-file="variables-vcenter-a.pkrvars.hcl" ubuntu-24.04.pkr.hcl

# Für vCenter Legacy (HOST1):
packer validate -var-file="credentials.auto.pkrvars.hcl" -var-file="variables-vcenter-legacy.pkrvars.hcl" ubuntu-24.04.pkr.hcl
```

### 4. Template bauen

```bash
# Für vCenter-A (HOST2, HOST3):
packer build -var-file="credentials.auto.pkrvars.hcl" -var-file="variables-vcenter-a.pkrvars.hcl" ubuntu-24.04.pkr.hcl

# Für vCenter Legacy (HOST1):
packer build -var-file="credentials.auto.pkrvars.hcl" -var-file="variables-vcenter-legacy.pkrvars.hcl" ubuntu-24.04.pkr.hcl
```

## Was das Template enthält

- **OS:** Ubuntu 24.04 LTS (Standard Server-Installation, NICHT minimal)
- **Locale:** Deutsch (de_DE.UTF-8)
- **Tastatur:** Deutsch (nodeadkeys)
- **Kernel:** linux-image-6.8.0-71-generic (festgepinnt für Stabilität)
- **Storage:** LVM über gesamte Disk
- **Benutzer:** admin-ubuntu (sudo ohne Passwort)
- **SSH:** Aktiviert mit Passwort-Authentifizierung

### Vorinstallierte Pakete
- open-vm-tools (VMware Integration)
- qemu-guest-agent
- curl, wget, git, vim, htop

### Kubernetes-Vorbereitungen
- Kernel-Module: `overlay`, `br_netfilter`
- Sysctl-Parameter:
  - `net.bridge.bridge-nf-call-iptables = 1`
  - `net.bridge.bridge-nf-call-ip6tables = 1`
  - `net.ipv4.ip_forward = 1`

## Nach dem Build

Das Template wird automatisch als VM-Template in vCenter konvertiert:
- **Name:** `ubuntu-24.04-k8s-template`
- **Ort:** `eNeG-VM-Vorlagen/`
- **Datastore:** `S2843_HDD_00_BOOT`

---

## Bekannte Probleme und Lösungen

### Problem 1: `history -c` Fehler (Exit Code 127)

**Symptom:**
```
/tmp/script_XXXX.sh: 25: history: not found
Script exited with non-zero exit status: 127
```

**Ursache:** Der Befehl `history -c` ist ein Bash-Built-in, das nur in interaktiven Shells verfügbar ist. Packer führt Shell-Provisioner standardmäßig mit `/bin/sh` aus (nicht Bash) und in nicht-interaktivem Modus.

**Lösung:** Im Cleanup-Provisioner `history -c` ersetzen durch:
```hcl
"cat /dev/null > ~/.bash_history || true",
"sudo rm -f /root/.bash_history || true"
```

### Problem 2: DNS-Auflösung während Build

**Symptom:** `apt-get update` schlägt fehl, Pakete können nicht heruntergeladen werden.

**Ursache:** Die Build-VM verwendet die DNS-Server aus der Netzwerkkonfiguration, die möglicherweise nur intern auflösen.

**Lösung:** In `http/user-data.pkrtpl.hcl` werden explizit Google DNS-Server verwendet:
```yaml
nameservers:
  addresses:
    - 8.8.8.8
    - 8.8.4.4
```

### Problem 3: Kernel-Version Mismatch

**Symptom:** Nach dem Boot fehlen Module oder Dienste starten nicht.

**Ursache:** Ubuntu installiert möglicherweise einen neueren Kernel als auf der ISO.

**Lösung:** Kernel-Version in `user-data.pkrtpl.hcl` festpinnen:
```yaml
kernel:
  package: linux-image-6.8.0-71-generic
```

### Problem 4: SSH-Verbindung schlägt fehl

**Symptom:** Packer wartet ewig auf SSH-Verbindung oder Timeout.

**Mögliche Ursachen und Lösungen:**

1. **Falsches Passwort oder Hash:** Sicherstellen, dass `ssh_password` (Klartext) und `ssh_password_hash` (SHA-512) übereinstimmen.

2. **Netzwerk nicht erreichbar:** Die Build-IP (192.168.180.9) muss von der Management-VM erreichbar sein.

3. **Firewall blockiert:** Port 22 muss offen sein.

4. **Cloud-init nicht fertig:** Das Template wartet bereits auf `/var/lib/cloud/instance/boot-finished`.

### Problem 5: VM bleibt im GRUB hängen

**Symptom:** Nach dem Boot bleibt die VM im GRUB-Bootloader stehen.

**Ursache:** Boot-Reihenfolge oder Boot-Command falsch.

**Lösung:** Die aktuelle Konfiguration verwendet EFI-Boot mit korrektem Boot-Command:
```hcl
boot_order = "disk,cdrom"
boot_command = [
  "<wait>c<wait>",
  "linux /casper/vmlinuz autoinstall ds=nocloud",
  "<enter><wait>",
  "initrd /casper/initrd",
  "<enter><wait>",
  "boot",
  "<enter>"
]
```

---

## Architekturentscheidungen

### Warum Standard Ubuntu Server statt Minimal?

| Aspekt | Minimal | Standard (gewählt) |
|--------|---------|-------------------|
| Disk-Größe | ~1.5 GB | ~3-4 GB |
| Tools für Debugging | Müssen nachinstalliert werden | Vorhanden |
| Wartungsaufwand | Höher | Geringer |
| K8s-Troubleshooting | Erschwert | Einfacher |

**Begründung:** Die gesparten ~2 GB sind bei 384-768 GB Disk pro Node irrelevant. Für Troubleshooting sind Tools wie `curl`, `vim`, `less` essentiell.

### Warum CD-ROM statt HTTP für Cloud-Init?

Packer unterstützt zwei Methoden für Cloud-Init:
1. **HTTP-Server:** Packer startet temporären HTTP-Server
2. **CD-ROM (gewählt):** Packer erstellt ISO mit Cloud-Init-Dateien

**CD-ROM wurde gewählt weil:**
- Keine Firewall-Regeln für HTTP-Port nötig
- Zuverlässiger in isolierten Netzwerken
- Keine Abhängigkeit von der Management-VM während des Boots

---

## Troubleshooting

### Build-Log analysieren

Bei Fehlern den vollständigen Output prüfen:
```bash
packer build -var-file="credentials.auto.pkrvars.hcl" -var-file="variables.pkrvars.hcl" ubuntu-24.04.pkr.hcl 2>&1 | tee packer-build.log
```

### Temporäre VM manuell prüfen

Falls der Build abbricht, kann die temporäre VM in vCenter noch existieren:
1. In vCenter nach VMs mit Prefix `packer_` suchen
2. VM manuell löschen
3. Build erneut starten

### SSH manuell testen

Falls SSH-Probleme auftreten:
```bash
ssh admin-ubuntu@192.168.180.9
```

---

## Sicherheitshinweise

- Die Datei `credentials.auto.pkrvars.hcl` enthält sensitive Daten
- Diese Datei ist in `.gitignore` und wird NICHT committed
- Passwörter sollten in 1Password gespeichert werden
- Der SSH-Passwort-Hash sollte ebenfalls in 1Password dokumentiert werden

---

## Änderungshistorie

| Datum | Änderung |
|-------|----------|
| 05.02.2026 | Fix: `history -c` durch Dateilöschung ersetzt (Exit Code 127 behoben) |
| 04.02.2026 | Initiale Version erstellt |
