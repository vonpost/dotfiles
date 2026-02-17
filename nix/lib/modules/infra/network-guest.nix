{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.my.infra.networkGuest;
  topology = config.my.infra.topology;
  vm = topology.vms.${cfg.name};
  vlans = topology.vlans;
  firewallRules = topology.firewallRules;
  natRules = topology.natRules;

  getSubnet = vlan: "10.10.${toString vlans.${vlan}.id}";
  getIp = name: vlan: "${getSubnet vlan}.${toString topology.vms.${name}.id}";
  getMac = name: vlan: "02:00:00:00:${toString vlans.${vlan}.id}:${toString topology.vms.${name}.id}";
  getGateway = vlan: "${getSubnet vlan}.${toString topology.vms.${topology.gatewayVM}.id}";
  getDns = getIp topology.dnsVM "srv";
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
          mac = getMac cfg.name vlan;
        })
        vm.assignedVlans;

    systemd.network = {
      enable = true;

      networks = builtins.listToAttrs (
        map
          (vlan: {
            name = "20-${vlan}";
            value = {
              matchConfig.MACAddress = getMac cfg.name vlan;
              networkConfig =
                {
                  Address = "${getIp cfg.name vlan}/24";
                  Gateway = if cfg.name != topology.gatewayVM then getGateway vlan else null;
                  DNS = getDns;
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
              matchConfig.PermanentMACAddress = getMac cfg.name vlan;
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
