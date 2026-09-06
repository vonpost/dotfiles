{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf flatten mapAttrsToList optional;
  cfg = config.my.infra.hostServiceMounts;
  services = config.my.infra.services;
  vms = config.my.infra.vms;
  state = config.my.infra.state;
  statefulServices = lib.filterAttrs (_svcName: service: service.managedState) services;
  layout = import ../../service-state-layout.nix { inherit lib; infra = config.my.infra; };

  mkBindMount = unit: mp: dev: {
    what = dev;
    where = toString (builtins.toPath mp);
    type = "none";
    options = "bind";
    before = [ unit ];
    wantedBy = [ unit ];
    partOf = [ unit ];
    bindsTo = [ unit ];
  };

in
{
  options.my.infra.hostServiceMounts = {
    enable = mkEnableOption "host-side tmpfiles + bind mounts for microvm service state staging";
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = lib.unique (
      [
        "d ${state.paths.base} 0755 root root -"
        "d ${state.paths.base}/${state.paths.lib} 0755 root root -"
        "d ${state.paths.base}/${state.paths.cache} 0755 root root -"
        "d ${state.paths.mediaRoot} 0755 root ${toString state.gids.media} -"
        "d ${state.paths.downloadsRoot} 2770 root ${toString state.gids.downloads} -"
      ]
      ++ flatten (
        mapAttrsToList
          (_svcName: service:
            [
              "d ${state.paths.base}/${state.paths.lib}/${service.name} 0755 ${toString service.uid} ${toString service.gid} -"
            ]
            ++ optional
              service.hasCacheDir
              "d ${state.paths.base}/${state.paths.cache}/${service.name} 0755 ${toString service.uid} ${toString service.gid} -"
            ++ optional
              service.hasDownloadsDir
              "d ${state.paths.downloadsRoot}/${service.name} 2770 ${toString service.uid} ${toString state.gids.downloads} -"
            ++ optional
              service.hasMediaDir
              "d ${state.paths.mediaRoot}/${service.name} 2750 ${toString service.uid} ${toString state.gids.media} -"
          )
          statefulServices
      ));

    systemd.mounts =
      flatten (
        mapAttrsToList
          (vmName: _vmCfg:
            let
              unit = "microvm@${vmName}.service";
              vm = layout.forVm vmName;
            in
            map (mount: mkBindMount unit
              "${vm.stagePath}/${mount.relativePath}" mount.source) vm.mounts
          )
          vms
      );
  };
}
