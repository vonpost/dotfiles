{ config, lib }:
let
  hostname = config.networking.hostName;
  hostConfig = config.my.infra.vmServiceMounts.${hostname} or { serviceMounts = [ ]; };
  assignedServices = hostConfig.serviceMounts;
  topology = config.my.infra.topology;
  topo = import ../../../lib/infra-topology.nix { inherit topology; };
  vm = topology.vms.${hostname};
in
{
  inherit hostname assignedServices topology vm;
  inherit (topo) vlans getSubnet getIp getGateway;

  hasService = serviceName:
    builtins.elem serviceName assignedServices;

  hasAnyService = serviceNames:
    builtins.any (serviceName: builtins.elem serviceName assignedServices) serviceNames;
}
