{ self, config, lib, pkgs, ... }:

let
  addrs = import ../../lib/lan-address.nix;

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
  imports = [
    (import ../../common/vm-common.nix {
      hostname = hostname;
      nameserverHost = null;
      dnsHost = "gateway";
    })
  ];

  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.extraConfig = ''
    AllowAgentForwarding yes
  '';

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
      forward-addr = [ "9.9.9.9" "1.1.1.1" ];
    }];
  };

  # --- Firewall ---
  networking.firewall.allowedUDPPorts = [ 53 22 ];
  networking.firewall.allowedTCPPorts = [ 53 22 ];

  environment.systemPackages = with pkgs; [ dig ];
}
