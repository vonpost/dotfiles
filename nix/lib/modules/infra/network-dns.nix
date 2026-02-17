{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.my.infra.networkDns;
  topology = config.my.infra.topology;
  vlans = topology.vlans;

  getSubnet = vlan: "10.10.${toString vlans.${vlan}.id}";
  getIp = name: vlan: "${getSubnet vlan}.${toString topology.vms.${name}.id}";
in
{
  options.my.infra.networkDns.enable = mkEnableOption "unbound DNS config from my.infra.topology";

  config = mkIf cfg.enable {
    services.unbound = {
      enable = true;
      settings.server = {
        interface = [ (getIp topology.dnsVM "srv") "127.0.0.1" ];
        access-control = [ "10.0.0.0/8 allow" ];
        local-zone = ''"${topology.domain}." static'';
        local-data =
          lib.mapAttrsToList
            (name: vmCfg: ''"${name}.${topology.domain}. IN A ${getIp name (lib.head vmCfg.assignedVlans)}"'')
            topology.vms;
        hide-identity = "yes";
        hide-version = "yes";
        qname-minimisation = "yes";
        prefetch = "yes";
        cache-min-ttl = 60;
        cache-max-ttl = 86400;
      };

      settings.forward-zone = [
        {
          name = ".";
          forward-addr = [ "9.9.9.9" "1.1.1.1" ];
        }
      ];
    };
  };
}
