{ config, pkgs, lib, microvm, ... }:
let svc = import ../../lib/vm-service-state.nix;
in {
  imports = svc.mkMany [ "sonarr" "radarr" "prowlarr" ];

  services.sonarr.enable = true;
  services.radarr.enable = true;
  services.prowlarr.enable = true;

  networking.hostName = "UCHI";
  networking.useDHCP = true;
  networking.enableIPv6 = false;
  networking.firewall.enable = false;
  networking.useHostResolvConf = false;

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
  ];

  microvm.hypervisor = "cloud-hypervisor";
  microvm.vcpu = 2;
  microvm.mem = 2000;
  #microvm.hotplugMem = 8400;

  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-UCHI";
      mac = "02:00:00:00:00:01";
    }
  ];

}
