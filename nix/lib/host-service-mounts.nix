
{ lib, utils, ... }:
with lib;
let
  vmConfig = import ./vm-config.nix;
  svc = import ./vm-service-state.nix {inherit lib;};
  svcMap = import ./service-map.nix;
  stageRoot = "/run/microvm-staging";
in
{
  systemd.tmpfiles.rules =
    [
    "d ${svc.base} 0755 root root -"
    "d ${svc.base}/${svc.libPath} 0755 root root -"
    "d ${svc.base}/${svc.cachePath} 0755 root root -"
    "d ${svc.mediaRoot} 0755 root ${toString svc.mediaGID} -"
    "d ${svc.downloadsRoot} 2770 root ${toString svc.downloadsGID} -"
    # "d ${stageRoot} 0755 root root -"
    ]
    ++ flatten (mapAttrsToList (svcName: service:
      [
        "d ${svc.base}/${svc.libPath}/${svcName} 0755 ${toString service.uid} ${toString service.uid} -"
      ]
      ++ optional (service.hasCacheDir or false) "d ${svc.base}/${svc.cachePath}/${service.name} 0755 ${toString service.uid} ${toString service.uid} -"
      ++ optional (service.hasDownloadsDir or false) "d ${svc.downloadsRoot}/${service.name} 2770 ${toString service.uid} ${toString svc.downloadsGID} -"
      ++ optional (service.hasMediaDir or false) "d ${svc.mediaRoot}/${service.name} 2750 ${toString service.uid} ${toString svc.mediaGID} -"
    ) svcMap);
    systemd.mounts =
      flatten (mapAttrsToList (vm: vmCfg:
        let
          unit = "microvm@${vm}.service";

          mkBindMount = mp: dev: {
            what = dev;
            where = toString (builtins.toPath mp);
            type = "none";
            options = "bind";
            before = [ unit ];
            wantedBy = [ unit ];

            # The crucial lifecycle coupling:
            partOf = [ unit ];
            bindsTo = [ unit ];
          };

          perServiceMounts =
            flatten (map (service:
              map (pth:
                let
                  mp  = "${stageRoot}/${vm}/${pth}";
                  dev = "${svc.base}/${pth}";
                in mkBindMount mp dev
              ) (
                [ "${svc.libPath}/${service.name}" ]
                ++ (lib.optional (service.hasCacheDir or false) "${svc.cachePath}/${service.name}")
              )
            ) (map (sn: svcMap.${sn}) vmCfg.serviceMounts));

          sharedMounts =
            map (pth:
              let
                pPath = "${pth}Path";
                pRoot = "${pth}Root";
                mp = "${stageRoot}/${vm}/${svc.${pPath}}";
                dev = "${svc.${pRoot}}";
              in mkBindMount mp dev
            ) (builtins.filter
                (p: builtins.any (sm: (svcMap.${sm}."${p}Group" or false)) vmCfg.serviceMounts)
                [ "downloads" "media" ]);

        in perServiceMounts ++ sharedMounts
      ) vmConfig);
}
