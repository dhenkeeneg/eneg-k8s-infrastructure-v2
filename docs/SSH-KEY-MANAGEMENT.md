# SSH-Key Management für K8s Cluster

## Übersicht

Die SSH-Keys für den Cluster-Zugriff werden über Ansible zentral verwaltet. Alle autorisierten Public Keys werden in der Datei `ansible/inventory/dev/group_vars/secrets.yml` gespeichert.

## Aktuell autorisierte Arbeitsstationen

Stand: 06.02.2026

| Workstation | User | Fingerprint (letzte 8 Zeichen) |
|-------------|------|--------------------------------|
| k8s-mgmt-10 (Management-VM) | k8s-mgmt-10@eneg.de | IScDQj |
| Windows Laptop | d.henke@eneg.de | uEYjh |
| MacMini | danielhenke@Mac.localdomain | hgSi |
| MacBook Pro | danielhenke@MacBook-Pro-von-Daniel.local | M4LZ |

## SSH-Key hinzufügen (neue Person / neuer Rechner)

### Schritt 1: SSH-Key auf dem neuen Rechner generieren

```bash
# Ed25519 Key generieren (empfohlen)
ssh-keygen -t ed25519 -C "benutzer@rechner"

# Key anzeigen
cat ~/.ssh/id_ed25519.pub
```

### Schritt 2: Public Key zur secrets.yml hinzufügen

```bash
# Auf einer der autorisierten Workstations (z.B. Management-VM)
cd ~/git/eneg-k8s-infrastructure-v2/ansible/inventory/dev/group_vars
nano secrets.yml
```

Fügen Sie den neuen Public Key zur Liste hinzu:

```yaml
ssh_public_keys:
  # Bestehende Keys...
  
  # Neuer Rechner
  - "ssh-ed25519 AAAA...xyz neuer-benutzer@neuer-rechner"
```

### Schritt 3: Keys auf alle Cluster-Nodes verteilen

```bash
cd ~/git/eneg-k8s-infrastructure-v2/ansible

# Keys aktualisieren (ohne --ask-pass, da bereits SSH-Keys vorhanden)
ansible-playbook -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml
```

### Schritt 4: Zugriff testen

```bash
# Vom neuen Rechner aus
ssh k8sadmin@192.168.180.21
```

## SSH-Key entfernen (Rechner außer Betrieb / Person verlässt Organisation)

### Schritt 1: Public Key aus secrets.yml entfernen

```bash
# Auf einer der autorisierten Workstations
cd ~/git/eneg-k8s-infrastructure-v2/ansible/inventory/dev/group_vars
nano secrets.yml
```

Entfernen Sie die entsprechende Zeile aus der `ssh_public_keys` Liste.

### Schritt 2: Keys auf allen Nodes aktualisieren

```bash
cd ~/git/eneg-k8s-infrastructure-v2/ansible

# authorized_keys neu erstellen (ohne den entfernten Key)
ansible-playbook -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml
```

Das Playbook überschreibt die `authorized_keys` Datei komplett, daher wird der entfernte Key automatisch gelöscht.

### Schritt 3: Zugriff verifizieren

```bash
# Vom entfernten Rechner sollte der Zugriff jetzt fehlschlagen
ssh k8sadmin@192.168.180.21
# Permission denied (publickey)
```

## Notfall: Aussperrung

Falls Sie sich ausgesperrt haben (z.B. secrets.yml falsch bearbeitet):

### Option 1: Über vCenter Console

1. In vCenter zur VM navigieren
2. "Console öffnen"
3. Mit k8sadmin-Passwort einloggen
4. Manuell korrigieren:

```bash
# Keys manuell prüfen
cat ~/.ssh/authorized_keys

# Falls nötig: Backup wiederherstellen
sudo cp ~/.ssh/authorized_keys.backup ~/.ssh/authorized_keys
```

### Option 2: Über andere autorisierte Workstation

Wenn noch eine andere Workstation Zugriff hat:

