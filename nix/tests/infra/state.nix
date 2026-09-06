# Evaluate real host/guest modules. These checks exercise the contract across
# the VM boundary, including overrides that the old raw-file imports ignored.
{ lib, nixosConfigurations }:
let
  host = nixosConfigurations.MOTHER.config;
  guestNames = builtins.attrNames (builtins.removeAttrs nixosConfigurations [ "MOTHER" ]);
  stateShares = config: builtins.filter (share: share.tag == "state") config.microvm.shares;
  stagingMounts = config: builtins.filter
    (mount: lib.hasPrefix "${config.my.infra.state.stageRoot}/" mount.where)
    config.systemd.mounts;

  overrides = { lib, ... }: {
    my.infra = {
      state = {
        stageRoot = "/run/infra-test";
        paths = {
          base = "/persist/services";
          lib = "library";
          cache = "caches";
          media = "collection";
          downloads = "incoming";
          mediaRoot = "/shared/media";
          downloadsRoot = "/shared/downloads";
        };
        gids = { downloads = 4300; media = 4301; };
      };
      services.sonarr = {
        name = lib.mkForce "series";
        bindTarget = "series-app";
        uid = lib.mkForce 4203;
        gid = 4204;
        hasCacheDir = true;
      };
      vms.UCHI.services = lib.mkForce [ "sonarr" ];
    };
  };
  changedHost = (nixosConfigurations.MOTHER.extendModules { modules = [ overrides ]; }).config;
  changedGuest = (nixosConfigurations.UCHI.extendModules { modules = [ overrides ]; }).config;
  changedMounts = builtins.filter
    (mount: lib.hasPrefix "/run/infra-test/UCHI/" mount.where)
    changedHost.systemd.mounts;
  hostMountSources = builtins.listToAttrs
    (map (mount: lib.nameValuePair mount.where mount.what) changedMounts);

  noStateGuest = (nixosConfigurations.UCHI.extendModules {
    modules = [{ my.infra.services = {
      sonarr.managedState = false;
      radarr.managedState = false;
      prowlarr.managedState = false;
    }; }];
  }).config;

  aliasGuest = (nixosConfigurations.UCHI.extendModules {
    modules = [{ my.infra.hostServiceMounts.stageRoot = "/run/legacy-test"; }];
  }).config;
  aliasHost = (nixosConfigurations.MOTHER.extendModules {
    modules = [{ my.infra.hostServiceMounts.stageRoot = "/run/legacy-test"; }];
  }).config;

  movedSab = (nixosConfigurations.UCHI.extendModules {
    modules = [{ my.infra.vms.UCHI.services = lib.mkForce [ "sabnzbd" ]; }];
  }).config;
  removedSab = (nixosConfigurations.KAIZOKU.extendModules {
    modules = [{ my.infra.vms.KAIZOKU.services = lib.mkForce [ "qbittorrent" ]; }];
  }).config;

  checks = {
    oneStateShare = builtins.all (name:
      let
        c = nixosConfigurations.${name}.config;
        stateful = builtins.any (service: c.my.infra.services.${service}.managedState)
          c.my.infra.vms.${name}.services;
        shares = stateShares c;
      in builtins.length shares == (if stateful then 1 else 0)
        && map (share: share.tag) c.microvm.shares ==
          [ "ro-store" ] ++ lib.optional stateful "state"
        && builtins.all (share: share.proto == "virtiofs"
          && share.mountPoint == "/state"
          && share.source == "/run/microvm-staging/${name}") shares
    ) guestNames;

    guestBindsHaveHostMounts = builtins.all (name:
      let c = nixosConfigurations.${name}.config;
      in builtins.all (fs:
        !(lib.hasPrefix "/state/" fs.device) || builtins.any
          (mount: mount.where == "/run/microvm-staging/${name}/${lib.removePrefix "/state/" fs.device}")
          (stagingMounts host)
      ) (builtins.attrValues c.fileSystems)
    ) guestNames;

    overrideHostSources = hostMountSources == {
      "/run/infra-test/UCHI/library/series" = "/persist/services/library/series";
      "/run/infra-test/UCHI/caches/series" = "/persist/services/caches/series";
      "/run/infra-test/UCHI/incoming" = "/shared/downloads";
      "/run/infra-test/UCHI/collection" = "/shared/media";
    };
    overrideGuestSources =
      changedGuest.fileSystems."/var/lib/series-app".device == "/state/library/series"
      && changedGuest.fileSystems."/var/cache/series-app".device == "/state/caches/series"
      && changedGuest.fileSystems."/data/downloads".device == "/state/incoming"
      && changedGuest.fileSystems."/data/media".device == "/state/collection"
      && !(changedGuest.fileSystems ? "/var/lib/radarr")
      && (builtins.head (stateShares changedGuest)).source == "/run/infra-test/UCHI";
    overrideIdentity = changedGuest.users.users.series.uid == 4203
      && changedGuest.users.groups.series.gid == 4204
      && changedGuest.users.groups.downloads.gid == 4300
      && changedGuest.users.groups.media.gid == 4301
      && changedGuest.systemd.services.series.serviceConfig.User == "series"
      && changedGuest.systemd.services.series.unitConfig.RequiresMountsFor == [
        "/var/lib/series-app" "/var/cache/series-app"
      ];
    overrideHostOwnership = builtins.elem
      "d /persist/services/library/series 0755 4203 4204 -" changedHost.systemd.tmpfiles.rules
      && builtins.elem "d /persist/services/caches/series 0755 4203 4204 -"
        changedHost.systemd.tmpfiles.rules;
    statelessHasNoShare = stateShares noStateGuest == [ ]
      && !(noStateGuest.fileSystems ? "/var/lib/sonarr");
    legacyStageRootAlias = (builtins.head (stateShares aliasGuest)).source == "/run/legacy-test/UCHI"
      && builtins.any (mount: mount.where == "/run/legacy-test/UCHI/lib/sonarr")
        aliasHost.systemd.mounts;
    sabAssignmentUsesModuleConfig = movedSab.services.sabnzbd.enable
      && movedSab.services.sabnzbd.settings.misc.port == 1337
      && !(removedSab.services.sabnzbd.enable)
      && removedSab.services.sabnzbd.secretFiles == [ ];
  };
in
assert lib.assertMsg (builtins.all (value: value) (builtins.attrValues checks))
  "Infrastructure state contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks))}";
checks
