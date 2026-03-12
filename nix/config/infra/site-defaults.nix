{ ... }:
{
  config.my.infra = {
    services = import ./service-map.nix;
    vmServiceMounts = import ./vm-config.nix;
    topology = import ./topology.nix;
    observability = {
      lokiVM = "NIKKI";
      logProfiles = import ./log-profiles.nix;
    };
  };
}
