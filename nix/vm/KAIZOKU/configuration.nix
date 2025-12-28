{ config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
in {
  imports = svc.mkMany [ "qbittorrent" "sabnzbd" ];
  nixpkgs.config.allowUnfree = true;
  services.sabnzbd.enable = true;
  services.qbittorrent.enable = true;

  networking.hostName = "KAIZOKU";
  networking.useDHCP = true;
  networking.enableIPv6 = false;
  networking.firewall.enable = false;
  networking.useHostResolvConf = false;
  networking.nameservers = [
    "192.168.1.53"
  ];
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
  ];

  microvm.hypervisor = "cloud-hypervisor";
  microvm.vcpu = 2;
  microvm.mem = 1000;
  #microvm.hotplugMem = 8400;

  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-KAIZOKU";
      mac = "02:00:00:00:00:03";
    }
  ];

}
