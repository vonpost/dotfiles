{ lib, config, pkgs, ... }:

let
  addr = import ../lib/lan-address.nix;
  wanMac  = addr.${config.networking.hostName}.mac;
  mgmtMac = "02:00:00:01:00:10";
  srvMac  = "02:00:00:01:00:20";
  dmzMac  = "02:00:00:01:00:30";

  # Subnets (edit if you want different addressing)
  mgmtGw = "10.10.10.1";
  srvGw  = "10.10.20.1";
  dmzGw  = "10.10.30.1";
in
{
  systemd.network.enable = true;

  systemd.network.links."20-custom-name" = {
    matchConfig.PermanentMACAddress = wanMac; # Replace with your MAC
    linkConfig.Name = "wan"; # Desired new name
  };

  systemd.network.links."21-custom-name" = {
    matchConfig.PermanentMACAddress = mgmtMac; # Replace with your MAC
    linkConfig.Name = "mgmt"; # Desired new name
  };

  systemd.network.links."22-custom-name" = {
    matchConfig.PermanentMACAddress = srvMac; # Replace with your MAC
    linkConfig.Name = "srv"; # Desired new name
  };

  systemd.network.links."23-custom-name" = {
    matchConfig.PermanentMACAddress = dmzMac; # Replace with your MAC
    linkConfig.Name = "dmz"; # Desired new name
  };

  # LAN interfaces: static gateways
  systemd.network.networks."20-mgmt" = {
    matchConfig.MACAddress = mgmtMac;
    address = [ "${mgmtGw}/24" ];
    networkConfig = { IPv6AcceptRA = false; };
  };

  systemd.network.networks."21-srv" = {
    matchConfig.MACAddress = srvMac;
    address = [ "${srvGw}/24" ];
    networkConfig = { IPv6AcceptRA = false; };
  };

  systemd.network.networks."22-dmz" = {
    matchConfig.MACAddress = dmzMac;
    address = [ "${dmzGw}/24" ];
    networkConfig = { IPv6AcceptRA = false; };
  };

  # Forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
  };

  networking.nftables.enable = true;
  networking.nftables.ruleset = ''
    table inet filter {
      chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept

        # Optional diagnostics
        ip protocol icmp accept

        # Allow SSH to firewall only from mgmt LAN
        iifname "mgmt" tcp dport 22 accept

        # Temporary until done configuring. Note, this is still behind double NAT so not really exposed to the internet yet.
        iifname "wan" tcp dport 22 accept

        # If WireGuard enabled, allow handshake from WAN
        # iifname "wan" udp dport 51820 accept
      }

      chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept

        # Allow LANs out to WAN
        iifname { "mgmt", "srv", "dmz" } oifname "wan" accept

        # Inter-LAN default deny (add specific rules as needed)
        # Example allow mgmt -> srv (ssh + https):
        # iifname "mgmt" oifname "srv" tcp dport { 22, 443 } accept

        # WireGuard -> all LANs (if WireGuard enabled)
        # iifname "wg0" oifname { "mgmt", "srv", "dmz" } accept
      }
    }

    table ip nat {
      chain postrouting {
        type nat hook postrouting priority 100;
        oifname "wan" masquerade
      }
    }
  '';
}
