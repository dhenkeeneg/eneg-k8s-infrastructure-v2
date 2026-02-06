# SSH-Key Management - Schnellreferenz

**Ausführliche Dokumentation:** [docs/SSH-KEY-MANAGEMENT.md](../docs/SSH-KEY-MANAGEMENT.md)

## SSH-Key hinzufügen

1. Neuen Key zur Liste hinzufügen:
   ```bash
   nano inventory/dev/group_vars/secrets.yml
   ```

2. Keys auf alle Nodes verteilen:
   ```bash
   ansible-playbook -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml
   ```

## SSH-Key entfernen

1. Key aus Liste entfernen:
   ```bash
   nano inventory/dev/group_vars/secrets.yml
   ```

2. Keys auf allen Nodes aktualisieren:
   ```bash
   ansible-playbook -i inventory/dev/hosts.ini playbooks/01-setup-ssh-keys.yml
   ```

## Aktuell autorisierte Keys (Stand: 06.02.2026)

- k8s-mgmt-10 (Management-VM)
- Windows Laptop (d.henke@eneg.de)
- MacMini
- MacBook Pro

**Hinweis:** `secrets.yml` wird nicht in Git committed - Änderungen regelmäßig auf NAS sichern!
