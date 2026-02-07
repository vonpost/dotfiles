{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "UCHI";
in
{
  imports =
    [
      (import ../../common/vm-common.nix { hostname = hostname; })
      ../../common/recyclarr.nix
    ];

  microvm.shares = [
    {
      proto = "virtiofs";
      tag = "sabnzbdSecret";
      source = "/run/secrets/arrApiKeys";
      mountPoint = "/run/arrApiKeys";
    }
  ];
  services = {
    sonarr.enable = true;
    radarr.enable = true;
    recyclarr = {
      enable = true;
      configuration = {
        radarr.radarrMain.api_key._secret="/run/arrApiKeys/radarr";
        sonarr.sonarrMain.api_key._secret="/run/arrApiKeys/sonarr";
      };
    };
    prowlarr = {
      enable = true;
      package = bleeding.prowlarr;
    };
  };
  microvm.vcpu = 2;
  microvm.mem = 4000;
  #microvm.hotplugMem = 8400;


}
