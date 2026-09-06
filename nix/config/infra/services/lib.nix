{ config, lib }:
let
  hostname = config.networking.hostName;
  hostConfig = config.my.infra.vms.${hostname} or { services = [ ]; };
  assignedServices = hostConfig.services;
  topology = config.my.infra.topology;
  topo = import ../../../lib/infra-topology.nix { inherit topology; };
  vm = topology.vms.${hostname};
in
{
  inherit hostname assignedServices topology vm;
  inherit (topo) vlans getSubnet getIp getPrimaryIp getGateway getPort;

  hasService = serviceName:
    builtins.elem serviceName assignedServices;

  hasAnyService = serviceNames:
    builtins.any (serviceName: builtins.elem serviceName assignedServices) serviceNames;
}
