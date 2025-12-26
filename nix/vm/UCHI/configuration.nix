{ config, pkgs, lib, ... }:

{
  networking.hostName = "UCHI";
  networking.useDHCP = true;
  networking.enableIPv6 = false;
  networking.firewall.enable = false;

  # In MicroVMs this is often disabled; keep as you had it.
  networking.useHostResolvConf = false;

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
  ];

  services.jellyfin.enable = true;
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vcpu = 8;
  microvm.mem = 8000;
  #microvm.hotplugMem = 8400;

  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-UCHI";
      mac = "02:00:00:00:00:01";
    }
  ];

}
