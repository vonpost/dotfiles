# Exercise the actual host/guest modules, including service and path overrides.
{ lib, nixosConfigurations }:
let
  host = nixosConfigurations.MOTHER.config;
  server = nixosConfigurations.SOTO.config;
  worker = nixosConfigurations.OKAMI.config;
  guests = builtins.removeAttrs nixosConfigurations [ "MOTHER" ];
  shares = c: builtins.filter (s: s.cache == "never") c.microvm.shares;
  source = "/state/services/./cache/jellyfin/transcodes";
  target = "/var/cache/jellyfin/transcodes";
  hasMountDependency = c: vm: path:
    builtins.elem path c.systemd.services."microvm-virtiofsd@${vm}".unitConfig.RequiresMountsFor
    && builtins.elem "systemd-tmpfiles-setup.service"
      c.systemd.services."microvm-virtiofsd@${vm}".after;

  overrides = { lib, ... }: {
    my.infra.state.paths = { base = "/persist/services"; cache = "scratch"; };
    my.infra.services = lib.genAttrs [ "jellyfin" "transcode-worker" ] (_: {
      name = lib.mkForce "cinema";
      bindTarget = lib.mkForce "cinema-app";
      uid = lib.mkForce 4210;
      gid = 4211;
      uncachedCacheDirectories = lib.mkForce [ "chunks" ];
    });
  };
  changedHost = (nixosConfigurations.MOTHER.extendModules { modules = [ overrides ]; }).config;
  changedServer = (nixosConfigurations.SOTO.extendModules { modules = [ overrides ]; }).config;
  changedWorker = (nixosConfigurations.OKAMI.extendModules { modules = [ overrides ]; }).config;
  changedSource = "/persist/services/scratch/cinema/chunks";
  changedTarget = "/var/cache/cinema-app/chunks";

  moved = { lib, ... }: {
    my.infra.vms.UCHI.services = lib.mkForce [ "jellyfin" ];
    my.infra.vms.SOTO.services = lib.mkForce [ "seerr" ];
  };
  movedHost = (nixosConfigurations.MOTHER.extendModules { modules = [ moved ]; }).config;
  movedServer = (nixosConfigurations.UCHI.extendModules { modules = [ moved ]; }).config;
  oldServer = (nixosConfigurations.SOTO.extendModules { modules = [ moved ]; }).config;

  invalid = (nixosConfigurations.SOTO.extendModules {
    modules = [{ my.infra.services.jellyfin.hasCacheDir = lib.mkForce false; }];
  }).config;

  checks = {
    onlyTwoExtraShares = builtins.all (name:
      builtins.length (shares guests.${name}.config) ==
        (if builtins.elem name [ "SOTO" "OKAMI" ] then 1 else 0)
    ) (builtins.attrNames guests);
    sameBackingDirectory = builtins.all (c:
      let s = builtins.head (shares c);
      in s.source == source && s.mountPoint == target
        && s.tag == "jellyfin-transcodes" && s.proto == "virtiofs"
    ) [ server worker ];
    cachedStatePreserved = builtins.all (c:
      builtins.all (s: s.cache == "auto")
        (builtins.filter (s: builtins.elem s.tag [ "state" "ro-store" ]) c.microvm.shares)
      && c.fileSystems."/var/lib/jellyfin".device == "/state/lib/jellyfin"
      && c.fileSystems."/var/cache/jellyfin".device == "/state/cache/jellyfin"
    ) [ server worker ];
    mountsFollowParentBinds = builtins.all (c:
      c.fileSystems.${target}.fsType == "virtiofs"
      && c.fileSystems.${target}.device == "jellyfin-transcodes"
      && builtins.elem "/var/cache/jellyfin" c.fileSystems.${target}.depends
      && !(builtins.elem "nofail" c.fileSystems.${target}.options)
    ) [ server worker ];
    jellyfinRequiresTranscodeMount = builtins.elem target
      server.systemd.services.jellyfin.unitConfig.RequiresMountsFor;
    hostPreparesExports = builtins.all (name: hasMountDependency host name source) [ "SOTO" "OKAMI" ]
      && builtins.filter (rule: rule == "d ${source} 0755 2104 2104 -") host.systemd.tmpfiles.rules
        == [ "d ${source} 0755 2104 2104 -" ];
    overridesReachBothGuests = builtins.all (c:
      let s = builtins.head (shares c);
      in s.source == changedSource && s.mountPoint == changedTarget
        && s.tag == "cinema-chunks" && s.cache == "never"
        && c.fileSystems.${changedTarget}.depends == [ "/var/cache/cinema-app" ]
    ) [ changedServer changedWorker ];
    overridesReachHost = builtins.all (name: hasMountDependency changedHost name changedSource)
      [ "SOTO" "OKAMI" ]
      && builtins.elem "d ${changedSource} 0755 4210 4211 -" changedHost.systemd.tmpfiles.rules;
    sharesFollowServiceAssignment = shares oldServer == [ ]
      && builtins.length (shares movedServer) == 1
      && (builtins.head (shares movedServer)).source == source
      && hasMountDependency movedHost "UCHI" source
      && !(movedHost.systemd.services."microvm-virtiofsd@SOTO".unitConfig ? RequiresMountsFor);
    rejectsMissingParentCache = builtins.any (a:
      a.message == "Uncached cache directories require managedState and hasCacheDir."
      && !a.assertion
    ) invalid.assertions;
  };
in
assert lib.assertMsg (builtins.all (x: x) (builtins.attrValues checks))
  "Cache share contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: x: !x) checks))}";
checks
