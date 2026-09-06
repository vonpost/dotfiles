{ lib, config, ... }:
let
  cfg = config.my.infra.guestServiceState;
  infra = config.my.infra;
  state = infra.state;
  layout = import ../../service-state-layout.nix { inherit lib infra; };
  vm = layout.forVm config.networking.hostName;

  mkFileSystem = mount: lib.nameValuePair mount.mountPoint {
    device = mount.guestSource;
    fsType = "none";
    options = [ "bind" ];
  };

  mkService = service: {
    users.groups.${service.group}.gid = lib.mkForce service.gid;
    users.users.${service.user} = {
      uid = lib.mkForce service.uid;
      group = lib.mkForce service.group;
      isSystemUser = lib.mkDefault true;
      extraGroups = lib.optional service.downloadsGroup "downloads"
        ++ lib.optional service.mediaGroup "media";
    };

    users.groups.downloads = lib.mkIf service.downloadsGroup {
      gid = state.gids.downloads;
    };
    users.groups.media = lib.mkIf service.mediaGroup {
      gid = state.gids.media;
    };

    systemd.services = lib.optionalAttrs (service.unit != null) {
      ${service.unit} = {
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = lib.mkForce service.user;
          Group = lib.mkForce service.group;
          # Supplementary gids may be unmapped by upstream PrivateUsers. Preserve
          # setgid directory ownership and the media umask instead of chowning.
          UMask = lib.mkIf service.mediaGroup (lib.mkForce "0027");
        };
        unitConfig.RequiresMountsFor = map (mount: mount.mountPoint)
          (layout.serviceMounts service);
      };
    };

    # Preserve the existing merge behavior for resources used by several
    # services, while sharing the path specification with host provisioning.
    fileSystems = builtins.listToAttrs (map mkFileSystem (
      layout.serviceMounts service
      ++ lib.optional service.downloadsGroup (layout.sharedMount "downloads")
      ++ lib.optional service.mediaGroup (layout.sharedMount "media")
    ));
  };
  serviceConfigs = map mkService vm.services;
in
{
  options.my.infra.guestServiceState.enable = lib.mkEnableOption
    "guest users and bind mounts for the shared service state tree";

  config = lib.mkIf cfg.enable {
    users.users = lib.mkMerge (map (service: service.users.users) serviceConfigs);
    users.groups = lib.mkMerge (map (service: service.users.groups) serviceConfigs);
    systemd.services = lib.mkMerge (map (service: service.systemd.services) serviceConfigs);
    fileSystems = lib.mkMerge (map (service: service.fileSystems) serviceConfigs);
    # One state share per VM is intentional: many concurrent VirtioFS
    # shares previously caused failures on MOTHER. Keep host staging and
    # guest bind mounts; do not replace them with per-service shares.
    microvm.shares = lib.mkAfter (lib.optional (vm.services != [ ]) {
      proto = "virtiofs";
      tag = "state";
      source = vm.stagePath;
      mountPoint = "/state";
    });
  };
}
