{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    addrs = import ../../lib/lan-address.nix;
    hostname = "UCHI";
in
{
  imports = (map (name: svc.mkOne { name = name; downloadsGroup = true; } ) [ "sonarr" "radarr"]) ++ svc.mkMany [ "prowlarr" ] ++ [ ../../common/share_journald.nix ];

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      proto = "virtiofs";
      tag = "theta";
      source = "/theta/";
      mountPoint = "/theta";
    }
  ];

  services.sonarr.enable = true;
  services.radarr.enable = true;
  services.prowlarr.enable = true;
  services.prowlarr.package = bleeding.prowlarr;

  networking.hostName = hostname;
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.enableIPv6 = false;
  networking.firewall.enable = false;
  networking.nameservers = [ addrs.DARE.ip ];
  systemd.network.enable = true;
  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "${addrs.${hostname}.mac}";
    networkConfig = {
      Address = "${addrs.${hostname}.ip}/24";
      Gateway = addrs.gateway.ip;
      DNS = [ addrs.DARE.ip ];
    };
    linkConfig.RequiredForOnline = "yes";
  };
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
  ];

  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-${hostname}";
      mac = addrs.${hostname}.mac;
    }
  ];

  microvm.hypervisor = "cloud-hypervisor";
  microvm.vcpu = 2;
  microvm.mem = 2000;
  #microvm.hotplugMem = 8400;


}
