{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.my.infra.networkHost;
  topology = config.my.infra.topology;
  topo = import ../../infra-topology.nix { inherit topology; };
  vlans = topo.vlans;
in
{
  options.my.infra.networkHost = {
    enable = mkEnableOption "host bridge/tap network configuration from my.infra.topology";
    wanBridge = mkOption {
      type = types.str;
      default = topology.wanBridge;
      description = "Bridge used for host WAN tap interfaces.";
    };
  };

  config = mkIf cfg.enable {
    systemd.network = {
      netdevs = builtins.listToAttrs (
        map
          (vlan: {
            name = "40-br-${vlan}";
            value = {
              netdevConfig = {
                Name = "br-${vlan}";
                Kind = "bridge";
              };
            };
          })
          (builtins.attrNames vlans)
      );

      networks = builtins.listToAttrs (
        [
          {
            name = "50-br-vlan";
            value = {
              matchConfig.Name = "br-*";
              linkConfig.RequiredForOnline = "no";
              networkConfig = {
                DHCP = false;
                IPv6AcceptRA = false;
                LinkLocalAddressing = false;
                ConfigureWithoutCarrier = true;
              };
            };
          }
          {
            name = "20-br-mgmt";
            value = {
              matchConfig.Name = "br-mgmt";
              address = [ "${topology.hostIp}/24" ];
              dns = [ topo.getDns ];
              networkConfig.BindCarrier = "enp8s0";
              routes =
                [ { Gateway = topo.getGateway "mgmt"; Metric = 100; } ]
                ++ map
                  (vlan: {
                    Destination = "${topo.getSubnet vlan}.0/24";
                    Gateway = topo.getGateway "mgmt";
                  })
                  (builtins.attrNames (builtins.removeAttrs vlans [ "mgmt" ]));
              linkConfig.RequiredForOnline = "no";
            };
          }
          {
            name = "50-tap-wan";
            value = {
              matchConfig.Name = "tap-wan-*";
              networkConfig = {
                Bridge = cfg.wanBridge;
                ConfigureWithoutCarrier = true;
              };
              linkConfig.RequiredForOnline = "no";
            };
          }
        ]
        ++ map
          (vlan: {
            name = "50-tap-${vlan}";
            value = {
              matchConfig.Name = "tap-${vlan}-*";
              linkConfig.RequiredForOnline = "no";
              networkConfig = {
                Bridge = "br-${vlan}";
                ConfigureWithoutCarrier = true;
              };
            };
          })
          (builtins.attrNames vlans)
      );
    };
  };
}
