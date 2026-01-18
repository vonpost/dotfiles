{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "UCHI";
in
{
  imports =
    (map (name: svc.mkOne { name = name; downloadsGroup = true; } ) [ "sonarr" "radarr"]) ++
    svc.mkMany [ "prowlarr" ] ++
    [
      (import ../../common/vm-common.nix { hostname = hostname; media = true; })
    ];

  services = {
    sonarr.enable = true;
    radarr.enable = true;
    prowlarr = {
      enable = true;
      package = bleeding.prowlarr;
    };
  };
  microvm.vcpu = 2;
  microvm.mem = 4000;
  #microvm.hotplugMem = 8400;


}
