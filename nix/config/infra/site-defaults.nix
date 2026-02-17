{ ... }:
{
  config.my.infra = {
    services = import ./service-map.nix;
    vmServiceMounts = import ./vm-config.nix;
    topology = import ./topology.nix;
  };
}
