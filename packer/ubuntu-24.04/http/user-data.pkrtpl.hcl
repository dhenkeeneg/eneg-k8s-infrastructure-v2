#cloud-config
autoinstall:
  version: 1
  locale: de_DE.UTF-8
  keyboard:
    layout: de
    variant: nodeadkeys
  
  # Netzwerk: Statische IP für Template-Build
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
  
  # Späte Befehle
  late-commands:
    - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
    - echo '${ssh_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${ssh_username}
    - chmod 0440 /target/etc/sudoers.d/${ssh_username}
