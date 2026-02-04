#cloud-config
autoinstall:
  version: 1
  locale: de_DE.UTF-8
  keyboard:
    layout: de
    variant: nodeadkeys
  
  # Netzwerk: Statische IP für Template-Build
  network:
    network:
      version: 2
      ethernets:
        ens192:
          dhcp4: false
          addresses:
            - ${build_ip}/24
          routes:
            - to: default
              via: ${gateway}
          nameservers:
            addresses:
              - 192.168.161.101
              - 192.168.161.102
              - 192.168.161.103
  
  # Storage: Gesamte Disk verwenden mit LVM
  storage:
    layout:
      name: lvm
      sizing-policy: all
  
  # Benutzer
  identity:
    hostname: ubuntu-template
    username: ${ssh_username}
    password: "${ssh_password}"
  
  # SSH Server aktivieren
  ssh:
    install-server: true
    allow-pw: true
  
  # Pakete
  packages:
    - openssh-server
    - open-vm-tools
    - cloud-init
    - curl
    - wget
    - vim
    - htop
    - net-tools
    - ca-certificates
    - gnupg
    - lsb-release
  
  # Updates
  updates: security
  
  # Späte Befehle
  late-commands:
    # SSH Passwort-Login temporär erlauben (für Packer)
    - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
    # sudo ohne Passwort für admin-ubuntu
    - echo '${ssh_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${ssh_username}
    - chmod 0440 /target/etc/sudoers.d/${ssh_username}
