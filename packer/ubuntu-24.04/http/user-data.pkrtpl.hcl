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

  # Kernel: Spezifische Version von der ISO verwenden
  kernel:
    package: linux-image-6.8.0-71-generic
  
  # Pakete installieren (für VMware Guest Customization)
  packages:
    - open-vm-tools
    - util-linux
    - perl
  
  # Späte Befehle
  late-commands:
    - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
    - echo '${ssh_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${ssh_username}
    - chmod 0440 /target/etc/sudoers.d/${ssh_username}
