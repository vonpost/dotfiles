{ topology
, vlans ? topology.vlans
}:
rec {
  inherit vlans;

  getSubnet = vlan: "10.10.${toString vlans.${vlan}.id}";

  getIp = name: vlan:
    "${getSubnet vlan}.${toString topology.vms.${name}.id}";

  getMac = name: vlan:
    "02:00:00:00:${toString vlans.${vlan}.id}:${toString topology.vms.${name}.id}";

  getGateway = vlan:
    "${getSubnet vlan}.${toString topology.vms.${topology.gatewayVM}.id}";

  getDns = getIp topology.dnsVM "srv";
}
