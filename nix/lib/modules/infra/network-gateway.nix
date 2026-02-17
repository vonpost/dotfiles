{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.my.infra.networkGateway;
  topology = config.my.infra.topology;
  vlans = topology.vlans;
  firewallRules = topology.firewallRules;
  natRules = topology.natRules;

  getSubnet = vlan: "10.10.${toString vlans.${vlan}.id}";
  getIp = name: vlan: "${getSubnet vlan}.${toString topology.vms.${name}.id}";
in
{
  options.my.infra.networkGateway.enable = mkEnableOption "gateway nftables/NAT/WAN setup from my.infra.topology";

  config = mkIf cfg.enable {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv6.conf.default.accept_ra" = 2;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.ipv6.conf.default.forwarding" = 1;
      "net.ipv6.conf.wan.accept_ra" = 2;
    };

    systemd.network.links."50-custom-name-wan" = {
      matchConfig.PermanentMACAddress = topology.wanMac;
      linkConfig.Name = "wan";
    };

    systemd.network.networks."10-wan" = {
      matchConfig.MACAddress = topology.wanMac;
      networkConfig = {
        DHCP = "ipv4";
      };
      dhcpV4Config = {
        UseDNS = true;
        UseRoutes = true;
        UseGateway = true;
      };
      linkConfig.RequiredForOnline = "no";
    };

    microvm.interfaces = [
      {
        type = "tap";
        id = "tap-wan-${topology.gatewayVM}";
        mac = topology.wanMac;
      }
    ];

    networking.firewall.enable = lib.mkForce false;
    networking.nftables = {
      enable = true;
      ruleset =
        let
          vms = builtins.removeAttrs topology.vms [ topology.gatewayVM ];

          inputRules =
            lib.concatStringsSep "\n" (
              lib.flatten (
                map
                  (rule:
                    map
                      (src:
                        let
                          vlanSrc = lib.head topology.vms.${src}.assignedVlans;
                        in
                        "iifname ${vlanSrc} ip saddr ${getIp src vlanSrc} ip daddr ${getIp topology.gatewayVM vlanSrc} ${firewallRules.${rule}.proto} dport ${toString firewallRules.${rule}.port} ct state new accept"
                      )
                      firewallRules.${rule}.allowFrom
                  )
                  topology.vms.${topology.gatewayVM}.provides
              )
            );

          inputRulesExt =
            lib.concatStringsSep "\n" (
              map
                (rule: "iifname wan ${natRules.${rule}.proto} dport ${toString natRules.${rule}.port} ct state new accept")
                topology.vms.${topology.gatewayVM}.portForward
            );

          redirectRules =
            lib.concatStringsSep "\n" (
              map
                (rule:
                  "iifname wan ${natRules.${rule}.proto} dport ${toString natRules.${rule}.externalPort} redirect to :${toString natRules.${rule}.port}"
                )
                (builtins.filter (rule: natRules.${rule}.port != natRules.${rule}.externalPort) topology.vms.${topology.gatewayVM}.portForward)
            );

          fwRules =
            lib.concatStringsSep "\n" (
              lib.flatten (
                lib.mapAttrsToList
                  (name: vmCfg:
                    map
                      (rule:
                        builtins.filter
                          (line: line != "")
                          (
                            map
                              (src:
                                let
                                  intersectedVlan = lib.intersectLists vmCfg.assignedVlans topology.vms.${src}.assignedVlans;
                                  vlanSrc = if intersectedVlan == [ ] then lib.head topology.vms.${src}.assignedVlans else lib.head intersectedVlan;
                                  vlanDest = if intersectedVlan == [ ] then lib.head vmCfg.assignedVlans else lib.head intersectedVlan;
                                in
                                if intersectedVlan == [ ] then
                                  "iifname ${vlanSrc} oifname ${vlanDest} ip saddr ${getIp src vlanSrc} ip daddr ${getIp name vlanDest} ${firewallRules.${rule}.proto} dport ${toString firewallRules.${rule}.port} ct state new accept"
                                else
                                  ""
                              )
                              firewallRules.${rule}.allowFrom
                          )
                      )
                      vmCfg.provides
                  )
                  vms
              )
            );

          mgmtRules =
            lib.concatStringsSep "\n" (
              map
                (vlan: "iifname mgmt oifname ${vlan} ct state new accept")
                (builtins.attrNames (builtins.removeAttrs vlans [ "mgmt" ]))
            );

          fwRulesExt =
            lib.concatStringsSep "\n" (
              lib.flatten (
                lib.mapAttrsToList
                  (name: vmCfg:
                    map
                      (rule:
                        "iifname wan oifname ${lib.head vmCfg.assignedVlans} ip daddr ${getIp name (lib.head vmCfg.assignedVlans)} ${natRules.${rule}.proto} dport ${toString natRules.${rule}.port} ct state new accept"
                      )
                      vmCfg.portForward
                  )
                  vms
              )
            );

          natDnats =
            lib.concatStringsSep "\n" (
              lib.flatten (
                lib.mapAttrsToList
                  (name: vmCfg:
                    map
                      (rule:
                        "iifname wan ${natRules.${rule}.proto} dport ${toString natRules.${rule}.externalPort} dnat to ${getIp name (lib.head vmCfg.assignedVlans)}:${toString natRules.${rule}.port}"
                      )
                      vmCfg.portForward
                  )
                  vms
              )
            );
        in
        ''
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
              iifname { ${lib.concatStringsSep "," (builtins.attrNames (builtins.removeAttrs vlans [ "dmz" ]))} } oifname wan meta nfproto ipv6 ct state new accept
              # Egress restrictions for dmz
              iifname "dmz" oifname "wan" meta nfproto ipv6 tcp dport { 80, 443 } ct state new accept
              iifname "dmz" oifname "wan" meta nfproto ipv6 udp dport { 53, 123 } ct state new accept
              iifname "dmz" oifname "wan" meta nfproto ipv6 tcp dport { 53 } ct state new accept
              ct state established,related meta nfproto ipv6 accept
              # Explicitly drop all other IPv6 forwarding
              meta nfproto ipv6 drop
              # IPV4
              ct state established,related accept
              iifname { ${lib.concatStringsSep "," (builtins.attrNames (builtins.removeAttrs vlans [ "dmz" ]))} } oifname wan ct state new accept
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
              ${natDnats}
            }
            chain postrouting {
              type nat hook postrouting priority srcnat;
              oifname wan masquerade
            }
          }
        '';
    };
  };
}
