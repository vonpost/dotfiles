{ config, lib, pkgs, bleeding ? pkgs, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  topology = config.my.infra.topology;
  enableJellyfinService = svc.hasService "jellyfin";
  transcodeWorkers =
    builtins.filter
      (vmName: builtins.elem "transcode-worker" config.my.infra.vms.${vmName}.services)
      (builtins.attrNames config.my.infra.vms);
  okuriHosts =
    map
      (vmName: "${lib.toLower vmName}.${topology.domain}")
      (builtins.filter (vmName: vmName != svc.hostname) transcodeWorkers);
  useOkuri = pkgs ? okuri && enableJellyfinService && okuriHosts != [ ];
  jellyfinPackage =
    if useOkuri
    then bleeding.jellyfin.override { jellyfin-ffmpeg = pkgs.okuri; }
    else bleeding.jellyfin;
in
{
  config = lib.mkMerge [
    (lib.mkIf enableJellyfinService {
      assertions = [{
        # okuri dispatches to a single target; priority ordering across
        # several GPU nodes is not implemented (and not needed here).
        assertion = builtins.length okuriHosts <= 1;
        message = "okuri supports at most one transcode worker, got: ${toString okuriHosts}";
      }];

      services.jellyfin = {
        enable = true;
        package = jellyfinPackage;
      };

      services.okuri = lib.mkIf useOkuri {
        enable = true;
        targetHost = lib.head okuriHosts;
      };

      environment.systemPackages = [ pkgs.jellyfin-ffmpeg ];
    })

    (lib.mkIf (svc.hasService "seerr") {
      services.seerr.enable = true;
      users.users.seerr.extraGroups = [ "media" ];
    })
  ];
}
