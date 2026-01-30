{ lib, ... }:
let
  topology = rec {
    domain = "lan";
    gatewayVM = "MAMORU"; # The VM acting as the router/firewall
    dnsVM = "DARE";

    firewallRules = {
      dns_udp = { port = 53; proto = "udp"; allowFrom = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" "MAMORU" ]; };
      dns_tcp = { port = 53; proto = "tcp"; allowFrom = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" "MAMORU" ]; };
      ssh = { port = 22; proto = "tcp"; allowFrom = [ "MAMORU" ]; };
      sshRouter = { port = 22; proto = "tcp"; allowFrom = [ "UCHI" ]; }; # Just temporary for testing
    };

    natRules = {
      http = { port = 80; proto = "tcp"; externalPort = 80; };
      wireguard = { port = 51820; proto = "udp"; externalPort = 51822; };
      https = { port = 443; proto = "tcp"; externalPort = 443; };
    };

    vms = {
      MAMORU = {
        id = 10;
        assignedVlans = [ "mgmt" "srv" "dmz" ]; # WAN is handled manually
        provides = [ "sshRouter" ];
        portForward = [ "wireguard" ];
      };
      KAIZOKU = {
        id = 15;
        assignedVlans = [ "srv" ]; # WAN is handled manually
        provides = [ "ssh" ];
        portForward = [];
      };

      UCHI = {
        id = 20;
        assignedVlans = [ "srv" ];
        provides = [ "ssh" ];
        portForward = [];
      };
      DARE = {
        id = 53;
        assignedVlans = [ "srv" ];
        provides = [ "dns_tcp" "dns_udp" "ssh" ];
        portForward = [];
      };
      SOTO = {
        id = 25;
        assignedVlans = [ "dmz" ];
        provides = [ "ssh" ];
        portForward = [ "http" "https" ];
      };
      OKAMI = {
        id = 30;
        assignedVlans = [ "dmz" ];
        provides = [ "ssh" ];
        portForward = [];
      };
    };
  };

  wanMac = "02:00:00:00:00:90";
  wanBridge = "br0";
  vlans = {
    mgmt = { id = 10; };
    srv  = { id = 20; };
    dmz  = { id = 30; };
  };

  getSubnet = vlan: "10.10.${toString vlans.${vlan}.id}";
  getIp = name: vlan: "${getSubnet vlan}.${toString topology.vms.${name}.id}";
  getMac = vm: vlan: "02:00:00:00:${toString vlans.${vlan}.id}:${toString topology.vms.${vm}.id}";
  getGateway = vlan: "${getSubnet vlan}.${toString topology.vms.${topology.gatewayVM}.id}";
  getDns = getIp topology.dnsVM "srv";
  firewallRules = topology.firewallRules;
in {
    # HOST CONFIG: Bridges and Taps
    mkHostNetwork = {
      systemd.network = {
        netdevs = builtins.listToAttrs (map (vlan: {
          name = "40-br-vlan-${vlan}";
          value = {
            netdevConfig = {
              Name = "br-vlan-${vlan}";
              Kind = "bridge";
            };
          };
        }) (builtins.attrNames vlans));
        networks = builtins.listToAttrs (
          [
            {
              # Bridges online without carrier
              name = "50-br-vlan";
              value = {
                matchConfig.Name = "br-vlan-*";
                networkConfig.ConfigureWithoutCarrier = true;
                linkConfig.RequiredForOnline = "no";
              };
            }

            {
              # Bridges online without carrier
              name = "50-tap-wan";
              value = {
                matchConfig.Name = "tap-wan-*";
                networkConfig = {
                  Bridge = wanBridge;
                  ConfigureWithoutCarrier = true;
                };
                linkConfig.RequiredForOnline = "no";
              };
            }
          ] ++ (map (vlan:
              # Attach taps to bridge
            {
              name = "50-tap-${vlan}";
              value = {
                matchConfig.Name = "tap-${vlan}-*";
                linkConfig.RequiredForOnline = "no";
                networkConfig = {
                  Bridge = "br-vlan-${vlan}";
                  ConfigureWithoutCarrier = true;
                };
              };
            }) (builtins.attrNames vlans)));
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
          networks = builtins.listToAttrs (map (vlan:
          {
            name="20-${vlan}";
            value = {
              matchConfig.MACAddress = getMac name vlan;
              networkConfig = {
                Address = "${getIp name vlan}/24";
                Gateway = if (name != topology.gatewayVM) then (getGateway vlan) else null;
                DNS = getDns;
              };
            };
          }) vm.assignedVlans);

          # Rename to map to the VLAN names.
          links = builtins.listToAttrs (map (vlan:
          {
            name = "50-custom-name-${vlan}";
            value = {
              matchConfig.PermanentMACAddress = getMac name vlan;
              linkConfig.Name = vlan; # Desired new name
            };
          }) vm.assignedVlans);
        };

        # Rest of the networking config
        boot.kernelParams = [ "ipv6.disable=1" ];
        networking = {
          useDHCP = false;
          useNetworkd = true;
          enableIPv6 = false;
          # Not sure if this is needed as well since we did set dns for the systemd definition.. nameservers = [ (getIp dnsVM "srv") ];
          firewall = {
            enable = true;
            allowedTCPPorts = map (p: firewallRules.${p}.port) (builtins.filter (p: firewallRules.${p}.proto == "tcp") vm.provides);
            allowedUDPPorts = map (p: firewallRules.${p}.port) (builtins.filter (p: firewallRules.${p}.proto == "udp") vm.provides);
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

    systemd.network.links."50-custom-name-wan" = {
        matchConfig.PermanentMACAddress = wanMac;
        linkConfig.Name = "wan"; # Desired new name
    };
    systemd.network.networks."10-wan" = {
      matchConfig.MACAddress = wanMac;
      networkConfig = {
        Address = "192.168.1.166/24";
        Gateway = "192.168.1.1";
        DNS = "9.9.9.9";
      };
      # networkConfig = {
      #   DHCP="ipv4";
      # };
      # dhcpV4Config = {
      #   UseDNS = true;
      #   UseRoutes = true;
      #   UseGateway = true;
      # };
      linkConfig.RequiredForOnline = "no";
    };

    microvm.interfaces = [
      {
        type = "tap";
        id = "tap-wan-${topology.gatewayVM}";
        mac = wanMac;
      }
    ];
    networking.firewall.enable = lib.mkForce false;
    networking.nftables = {
        enable = true;
        ruleset = let
          vms = builtins.removeAttrs topology.vms [ topology.gatewayVM ];
          # NOTE: FW Rules will pick the first VLAN when multiple are available.
          inputRules = lib.concatStringsSep "\n" (lib.flatten (map (rule: (map (src:
          let
            vlanSrc = lib.head topology.vms.${src}.assignedVlans;
          in
            "iifname ${vlanSrc} ip saddr ${getIp src vlanSrc} ip daddr ${getIp topology.gatewayVM vlanSrc} ${firewallRules.${rule}.proto} dport ${toString firewallRules.${rule}.port} ct state new accept"
          ) firewallRules.${rule}.allowFrom)) topology.vms.${topology.gatewayVM}.provides));

          inputRulesExt = lib.concatStringsSep "\n" (map (rule:
            "iifname wan ${topology.natRules.${rule}.proto} dport ${toString topology.natRules.${rule}.port} ct state new accept"
          ) topology.vms.${topology.gatewayVM}.portForward);

          redirectRules = lib.concatStringsSep "\n" (map (rule:
            "iifname wan ${topology.natRules.${rule}.proto} dport ${toString topology.natRules.${rule}.externalPort} redirect to :${toString topology.natRules.${rule}.port}"
          ) topology.vms.${topology.gatewayVM}.portForward);

          fwRules = lib.concatStringsSep "\n" (lib.flatten (lib.mapAttrsToList (name: cfg: (map (rule: (builtins.filter (x: x!="") (map (src:
          let
              intersectedVlan = lib.intersectLists cfg.assignedVlans topology.vms.${src}.assignedVlans;
              vlanSrc = if intersectedVlan == [] then lib.head topology.vms.${src}.assignedVlans else lib.head intersectedVlan;
              vlanDest = if intersectedVlan == [] then lib.head cfg.assignedVlans else lib.head intersectedVlan;
          in
            if (intersectedVlan == []) then
              "iifname ${vlanSrc} oifname ${vlanDest} ip saddr ${getIp src vlanSrc} ip daddr ${getIp name vlanDest} ${firewallRules.${rule}.proto} dport ${toString firewallRules.${rule}.port} ct state new accept"
            else
              ""
          ) firewallRules.${rule}.allowFrom))) cfg.provides)) vms));

          fwRulesExt = lib.concatStringsSep "\n" (lib.flatten (lib.mapAttrsToList (name: cfg: (map (rule:
            "iifname wan oifname ${lib.head cfg.assignedVlans} ip daddr ${getIp name (lib.head cfg.assignedVlans)} ${topology.natRules.${rule}.proto} dport ${toString topology.natRules.${rule}.port} ct state new accept"
          ) cfg.portForward)) vms));

          natRules = lib.concatStringsSep "\n" (lib.flatten (lib.mapAttrsToList (name: cfg: (map (rule:
            "iifname wan ${topology.natRules.${rule}.proto} dport ${toString topology.natRules.${rule}.externalPort} dnat to ${getIp name (lib.head cfg.assignedVlans)}:${toString topology.natRules.${rule}.port}"
          ) cfg.portForward)) vms));
        in ''
          table inet filter {
            chain input {
              type filter hook input priority 0; policy drop;
              iif "lo" accept
              ct state invalid drop
              ct state established,related accept
              ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
              iifname "mgmt" ip protocol icmp icmp type echo-request accept
              ${inputRules}
              ${inputRulesExt}
              iifname "wan" limit rate 10/second burst 20 packets counter log prefix "INP_WAN_DROP " drop

            }
            chain forward {
              type filter hook forward priority 0; policy drop;
              ct state established,related accept
              iifname { ${lib.strings.concatStringsSep "," (builtins.attrNames (builtins.removeAttrs vlans ["dmz"])) } } oifname wan ct state new accept
              iifname "dmz" oifname "wan" ct state new tcp dport {80,443} accept
              iifname "dmz" oifname "wan" ct state new udp dport {53,123} accept
              ${fwRules}
              ${fwRulesExt}
              iifname "wan" limit rate 10/second burst 20 packets counter log prefix "FWD_WAN_DROP " drop
            }
          }
          table ip nat {
            chain prerouting {
              type nat hook prerouting priority dstnat;
              ${redirectRules}
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
        ''"${name}.${topology.domain}. IN A ${getIp name (lib.head conf.assignedVlans)}"''
        ) topology.vms;
      };
    };
  };
}
