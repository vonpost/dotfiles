{ lib, ... }:
let
  topology = rec {
    domain = "lan";
    gatewayVM = "MAMORU"; # The VM acting as the router/firewall
    dnsVM = "DARE";
    hostIp = "10.10.10.99";

    firewallRules = {
      dns_udp = { port = 53; proto = "udp"; allowFrom = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU"  ]; };
      dns_tcp = { port = 53; proto = "tcp"; allowFrom = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" ]; };
      sonarr = { port=8989; proto = "tcp"; allowFrom = [ "SOTO" "KAIZOKU" ]; };
      radarr = { port=7878; proto = "tcp"; allowFrom = [ "SOTO" "KAIZOKU" ]; };
      prowlarr = { port=9696; proto = "tcp"; allowFrom = [  ]; };
      qbit = { port=8080; proto = "tcp"; allowFrom = [ "UCHI" ]; };
      sabnzbd = { port=1337; proto = "tcp"; allowFrom = [ "UCHI" ]; };
      jellyfin = { port=8096; proto = "tcp"; allowFrom = [ "UCHI" ]; };
      ssh = { port = 22; proto = "tcp"; allowFrom = [ "MAMORU" ]; };
      sshRouter = { port = 22; proto = "tcp"; allowFrom = [ "UCHI" ]; }; # Just temporary for testing
      wolf_https = { port = 47984; proto = "tcp"; allowFrom = [];};
      wolf_http = { port = 47989; proto = "tcp"; allowFrom = [];};
      wolf_control = { port = 47999; proto = "udp"; allowFrom = [];};
      wolf_rtsp_setup = { port = 48010; proto = "tcp"; allowFrom = [];};
      wolf_video_ping = { port = 48100; proto = "udp"; allowFrom = [];};
      wolf_audio_ping = { port = 48200; proto = "udp"; allowFrom = [];};
      wolf_den = {port = 8080; proto = "tcp"; allowFrom  = []; };
      llama_server = { port = 8888; proto = "tcp"; allowFrom = []; };
    };

    natRules = {
      http = { port = 80; proto = "tcp"; externalPort = 80; };
      wireguard = { port = 51820; proto = "udp"; externalPort = 51822; };
      https = { port = 443; proto = "tcp"; externalPort = 443; };
      battle_net = { port = 1119; proto = "tcp"; externalPort = 1119; };
    };

    vms = {
      MAMORU = {
        id = 10;
        assignedVlans = [ "mgmt" "srv" "dmz" ]; # WAN is handled manually
        ipv6 = true;
        provides = [ ];
        portForward = [ ];
      };
      KAIZOKU = {
        id = 15;
        assignedVlans = [ "srv" ]; # WAN is handled manually
        ipv6 = true;
        provides = [ "ssh" "qbit" "sabnzbd" ];
        portForward = [];
      };

      UCHI = {
        id = 20;
        assignedVlans = [ "srv" ];
        ipv6 = false;
        provides = [ "ssh" "sonarr" "radarr" "prowlarr"];
        portForward = [];
      };
      DARE = {
        id = 53;
        assignedVlans = [ "srv" ];
        ipv6 = false;
        provides = [ "dns_tcp" "dns_udp" "ssh" ];
        portForward = [];
      };
      SOTO = {
        id = 25;
        assignedVlans = [ "dmz" ];
        ipv6 = false;
        provides = [ "ssh" "jellyfin" ];
        portForward = [ "http" "https" ];
      };
      OKAMI = {
        id = 30;
        assignedVlans = [ "srv" ];
        ipv6 = true;
        provides = [ "ssh" "wolf_http" "wolf_https" "wolf_control" "wolf_rtsp_setup" "wolf_video_ping" "wolf_audio_ping" "llama_server" "wolf_den"];
        portForward = [ "battle_net"];
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
  inherit getGateway getDns getSubnet vlans;
  inherit (topology) vms;
    # HOST CONFIG: Bridges and Taps
    mkHostNetwork = {
      systemd.network = {
        netdevs = builtins.listToAttrs (map (vlan: {
          name = "40-br-${vlan}";
          value = {
            netdevConfig = {
              Name = "br-${vlan}";
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
                matchConfig.Name = "br-*";
                linkConfig.RequiredForOnline = "no";
                networkConfig = {
                  DHCP=false;
                  IPv6AcceptRA=false;
                  LinkLocalAddressing=false;
                  ConfigureWithoutCarrier = true;
                };
              };
            }

            {
              name = "20-br-mgmt";
              value = {
                matchConfig.Name = "br-mgmt";
                address = [ "${topology.hostIp}/24" ];
                dns = [ (getDns) ];
                networkConfig.BindCarrier = "enp8s0";
                routes = [ { Gateway=getGateway "mgmt"; Metric=100; } ] ++ map (vlan:
                  {
                    Destination="${getSubnet vlan}.0/24";
                    Gateway=getGateway "mgmt";
                  }
                ) (builtins.attrNames (builtins.removeAttrs vlans ["mgmt"]));
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
                  Bridge = "br-${vlan}";
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
                IPv6AcceptRA = (name != topology.gatewayVM);

              } // (if name == topology.gatewayVM then {
                IPv6SendRA = true;            # advertise to clients
                DHCPPrefixDelegation = true;  # get a /64 per VLAN from the WAN PD pool
              } else {});
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
        boot.kernelParams = [ "ipv6.disable=${if vm.ipv6 then "0" else "1"}" ];
        networking = {
          nftables.enable = true;
          useDHCP = false;
          useNetworkd = true;
          enableIPv6 = vm.ipv6;
          # Not sure if this is needed as well since we did set dns for the systemd definition.. nameservers = [ (getIp dnsVM "srv") ];
          firewall =
          let
            fwtcp=map (p: firewallRules.${p}.port) (builtins.filter (p: firewallRules.${p}.proto == "tcp") vm.provides);
            fwudp=map (p: firewallRules.${p}.port) (builtins.filter (p: firewallRules.${p}.proto == "udp") vm.provides);
            nattcp=map (p: topology.natRules.${p}.port) (builtins.filter (p: topology.natRules.${p}.proto == "tcp") vm.portForward);
            natudp=map (p: topology.natRules.${p}.port) (builtins.filter (p: topology.natRules.${p}.proto == "udp") vm.portForward);
          in
          {
            enable = true;
            allowedTCPPorts = fwtcp++nattcp;
            allowedUDPPorts = fwudp++natudp;
          };
        };
      };

    # GATEWAY CONFIG: Firewall & NAT (Assumes WAN is wan)
    mkGateway = {
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv4.conf.all.rp_filter" = 1;
        "net.ipv4.conf.default.rp_filter" = 1;

        "net.ipv6.conf.default.accept_ra" = 2;
        "net.ipv6.conf.all.forwarding" = 1;
        "net.ipv6.conf.default.forwarding" = 1;
        # critical: when forwarding=1, Linux otherwise ignores RAs.
        # accept_ra=2 means "accept RA even if forwarding".
        "net.ipv6.conf.wan.accept_ra" = 2;
      };

    systemd.network.links."50-custom-name-wan" = {
        matchConfig.PermanentMACAddress = wanMac;
        linkConfig.Name = "wan"; # Desired new name
    };
    systemd.network.networks."10-wan" = {
      matchConfig.MACAddress = wanMac;
      networkConfig = {
        DHCP="ipv4";
        #IPv6AcceptRA="yes";
      };
      dhcpV4Config = {
        UseDNS = true;
        UseRoutes = true;
        UseGateway = true;
      };
      #dhcpV6Config = {
      #  UseDNS=true;
      #};
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
          ) (builtins.filter (x: topology.natRules.${x}.port != topology.natRules.${x}.externalPort) topology.vms.${topology.gatewayVM}.portForward));

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

          mgmtRules = lib.concatStringsSep "\n" (map (vlan: "iifname mgmt oifname ${vlan} ct state new accept") (builtins.attrNames (builtins.removeAttrs vlans ["mgmt"])));

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
              ip6 nexthdr icmpv6 accept
              iifname "mgmt" ip protocol icmp icmp type echo-request accept
              ${inputRules}
              ${inputRulesExt}
              iifname "wan" limit rate 10/second burst 20 packets counter log prefix "INP_WAN_DROP " drop
              iifname "mgmt" limit rate 5/second burst 10 packets counter log prefix "MGMT_TO_ROUTER_DROP " drop

            }
            chain forward {
              type filter hook forward priority 0; policy drop;
              # --- IPV6  ---
              meta nfproto ipv6 ip6 nexthdr icmpv6 accept
              # Allow LAN -> WAN (Internet Access)
              iifname { ${lib.strings.concatStringsSep "," (builtins.attrNames (builtins.removeAttrs vlans ["dmz"])) } } oifname wan meta nfproto ipv6 ct state new accept
              # Egress restrictions for dmz
              iifname "dmz" oifname "wan" meta nfproto ipv6 tcp dport { 80, 443 } ct state new accept
              iifname "dmz" oifname "wan" meta nfproto ipv6 udp dport { 53, 123 } ct state new accept
              iifname "dmz" oifname "wan" meta nfproto ipv6 tcp dport { 53 } ct state new accept
              ct state established,related meta nfproto ipv6 accept
              # Explicitly drop all other IPv6 forwarding
              meta nfproto ipv6 drop
              # IPV4
              ct state established,related accept
              iifname { ${lib.strings.concatStringsSep "," (builtins.attrNames (builtins.removeAttrs vlans ["dmz"])) } } oifname wan ct state new accept
              #HTTP/HTTPS
              iifname "dmz" oifname "wan" tcp dport {80,443} ct state new accept
              #DNS
              iifname "dmz" oifname "wan" udp dport {53,123} ct state new accept
              iifname "dmz" oifname "wan" tcp dport {53} ct state new accept
              #WIREGUARD egress/ingress
              iifname "mgmt" oifname "wan" ip daddr ${topology.hostIp} udp dport 51820 ct state new accept
              iifname "wan" oifname "mgmt" ip daddr ${topology.hostIp} udp dport 51820 ct state new accept
              ${mgmtRules}
              ${fwRules}
              ${fwRulesExt}
              iifname "wan" limit rate 10/second burst 20 packets counter log prefix "FWD_WAN_DROP " drop
            }
          }
          table ip nat {
            chain prerouting {
              type nat hook prerouting priority dstnat;
              iifname wan udp dport 51822 dnat to ${topology.hostIp}:51820
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
        interface = [ (getIp topology.dnsVM "srv") "127.0.0.1" ];
        access-control = [ "10.0.0.0/8 allow" ];
        local-zone = ''"${topology.domain}." static'';
        local-data = lib.mapAttrsToList (name: conf:
        ''"${name}.${topology.domain}. IN A ${getIp name (lib.head conf.assignedVlans)}"''
        ) topology.vms;

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
  };
}