```bash
# Von der funktionierenden Workstation
ssh k8sadmin@192.168.180.21

# secrets.yml korrigieren und Playbook neu ausführen
```

## Best Practices

### Sicherheit

- **Niemals Private Keys teilen** - Jede Person generiert eigene Keys
- **Ed25519 bevorzugen** - Sicherer und kleiner als RSA
- **Key-Rotation** - Alle 1-2 Jahre Keys erneuern
- **Kommentare nutzen** - Immer aussagekräftige Kommentare (user@hostname)

### Dokumentation

- **Änderungen tracken** - Git-Commits für secrets.yml Änderungen
  ```bash
  git log ansible/inventory/dev/group_vars/secrets.yml
  ```
- **Tabelle aktualisieren** - Diese README bei Key-Änderungen aktualisieren

### Backup

Die `secrets.yml` wird **nicht** in Git committed (siehe `.gitignore`), daher:

```bash
# Regelmäßiges Backup auf NAS
scp ~/git/eneg-k8s-infrastructure-v2/ansible/inventory/dev/group_vars/secrets.yml \
    nasadmin@192.168.161.61:~/Backup-K8s-Secrets/secrets-dev-$(date +%Y%m%d).yml

# Oder in verschlüsselter Form in Git speichern (mit SOPS - siehe unten)
```

## Erweiterte Verwaltung mit SOPS (Optional, für später)

Für besseres Secret-Management kann später SOPS verwendet werden:

```bash
# secrets.yml verschlüsseln
sops -e secrets.yml > secrets.enc.yml

# In Git committen (verschlüsselt)
git add secrets.enc.yml
git commit -m "Update SSH keys (encrypted)"

# Auf anderem Rechner entschlüsseln
sops -d secrets.enc.yml > secrets.yml
```

## Troubleshooting

### "Permission denied (publickey)"

**Ursachen:**
- Public Key nicht in secrets.yml
- Playbook wurde nicht ausgeführt
- Falscher Private Key verwendet

**Lösung:**
```bash
# Verbindung debuggen
ssh -v k8sadmin@192.168.180.21

# Key-Angebot anzeigen
ssh-add -l

# Spezifischen Key verwenden
ssh -i ~/.ssh/id_ed25519 k8sadmin@192.168.180.21
```

### "Host key verification failed"

**Ursache:** Host-Key hat sich geändert (z.B. VM neu erstellt)

**Lösung:**
```bash
# Host-Key aus known_hosts entfernen
ssh-keygen -R 192.168.180.21

# Neu verbinden
ssh k8sadmin@192.168.180.21
```

### Keys werden nicht verteilt

**Prüfen:**
```bash
# Ansible-Verbindung testen
ansible all -i inventory/dev/hosts.ini -m ping

# secrets.yml Syntax prüfen
ansible-playbook --syntax-check -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml

# Detaillierte Ausgabe
ansible-playbook -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml -vvv
```

## Ansible Playbook Details

Das Playbook `01-setup-ssh-keys.yml` führt folgende Aktionen aus:

1. **Verzeichnis erstellen**: `~/.ssh` mit korrekten Berechtigungen (700)
2. **authorized_keys schreiben**: Alle Keys aus `secrets.yml` eintragen
3. **Berechtigungen setzen**: authorized_keys auf 600
4. **Root-Login deaktivieren**: `PermitRootLogin no` in sshd_config
5. **Passwort-Auth deaktivieren**: `PasswordAuthentication no` in sshd_config
6. **SSH neu starten**: Damit Änderungen aktiv werden

**Wichtig:** Das Playbook überschreibt `authorized_keys` komplett - manuelle Änderungen gehen verloren!

## Umgebungen

Aktuell verwalten wir Keys für:
- **DEV**: `ansible/inventory/dev/group_vars/secrets.yml`

Später kommen hinzu:
- **TEST**: `ansible/inventory/test/group_vars/secrets.yml`
- **PROD**: `ansible/inventory/prod/group_vars/secrets.yml`

**Best Practice:** In PROD sollten nur absolut notwendige Keys vorhanden sein!
