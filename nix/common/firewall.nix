{ config, lib, pkgs, ... }:

let

  addrs = (import ../lib/lan-address.nix);
  wanMac = addrs.${config.networking.hostName}.mac;
  lanMac = "02:00:00:00:20:02";

  vlans = {
    mgmt = { id = 10; gw = "10.10.10.1"; prefix = 24; ifname = "lan.10"; };
    srv  = { id = 20; gw = "10.10.20.1"; prefix = 24; ifname = "lan.20"; };
    dmz  = { id = 30; gw = "10.10.30.1"; prefix = 24; ifname = "lan.30"; };
  };
in
{
  services.udev.extraRules = ''
    SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="${wanMac}", NAME="wan"
    SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="${lanMac}", NAME="lan"
  '';

  # LAN trunk, no IP; attach VLANs
  systemd.network.networks."20-lan-trunk" = {
    matchConfig.MACAddress = lanMac;
    networkConfig = {
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
      VLAN = [ vlans.mgmt.ifname vlans.srv.ifname vlans.dmz.ifname ];
    };
  };

  # VLAN devices
  systemd.network.netdevs = {
    "10-vlan10" = { netdevConfig = { Name = vlans.mgmt.ifname; Kind = "vlan"; }; vlanConfig.Id = vlans.mgmt.id; };
    "11-vlan20" = { netdevConfig = { Name = vlans.srv.ifname;  Kind = "vlan"; }; vlanConfig.Id = vlans.srv.id;  };
    "12-vlan30" = { netdevConfig = { Name = vlans.dmz.ifname;  Kind = "vlan"; }; vlanConfig.Id = vlans.dmz.id;  };
  };

  # Static gateway IPs on VLANs
  systemd.network.networks."30-vlan10" = {
    matchConfig.Name = vlans.mgmt.ifname;
    address = [ "${vlans.mgmt.gw}/${toString vlans.mgmt.prefix}" ];
  };
  systemd.network.networks."31-vlan20" = {
    matchConfig.Name = vlans.srv.ifname;
    address = [ "${vlans.srv.gw}/${toString vlans.srv.prefix}" ];
  };
  systemd.network.networks."32-vlan30" = {
    matchConfig.Name = vlans.dmz.ifname;
    address = [ "${vlans.dmz.gw}/${toString vlans.dmz.prefix}" ];
  };

  # Enable forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
  };

  microvm.interfaces = [
    { type = "tap"; id = "lan0"; mac = lanMac; bridge = "br-lan"; }
    ];

  networking.nftables.enable = true;

  networking.nftables.ruleset = ''
    table inet filter {
      chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept

        # Optional diagnostics
        ip protocol icmp accept

        # Allow SSH to firewall only from mgmt VLAN
        iifname "${vlans.mgmt.ifname}" tcp dport 22 accept
        # Remove this when happy
        iifname "wan" tcp dport 22 accept

        # WireGuard handshake allowed on WAN
        iif "wan" udp dport 51820 accept
      }

      chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept

        # Allow VLANs -> WAN
        iifname { "${vlans.mgmt.ifname}", "${vlans.srv.ifname}", "${vlans.dmz.ifname}" } oif "wan" accept

        # Allow WireGuard -> all VLANs (management access to any port/UI)
        iifname "wg0" oifname { "${vlans.mgmt.ifname}", "${vlans.srv.ifname}", "${vlans.dmz.ifname}" } accept

        # Default: deny inter-VLAN until explicitly opened
      }
    }

    table ip nat {
      chain postrouting {
        type nat hook postrouting priority 100;
        oif "wan" masquerade
      }
    }
  '';

}
