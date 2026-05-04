# Ansible Secrets

Dieses Verzeichnis enthält SOPS-verschlüsselte Credentials für Ansible-Playbooks.

## Convention

- `*.example.yaml` → Klartext-Templates mit Platzhaltern (committed)
- `*.yaml` (real) → SOPS-verschlüsselt (committed im verschlüsselten Zustand)
- Greift `.sops.yaml` Regel 3: `(terraform|ansible)/.*credentials.*\.yaml$`

## Workflow

Auf **k8s-mgmt-10**:

    cd ~/git/eneg-k8s-infrastructure-v2/ansible/secrets
    cp govc-credentials.example.yaml govc-credentials.yaml
    vim govc-credentials.yaml           # Werte eintragen
    sops -e -i govc-credentials.yaml    # in-place verschluesseln
    head govc-credentials.yaml          # MUSS sops:-Block zeigen
    git add govc-credentials.yaml
    git commit -m "feat(ansible): govc credentials hinzugefuegt"
    git push

## Decrypt-Test

    sops -d ansible/secrets/govc-credentials.yaml

## Sicherheitshinweis

**Niemals** eine `*.yaml`-Datei mit echten Werten **unverschlüsselt** committen.
Der Verify-Schritt (`head` muss `sops:`-Block zeigen) ist Pflicht.

## Aktuelle Files

| Datei | Zweck |
|---|---|
| `govc-credentials.yaml` | vSphere/govc API für VM-Snapshots in Playbooks |
