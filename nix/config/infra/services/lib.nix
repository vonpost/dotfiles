{ config }:
let
  hostname = config.networking.hostName;
  hostConfig = config.my.infra.vmServiceMounts.${hostname} or { serviceMounts = [ ]; };
  assignedServices = hostConfig.serviceMounts;
in
{
  inherit hostname assignedServices;

  hasService = serviceName:
    builtins.elem serviceName assignedServices;

  hasAnyService = serviceNames:
    builtins.any (serviceName: builtins.elem serviceName assignedServices) serviceNames;
}
