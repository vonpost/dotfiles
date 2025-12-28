{ config, lib, pkgs, ... }:

let
  addrs = import ../../lib/lan-addresses.nix;

  lanIf = "eth0";          # adjust if needed
  lanPrefix = 24;
  lanSubnet = "192.168.1.0/24";

  # WireGuard client subnet (adjust to your real one)
  wgSubnet = "10.10.0.0/24";

  # Build {"mother.lan."="192.168.1.11"; ...} from addrs (excluding gateway)
  hosts =
    lib.mapAttrs'
      (name: ip: { name = "${name}.lan."; value = ip; })
      (lib.removeAttrs addrs [ "gateway" ]);
in
{
  networking.hostName = "DARE";
  networking.enableIPv6 = false;

  # --- networkd static IP ---
  networking.useNetworkd = true;
  systemd.network.enable = true;

  systemd.network.networks."10-lan" = {
    matchConfig.Name = lanIf;
    networkConfig = {
      Address = "${addrs.dns}/${toString lanPrefix}";
      Gateway = addrs.gateway;

      # Upstream DNS for the VM itself (nix, ntp, etc.)
      DNS = [ addrs.gateway ];
    };
    linkConfig.RequiredForOnline = "yes";
  };

  services.timesyncd.enable = true;

  # --- Unbound DNS ---
  services.unbound = {
    enable = true;

    settings.server = {
      interface = [ addrs.dns "127.0.0.1" ];

      access-control = [
        "${lanSubnet} allow"
        "${wgSubnet} allow"
        "127.0.0.0/8 allow"
      ];

      local-zone = [ "lan. static" ];
      local-data = lib.mapAttrsToList (n: ip: "${n} IN A ${ip}") hosts;

      hide-identity = "yes";
      hide-version = "yes";
      qname-minimisation = "yes";
      prefetch = "yes";
      cache-min-ttl = 60;
      cache-max-ttl = 86400;
    };

    settings.forward-zone = [{
      name = ".";
      forward-addr = [ addrs.gateway ];
    }];
  };

  # --- Firewall ---
  networking.firewall.enable = true;
  networking.firewall.allowedUDPPorts = [ 53 22 ];
  networking.firewall.allowedTCPPorts = [ 53 22 ];

  environment.systemPackages = with pkgs; [ dig ];

  # --- MicroVM device ---
  microvm.hypervisor = "cloud-hypervisor";
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-DARE";
      mac = "02:00:00:00:00:53";
    }
  ];
}
