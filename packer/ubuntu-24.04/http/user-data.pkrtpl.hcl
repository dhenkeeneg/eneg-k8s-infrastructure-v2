#cloud-config
autoinstall:
  version: 1
  locale: de_DE.UTF-8
  keyboard:
    layout: de
    variant: nodeadkeys
  
  # Netzwerk: Statische IP für Template-Build - mit Google DNS
  network:
    version: 2
    ethernets:
      id0:
        match:
          driver: vmxnet3
        addresses:
          - ${build_ip}/24
        routes:
          - to: default
            via: ${gateway}
        nameservers:
          addresses:
            - 8.8.8.8
            - 8.8.4.4
  
  # Storage: Gesamte Disk verwenden mit LVM
  storage:
    layout:
      name: lvm
      sizing-policy: all
  
  # Benutzer
  identity:
    hostname: ubuntu-template
    username: ${ssh_username}
    password: "${ssh_password_hash}"
  
  # SSH Server aktivieren
  ssh:
    install-server: true
    allow-pw: true

  # Kernel: Standard GA Kernel (kein Version-Pinning)
  kernel:
    package: linux-image-generic

  # Pakete installieren (für VMware Guest Customization + Disk-Erweiterung)
  packages:
    - open-vm-tools
    - util-linux-extra
    - perl
    - cloud-guest-utils
    - cloud-initramfs-growroot
  
  # Cloud-init: Automatische Disk-Erweiterung beim ersten Boot nach Clone
  # Wenn vSphere die Disk vergrößert (z.B. 50GB Template -> 384GB VM),
  # erweitert cloud-init beim ersten Boot automatisch Partition + LVM + Filesystem
  user-data:
    growpart:
      mode: auto
      devices: ['/']
      ignore_growroot_disabled: false
    resize_rootfs: true

  # Späte Befehle
  late-commands:
    - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
    - echo '${ssh_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${ssh_username}
    - chmod 0440 /target/etc/sudoers.d/${ssh_username}
    # SSH-Host-Keys beim ersten Boot generieren (systemd service)
    - |
      cat > /target/etc/systemd/system/regenerate-ssh-host-keys.service << 'SVCEOF'
      [Unit]
      Description=Regenerate SSH Host Keys
      Before=ssh.service
      ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/ssh-keygen -A
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
      SVCEOF
    - curtin in-target -- systemctl enable regenerate-ssh-host-keys.service
