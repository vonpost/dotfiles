{ config, lib, pkgs, ... }:

let
  addrs = import ../../lib/lan-address.nix;

  lanPrefix = 24;
  lanSubnet = "192.168.1.0/24";

  # WireGuard client subnet (adjust to your real one)
  wgSubnet = "10.10.0.0/24";

  # Build {"mother.lan."="192.168.1.11"; ...} from addrs (excluding gateway)
  hosts =
    lib.mapAttrs'
      (name: value: { name = "${name}.lan."; value = value.ip; })
      (lib.removeAttrs addrs [ "gateway" ]);
  hostname = "DARE";
in
{
  networking.hostName = hostname;
  networking.enableIPv6 = false;
  networking.useDHCP = false;
  # --- networkd static IP ---
  networking.useNetworkd = true;
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
];
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.extraConfig = ''
    AllowAgentForwarding yes
  '';


  systemd.network.enable = true;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = addrs.${hostname}.mac;
    networkConfig = {
      Address = "${addrs.${hostname}.ip}/${toString lanPrefix}";
      Gateway = addrs.gateway.ip;

      # Upstream DNS for the VM itself (nix, ntp, etc.)
      DNS = [ addrs.gateway.ip ];
    };
    linkConfig.RequiredForOnline = "yes";
  };

  microvm.shares = [
    {
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
    }
  ];

  services.timesyncd.enable = true;

  # --- Unbound DNS ---
  services.unbound = {
    enable = true;

    settings.server = {
      interface = [ addrs.${hostname}.ip "127.0.0.1" ];

      access-control = [
        "${lanSubnet} allow"
        "${wgSubnet} allow"
        "127.0.0.0/8 allow"
      ];

      local-zone = [ ''"lan." static'' ];
      local-data = lib.mapAttrsToList (n: ip: ''"${n} IN A ${ip}"'') hosts;

      hide-identity = "yes";
      hide-version = "yes";
      qname-minimisation = "yes";
      prefetch = "yes";
      cache-min-ttl = 60;
      cache-max-ttl = 86400;
    };

    settings.forward-zone = [{
      name = ".";
      forward-addr = [ addrs.gateway.ip ];
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
      id = "vm-${hostname}";
      mac = addrs.${hostname}.mac;
    }
  ];
}
