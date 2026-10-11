{ topology
, vlans ? topology.vlans
}:
let
  # Fleet modules provide the evaluated topology, including VM overrides.
  # Standalone consumers such as TERRA's WireGuard settings import the raw
  # topology file; derive their identities from the same canonical inventory.
  vms = topology.vms or (builtins.listToAttrs (map (vm: {
    name = vm.name;
    value = { inherit (vm) id primaryVlan; };
  }) (import ../config/infra/inventory.nix)));
in
rec {
  inherit vlans;

  getSubnet = vlan: "10.10.${toString vlans.${vlan}.id}";

  getIp = name: vlan:
    "${getSubnet vlan}.${toString vms.${name}.id}";

  getPrimaryIp = name: getIp name vms.${name}.primaryVlan;

  getPort = name: topology.firewallRules.${name}.port;

  getMac = name: vlan:
    "02:00:00:00:${toString vlans.${vlan}.id}:${toString vms.${name}.id}";

  getGateway = vlan:
    "${getSubnet vlan}.${toString vms.${topology.gatewayVM}.id}";

  getDns = getIp topology.dnsVM "srv";
}
