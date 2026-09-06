{ lib, ... }:
{
  config.my.infra = {
    services = import ./service-map.nix;
    vms = lib.listToAttrs (map (vm: lib.nameValuePair vm.name
      (builtins.removeAttrs vm [ "name" "modules" ])) (import ./inventory.nix));
    topology = import ./topology.nix;
    observability = {
      lokiVM = "NIKKI";
      logProfiles = import ./log-profiles.nix;
    };
  };
}
