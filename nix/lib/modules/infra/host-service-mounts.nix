{ lib, config, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf flatten mapAttrsToList optional;
  cfg = config.my.infra.hostServiceMounts;
  services = config.my.infra.services;
  vms = config.my.infra.vms;
  state = config.my.infra.state;
  statefulServices = lib.filterAttrs (_svcName: service: service.managedState) services;
  layout = import ../../service-state-layout.nix { inherit lib; infra = config.my.infra; };
  excludedCaches = lib.unique (lib.concatMap (service:
    map (directory: {
      path = layout.cacheDirectory service directory;
      inherit (service) uid gid;
    }) service.backupExcludedCacheDirectories
  ) (builtins.attrValues statefulServices));
  excludedCachePaths = map (cache: cache.path) excludedCaches;
  checkMigration = path: ''
    for leftover in ${lib.escapeShellArgs [ "${path}.before-subvolume" "${path}.new-subvolume" ]}; do
      if [ -e "$leftover" ] || [ -L "$leftover" ]; then
        echo "Backup refused: unfinished cache migration at $leftover" >&2
        exit 1
      fi
    done
  '';
  needsCacheSubvolumes = vm: builtins.any (service:
    builtins.any (path: lib.hasPrefix "${layout.cacheDirectory service ""}" path)
      excludedCachePaths
  ) vm.services;

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
    # Check the actual boundary before every backup. An ordinary directory
    # restored in place of the cache must not silently become backup data.
    system.build.checkServiceCacheSubvolumes = pkgs.writeShellScript "check-service-cache-subvolumes" ''
      set -eu
      ${lib.concatMapStringsSep "\n" (path: ''
        ${checkMigration path}
        if [ -L ${lib.escapeShellArg path} ] || ! ${pkgs.btrfs-progs}/bin/btrfs subvolume show ${lib.escapeShellArg path} >/dev/null; then
          echo ${lib.escapeShellArg "Backup refused: ${path} must be a nested Btrfs subvolume; migrate the existing cache with its users stopped."} >&2
          exit 1
        fi
      '') excludedCachePaths}
    '';

    # tmpfiles "v" falls back to an ordinary directory when / is not itself
    # a Btrfs subvolume (MOTHER has an ext4 root). Create these explicitly.
    # Populated ordinary directories are never converted while VMs run.
    system.build.prepareServiceCacheSubvolumes = pkgs.writeShellScript "prepare-service-cache-subvolumes" ''
      set -eu
      ${lib.concatMapStringsSep "\n" checkMigration excludedCachePaths}
      ${lib.concatMapStringsSep "\n" (path: ''
        if [ ! -e ${lib.escapeShellArg path} ] && [ ! -L ${lib.escapeShellArg path} ]; then
          ${pkgs.btrfs-progs}/bin/btrfs subvolume create ${lib.escapeShellArg path}
        fi
      '') excludedCachePaths}
      ${config.system.build.checkServiceCacheSubvolumes}
      ${lib.concatMapStringsSep "\n" (cache: ''
        ${pkgs.coreutils}/bin/chown ${toString cache.uid}:${toString cache.gid} ${lib.escapeShellArg cache.path}
        ${pkgs.coreutils}/bin/chmod 0755 ${lib.escapeShellArg cache.path}
      '') excludedCaches}
    '';

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
            ++ map (directory:
              let
                path = layout.cacheDirectory service directory;
                type = if builtins.elem path excludedCachePaths then "z" else "d";
              in "${type} ${path} 0755 ${toString service.uid} ${toString service.gid} -"
            ) (lib.unique (service.uncachedCacheDirectories ++ service.backupExcludedCacheDirectories))
            ++ optional
              service.hasDownloadsDir
              "d ${state.paths.downloadsRoot}/${service.name} 2770 ${toString service.uid} ${toString state.gids.downloads} -"
            ++ optional
              service.hasMediaDir
              "d ${state.paths.mediaRoot}/${service.name} 2750 ${toString service.uid} ${toString state.gids.media} -"
          )
          statefulServices
      ));

    # Direct cache exports must exist on the backing filesystem before the
    # guest runner starts its daemons. This is independent of the state bind
    # mounts, which continue to be owned by microvm@<name> as before.
    systemd.services = lib.mapAttrs' (name: vm:
      lib.nameValuePair "microvm-virtiofsd@${name}" {
        after = [ "systemd-tmpfiles-setup.service" ]
          ++ optional (needsCacheSubvolumes vm) "service-cache-subvolumes.service";
        requires = optional (needsCacheSubvolumes vm) "service-cache-subvolumes.service";
        unitConfig.RequiresMountsFor = map (share: share.source) vm.cacheShares;
      }
    ) (lib.filterAttrs (_: vm: vm.cacheShares != [ ] || needsCacheSubvolumes vm)
      (lib.mapAttrs (name: _: layout.forVm name) vms)) // {
        service-cache-subvolumes = mkIf (excludedCaches != [ ]) {
          description = "Prepare cache subvolumes excluded from state backups";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          unitConfig.RequiresMountsFor = excludedCachePaths;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${config.system.build.prepareServiceCacheSubvolumes}";
          };
        };
      };

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
