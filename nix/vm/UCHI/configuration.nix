{ self, config, pkgs, lib, utils, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "UCHI";
in
{
  imports =
    [
      (import ../../common/vm-common.nix { hostname = hostname; })
      ../../common/recyclarr.nix
    ];

  services = {
    sonarr.enable = true;
    radarr.enable = true;
    recyclarr.enable =true;
    prowlarr = {
      enable = true;
      package = bleeding.prowlarr;
    };
  };

  microvm.vcpu = 2;
  microvm.mem = 4000;
  #microvm.hotplugMem = 8400;


}
