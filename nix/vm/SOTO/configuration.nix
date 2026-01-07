{ config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    addrs = import ../../lib/lan-address.nix;
    hostname = "SOTO";
in {
  imports = [ (svc.mkOne { name = "jellyfin"; persistCache = true; })
              (svc.mkOne  { name = "jellyseerr"; })
              ../../common/nginx.nix
              ../../common/myaddr.nix
            ];

  services.jellyseerr.enable = true;
  services.jellyfin =  {
    enable = true;
    package = bleeding.jellyfin;
  };

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

  microvm.hypervisor = "cloud-hypervisor";
  microvm.vcpu = 8;
  microvm.mem = 8000;
  #microvm.hotplugMem = 8400;

  networking.hostName = hostname;
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.enableIPv6 = false;
  networking.nameservers = [ addrs.DARE.ip ];

  networking.firewall.enable = false;
  systemd.network.enable = true;
  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "${addrs.${hostname}.mac}";
    networkConfig = {
      Address = "${addrs."${hostname}".ip}/24";
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

}
