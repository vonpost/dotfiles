{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.my.infra.networkGuest;
  topology = config.my.infra.topology;
  topo = import ../../infra-topology.nix { inherit topology; };
  vm = topology.vms.${cfg.name};
  vlans = topo.vlans;
  firewallRules = topology.firewallRules;
  natRules = topology.natRules;
in
{
  options.my.infra.networkGuest = {
    enable = mkEnableOption "guest networking config from my.infra.topology";
    name = mkOption {
      type = types.str;
      default = "MAMORU";
      description = "VM name key in my.infra.topology.vms.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.name topology.vms;
        message = "my.infra.networkGuest.name '${cfg.name}' does not exist in my.infra.topology.vms";
      }
    ];

    microvm.interfaces =
      map
          (vlan: {
            type = "tap";
            id = "tap-${vlan}-${cfg.name}";
            mac = topo.getMac cfg.name vlan;
          })
        vm.assignedVlans;

    systemd.network = {
      enable = true;

      networks = builtins.listToAttrs (
        map
          (vlan: {
            name = "20-${vlan}";
            value = {
              matchConfig.MACAddress = topo.getMac cfg.name vlan;
              networkConfig =
                {
                  Address = "${topo.getIp cfg.name vlan}/24";
                  Gateway = if cfg.name != topology.gatewayVM then topo.getGateway vlan else null;
                  DNS = topo.getDns;
                  IPv6AcceptRA = (cfg.name != topology.gatewayVM);
                }
                // (
                  if cfg.name == topology.gatewayVM then
                    {
                      IPv6SendRA = true;
                      DHCPPrefixDelegation = true;
                    }
                  else
                    { }
                );
            };
          })
          vm.assignedVlans
      );

      links = builtins.listToAttrs (
        map
          (vlan: {
            name = "50-custom-name-${vlan}";
            value = {
              matchConfig.PermanentMACAddress = topo.getMac cfg.name vlan;
              linkConfig.Name = vlan;
            };
          })
          vm.assignedVlans
      );
    };

    boot.kernelParams = [ "ipv6.disable=${if vm.ipv6 then "0" else "1"}" ];

    networking = {
      nftables.enable = true;
      useDHCP = false;
      useNetworkd = true;
      enableIPv6 = vm.ipv6;
      firewall =
        let
          fwtcp =
            map (rule: firewallRules.${rule}.port)
              (builtins.filter (rule: firewallRules.${rule}.proto == "tcp") vm.provides);
          fwudp =
            map (rule: firewallRules.${rule}.port)
              (builtins.filter (rule: firewallRules.${rule}.proto == "udp") vm.provides);
          nattcp =
            map (rule: natRules.${rule}.port)
              (builtins.filter (rule: natRules.${rule}.proto == "tcp") vm.portForward);
          natudp =
            map (rule: natRules.${rule}.port)
              (builtins.filter (rule: natRules.${rule}.proto == "udp") vm.portForward);
        in
        {
          enable = true;
          allowedTCPPorts = fwtcp ++ nattcp;
          allowedUDPPorts = fwudp ++ natudp;
        };
    };
  };
}
