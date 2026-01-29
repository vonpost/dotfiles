{ lib, ... }:

let rec
  topology = {
    domain = "lan";
    gatewayVM = "MAMORU"; # The VM acting as the router/firewall
    dnsVM = "DARE";

    firewallRules = {
      dns = { port = 53; proto = "udp"; allowFrom = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" "MAMORU" ]; };
      http = { port = 80; proto = "tcp"; allowFrom = [ "external" ];  };
      https = { port = 80; proto = "tcp"; allowFrom = [ "external" ]; };
      ssh = { port = 22; proto = "tcp"; allowFrom = [ "MAMORU" ]; };
      wireguard = { port = 51820; proto = "udp"; allowFrom = [ "MAMORU"]; };
    };
    with topology.firewallRules;
    vms = {
      MAMORU = {
        id = 10;
        assignedVlans = [ "mgmt" "srv" "dmz" ]; # WAN is handled manually
        provides = [ ssh wireguard ];
      };
      KAIZOKU = {
        id = 15;
        assignedVlans = [ "srv" ]; # WAN is handled manually
        provides = [ ssh ];
      };

      UCHI = {
        id = 20;
        assignedVlans = [ "srv" ];
        provides = [ ssh ];
      };
      DARE = {
        id = 53;
        assignedVlans = [ "srv" ];
        provides = [ dns ssh ];
      };
      SOTO = {
        id = 25;
        assignedVlans = [ "dmz" ];
        provides = [ http https ssh ];
      };
      OKAMI = {
        id = 30;
        assignedVlans = [ "dmz" ];
        provides = [ ssh ];
      };
    };
  };

  wanMac = "02:10:00:00:00";
  wanBridge = "br0";
  vlans = {
    mgmt = { id = 10; };
    srv  = { id = 20; };
    dmz  = { id = 30; };
  };

  getSubnet = vlan: "10.10.${vlans.${vlan}.id}"
  getIp = name: vlan: "${getSubnet vlan}.${toString topology.vms.${name}.id}";
  getMac = vm: vlan: "02:00:00:00:${toString vlans.${vlan}.id}:${toString topology.vms.${name}.id}";
  getGateway = vlan: "${getSubnet vlan}.${toString vms.${topology.gatewayVM}.id}";
  getDns = getIp dnsVM "srv";
in {
    # HOST CONFIG: Bridges and Taps
    mkHostNetwork = {
      systemd.network = {
        netdevs = builtins.listToAttrs (map vlan: {
          name = "40-br-vlan-${vlan}"
          netdevConfig = {
            Name = "br-vlan-${vlan}";
            Kind = "bridge";
          };
        } builtins.attrNames vlans);
          networks = {
            # Bridges online without carrier
              {
                name = "50-br-vlan"
                matchConfig.Name = "br-vlan-*";
                networkConfig.ConfigureWithoutCarrier = true;
                linkConfig.RequiredForOnline = "no";
              }
          } // (builtins.listToAttrs (map vlan:
            # Attach taps to bridge
            {
              name = "50-tap-${vlan}";
              matchConfig.Name = "tap-${vlan}-*";
              linkConfig.RequiredForOnline = "no";
              networkConfig = {
                Bridge = "br-${vlan}";
                ConfigureWithoutCarrier = true;
              };
            } (builtins.attrNames vlans)));
      };
    };

    # GUEST CONFIG: For microvms
    mkGuest = name: let
      vm = topology.vms.${name};
    in
      {
        microvm.interfaces = map (vlan:
          {
            type = "tap";
            id = "tap-${vlan}-${name}";
            mac = getMac name vlan;
          }
        ) vm.assignedVlans;

        systemd.network = {
          enable = true;
          networks = builtins.listToAttrs (map vlan:
          {
            name="20-${vlan}";
            matchConfig.MACAddress = getMac name vlan;
            networkConfig = {
              Address = "${getIp name vlan}/24";
              Gateway = lib.mkIf (name != topology.gatewayVM) getGateway vlan;
              DNS = getDns;
            };
          } vm.assignedVlans);

          # Rename to map to the VLAN names.
          links = builtins.listToAttrs (map vlan:
          {
                matchConfig.PermanentMACAddress = getMac name vlan;
                linkConfig.Name = vlan; # Desired new name
          } vm.assignedVlans);
        };

        # Rest of the networking config
        boot.kernelParams = [ "ipv6.disable=1" ];
        systemd.network.enable = true;
        networking = {
          useDHCP = false;
          useNetworkd = true;
          enableIPv6 = false;
          # Not sure if this is needed as well since we did set dns for the systemd definition.. nameservers = [ (getIp dnsVM "srv") ];
          firewall = {
            enable = true;
            allowedTCPPorts = map (p: p.port) (filter (p: p.proto = "tcp") vm.provides);
            allowedUDPPorts = map (p: p.port) (filter (p: p.proto = "udp") vm.provides);
          };
        };
      };

    # GATEWAY CONFIG: Firewall & NAT (Assumes WAN is wan)
    mkGateway = {
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv4.conf.all.rp_filter" = 1;
        "net.ipv4.conf.default.rp_filter" = 1;
      };

    systemd.network.networks."10-wan" = {
      matchConfig.MACAddress = wanMac;
      networkConfig = {
        DHCP="ipv4";
      };
      dhcpV4Config = {
        UseDNS = true;
        UseRoutes = true;
        UseGateway = true;
      }
      linkConfig.RequiredForOnline = "yes";
    };

    microvm.interfaces = [
      {
        type = "tap";
        id = "tap-wan";
        mac = wanMac;
      }
    ];
      networking.nftables = {
        enable = true;
        ruleset = let
          # NOTE: FW Rules will pick the first VLAN when multiple are available.
          fwRules = lib.concatStringsSep "\n" (lib.flatten (map lib.mapAttrsToList (name: cfg: (map rule: (map: src:
          if src == "external" then
            "iifname wan oifname ${lib.head cfg.vlans} ip daddr ${getIp name (lib.head cfg.vlans)} ${rule.proto} dport ${toString rule.port} accept"
          else
          let rec
              intersectedVlan = lib.intersectLists cfg.vlans topology.vms.${src}.vlans;
              vlanSrc = if intersectedVlan == [] then lib.head topology.vms.${src}.vlans else intersectedVlan;
              vlanDest = if intersectedVlan == [] then lib.head cfg.vlans else intersectedVlan;
          in
            "iifname ${vlanSrc} oifname ${vlanDest} ip daddr ${getIp name vlanDest} ${rule.proto} dport ${toString rule.port} accept"
              rule.allowFrom) cfg.provides) topology.vms)));
          natRules = lib.concatStringsSep "\n" (lib.flatten (lib.mapAttrsToList (name: cfg: (map rule: (map: src
          "iifname wan ${rule.proto} dport ${toString rule.port} dnat to ${getIp name (lib.head cfg.vlans)}"
          rule.allowFrom) cfg.provides) topology.vms)));
        in ''
          table inet filter {
            chain input {
              type filter hook input priority 0; policy drop;
              iif "lo" accept
            }
            chain forward {
              type filter hook forward priority 0; policy drop;
              ct state established,related accept
              ${fwRules}
            }
          }
          table ip nat {
            chain prerouting {
              type nat hook prerouting priority dstnat;
              ${natRules}
            }
            chain postrouting {
              type nat hook postrouting priority srcnat;
              oifname wan masquerade
            }
          }
        '';
      };
    };

    # UNBOUND CONFIG
    mkDns = {
      services.unbound = {
        enable = true;
        settings.server = {
          interface = [ "0.0.0.0" ];
          access-control = [ "10.0.0.0/8 allow" ];
          local-zone = ''"${topology.domain}." static'';
          local-data = lib.mapAttrsToList (name: conf:
          ''"${name}.${topology.domain}. IN A ${getIp name (lib.head conf.vlans)}"''
          ) topology.vms;
        };
      };
    };
  };
}
