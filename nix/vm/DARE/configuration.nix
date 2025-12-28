{ config, lib, pkgs, ... }:

let
  addrs = import ../../lib/lan-address.nix;

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
  networking.useDHCP = false;
  # --- networkd static IP ---
  networking.useNetworkd = true;
  services.openssh.enable = true;
  users.users.root.openssh.authorizedkeys.keys = [
    "ssh-ed25519 aaaac3nzac1lzdi1nte5aaaaidg2yxfywcwwrss0tece+6wplgzerqabvdyky4hvsev+ ed25519-key-20221208"
    "ssh-ed25519 aaaac3nzac1lzdi1nte5aaaainabarhka8npou1vmjpcridaaidvqn7e1d+a+lxp7hmg daniel.j.collin@gmail.com"
  ];


  systemd.network.enable = true;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "02:00:00:00:00:53";
    networkConfig = {
      Address = "${addrs.DARE}/${toString lanPrefix}";
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
      interface = [ addrs.DARE "127.0.0.1" ];

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
  networking.firewall.enable = false;
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
