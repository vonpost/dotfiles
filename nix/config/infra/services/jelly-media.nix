{ config, lib, pkgs, bleeding ? pkgs, ... }:
let
  svc = import ./lib.nix { inherit config; };
  topology = config.my.infra.topology;
  hostProvides = topology.vms.${svc.hostname}.provides or [ ];
  enableJellyfinService = svc.hasService "jellyfin" && builtins.elem "jellyfin" hostProvides;
  sshJellyfinProviders =
    builtins.filter
      (vmName: builtins.elem "sshJellyfin" topology.vms.${vmName}.provides)
      (builtins.attrNames topology.vms);
  rffmpegHosts =
    map
      (vmName: "${lib.toLower vmName}.${topology.domain}")
      (builtins.filter (vmName: vmName != svc.hostname) sshJellyfinProviders);
  useRffmpeg = pkgs ? rffmpeg && enableJellyfinService && rffmpegHosts != [ ];
  jellyfinPackage =
    if useRffmpeg
    then bleeding.jellyfin.override { jellyfin-ffmpeg = pkgs.rffmpeg; }
    else bleeding.jellyfin;
in
{
  config = lib.mkMerge [
    (lib.mkIf enableJellyfinService {
      services.jellyfin = {
        enable = true;
        package = jellyfinPackage;
      };

      services.rffmpeg = lib.mkIf useRffmpeg {
        enable = true;
        hosts = rffmpegHosts;
      };

      environment.systemPackages = [ pkgs.jellyfin-ffmpeg ];
    })

    (lib.mkIf (svc.hasService "jellyseerr") {
      services.jellyseerr.enable = true;
      users.users.jellyseerr.extraGroups = [ "media" ];
    })

    (lib.mkIf (svc.hasService "geoipupdate") {
      services.geoipupdate = {
        enable = true;
        settings = {
          AccountID = 1286842;
          EditionIDs = [ "GeoLite2-Country" ];
          LicenseKey = { _secret = "/run/credentials/geoipupdate.service/maxmind_license_key"; };
          DatabaseDirectory = "/var/lib/geoipupdate";
        };
      };
    })
  ];
}
