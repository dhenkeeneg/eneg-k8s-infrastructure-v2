# Role: rolling_os_update

Rolling OS-Update für K3s HA-Cluster mit allen Safeguards.

## Aufruf

Diese Role wird **nicht direkt** als `roles: - rolling_os_update` aufgerufen,
sondern über das Multi-Play-Playbook `playbooks/08-rolling-os-update.yml`,
das die Task-Files in der richtigen Reihenfolge importiert.

```bash
# DEV
ansible-playbook -i inventory/dev/hosts.ini playbooks/08-rolling-os-update.yml \
  -e target_env=dev

# Nur Pre-Checks (Trockenlauf)
ansible-playbook -i inventory/dev/hosts.ini playbooks/08-rolling-os-update.yml \
  -e target_env=dev --tags pre-checks
```

## Variablen (defaults/main.yml)

| Variable | Default | Zweck |
|---|---|---|
| `target_env` | — (Pflicht) | dev / test / prod |
| `kubectl_context` | `k8s-{{ target_env }}` | abgeleitet |
| `cooldown_seconds` | `60` | Pause zwischen Nodes |
| `drain_timeout_seconds` | `600` | kubectl drain Timeout |
| `reboot_timeout_seconds` | `600` | Ansible reboot Timeout |
| `apt_hold_packages` | `[k3s, k3s-selinux]` | per apt-mark hold geschützt |
| `enable_vsphere_snapshot` | `true` | govc Snapshot vor Update |
| `snapshot_delete_on_success` | `true` | Snapshot bei Erfolg löschen |
| `force_reboot_on_changes` | `true` | „Immer"-Reboot-Strategie |
| `argocd_namespace` | `argocd` | für Sync-Check |

## Pflicht-Voraussetzungen auf dem Ansible Controller (k8s-mgmt-10)

- `kubectl` mit Contexts `k8s-dev`, `k8s-test`, `k8s-prod`
- `kubectl-cnpg` Plugin (mind. v1.28.x)
- `govc` mit gültigen vCenter-Credentials in `ansible/secrets/govc-credentials.yaml` (SOPS-verschlüsselt)
- `community.sops` Ansible Collection
- SSH-Zugriff zu allen Nodes als `admin-ubuntu` mit sudo

## Task-Files (Reihenfolge)

| # | Datei | Wo läuft's? |
|---|---|---|
| 1 | `pre_checks.yml` | localhost (run_once) |
| 2 | `snapshot_create.yml` | localhost (delegate_to, per Node) |
| 3 | `cnpg_failover.yml` | localhost (delegate_to, per Node) |
| 4 | `drain.yml` | localhost (delegate_to, per Node) |
| 5 | `apt_update.yml` | **Node** (become: true) |
| 6 | `reboot_if_changed.yml` | **Node** (become: true) |
| 7 | `uncordon_verify.yml` | localhost (delegate_to, per Node) |
| 8 | `snapshot_delete.yml` | localhost (delegate_to, per Node) |
| 9 | `post_checks.yml` | localhost (run_once) |

## Reboot-Logik

Reboot wird ausgelöst wenn:
- `force_reboot_on_changes=true` UND `apt_upgrade.changed=true` (ein oder mehrere Pakete installiert), **ODER**
- `/var/run/reboot-required` existiert auf der Node (Kernel-/glibc-Update markiert)

## Failure-Verhalten

Fehlerschlag in einer Phase **stoppt** den weiteren Lauf für **alle** Nodes
(Ansible Standard `any_errors_fatal: true` im Playbook gesetzt).
Snapshots der bereits erfolgreichen Nodes werden gelöscht (oder behalten je
nach `snapshot_delete_on_success`); der Snapshot der fehlerhaften Node bleibt
erhalten zur manuellen Wiederherstellung.

## Manuelles Rollback (falls nötig)

```bash
# Snapshot-Liste einer VM
govc snapshot.tree -vm k8s-dev-21

# Auf Snapshot zurueckrollen (VM muss aus sein)
govc vm.power -off k8s-dev-21
govc snapshot.revert -vm k8s-dev-21 <snapshot-name>
govc vm.power -on k8s-dev-21

# Snapshot loeschen wenn nicht mehr noetig
govc snapshot.remove -vm k8s-dev-21 <snapshot-name>
```
