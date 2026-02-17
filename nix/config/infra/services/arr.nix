{ config, lib, pkgs, bleeding ? pkgs, ... }:
let
  svc = import ./lib.nix { inherit config; };
in
{
  config = lib.mkMerge [
    (lib.mkIf (svc.hasService "sonarr") {
      services.sonarr.enable = true;
    })

    (lib.mkIf (svc.hasService "radarr") {
      services.radarr.enable = true;
    })

    (lib.mkIf (svc.hasService "prowlarr") {
      services.prowlarr = {
        enable = true;
        package = bleeding.prowlarr;
      };
    })
  ];
}
