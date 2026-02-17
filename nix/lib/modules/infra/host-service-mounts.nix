{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types flatten mapAttrsToList optional;
  cfg = config.my.infra.hostServiceMounts;
  services = config.my.infra.services;
  vmServiceMounts = config.my.infra.vmServiceMounts;
  state = config.my.infra.state;

  statefulServices = lib.filterAttrs (_svcName: service: service.managedState) services;

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
    stageRoot = mkOption {
      type = types.str;
      default = "/run/microvm-staging";
      description = "Base staging path where per-VM bind mount trees are created.";
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules =
      [
        "d ${state.paths.base} 0755 root root -"
        "d ${state.paths.base}/${state.paths.lib} 0755 root root -"
        "d ${state.paths.base}/${state.paths.cache} 0755 root root -"
        "d ${state.paths.mediaRoot} 0755 root ${toString state.gids.media} -"
        "d ${state.paths.downloadsRoot} 2770 root ${toString state.gids.downloads} -"
      ]
      ++ flatten (
        mapAttrsToList
          (svcName: service:
            [
              "d ${state.paths.base}/${state.paths.lib}/${svcName} 0755 ${toString service.uid} ${toString service.uid} -"
            ]
            ++ optional
              service.hasCacheDir
              "d ${state.paths.base}/${state.paths.cache}/${service.name} 0755 ${toString service.uid} ${toString service.uid} -"
            ++ optional
              service.hasDownloadsDir
              "d ${state.paths.downloadsRoot}/${service.name} 2770 ${toString service.uid} ${toString state.gids.downloads} -"
            ++ optional
              service.hasMediaDir
              "d ${state.paths.mediaRoot}/${service.name} 2750 ${toString service.uid} ${toString state.gids.media} -"
          )
          statefulServices
      );

    systemd.mounts =
      flatten (
        mapAttrsToList
          (vmName: vmCfg:
            let
              unit = "microvm@${vmName}.service";
              vmStateServices =
                builtins.filter
                  (service: service.managedState)
                  (map (serviceName: services.${serviceName}) vmCfg.serviceMounts);

              perServiceMounts =
                flatten (
                  map
                    (service:
                      map
                        (pth:
                          let
                            mp = "${cfg.stageRoot}/${vmName}/${pth}";
                            dev = "${state.paths.base}/${pth}";
                          in
                          mkBindMount unit mp dev
                        )
                        (
                          [ "${state.paths.lib}/${service.name}" ]
                          ++ lib.optional service.hasCacheDir "${state.paths.cache}/${service.name}"
                        )
                    )
                    vmStateServices
                );

              sharedMounts =
                map
                  (pth:
                    let
                      pPath = "${pth}";
                      pRoot = "${pth}Root";
                      mp = "${cfg.stageRoot}/${vmName}/${state.paths.${pPath}}";
                      dev = state.paths.${pRoot};
                    in
                    mkBindMount unit mp dev
                  )
                  (
                    builtins.filter
                      (p: builtins.any (service: service."${p}Group") vmStateServices)
                      [ "downloads" "media" ]
                  );
            in
            perServiceMounts ++ sharedMounts
          )
          vmServiceMounts
      );
  };
}
