{ lib }:

let
  base = "/aleph/state/services";
  cacheBase = "${base}/cache";

  uids = {
    prowlarr    = 2101;
    radarr      = 2102;
    sonarr      = 2103;
    jellyfin    = 2104;
    jellyseerr  = 2105;
    sabnzbd     = 2106;
    qbittorrent = 2107;
  };

  # Services we *know* use StateDirectory -> /var/lib/private/<name>
  privateStateDir = {
    prowlarr = "prowlarr";
  };

  # Services we *know* use CacheDirectory -> /var/cache/private/<name>
  privateCacheDir = { };

  defaultBindTarget = name: "/var/lib/${name}";
  privateBindTarget = sd: "/var/lib/private/${sd}";

  defaultCacheBindTarget = name: "/var/cache/${name}";
  privateCacheBindTarget = sd: "/var/cache/private/${sd}";

  mkOne =
    { name
    , unit ? name
    , uid ? uids.${name}
    , source ? "${base}/${name}"          # host path
    , stateMount ? "/state/${name}"       # inside VM (virtiofs mountpoint)
    , bindTarget ? null                   # explicit override
    , stateDirName ? (privateStateDir.${name} or null)  # auto from map
    , virtioTag ? "svc-${name}"
    , persistCache ? true
    , cacheSource ? "${cacheBase}/${name}"       # host path
    , cacheMount ? "/cache/${name}"              # inside VM (virtiofs mountpoint)
    , cacheBindTarget ? null                     # explicit override
    , cacheDirName ? (privateCacheDir.${name} or null)  # auto from map
    , cacheVirtioTag ? "cache-${name}"
    , disableDynamicUser ? true
    }:
    { ... }:
    let
      chosenBindTarget =
        if bindTarget != null then bindTarget
        else if stateDirName != null then privateBindTarget stateDirName
        else defaultBindTarget name;

      chosenCacheBindTarget =
        if cacheBindTarget != null then cacheBindTarget
        else if cacheDirName != null then privateCacheBindTarget cacheDirName
        else defaultCacheBindTarget name;
    in
    {
      users.groups.${name}.gid = lib.mkForce uid;
      users.users.${name} = {
        uid = lib.mkForce uid;
        group = lib.mkForce name;
        isSystemUser = lib.mkForce true;
      };

      systemd.services.${unit} = {
        serviceConfig.DynamicUser = lib.mkForce false;
        serviceConfig.User = lib.mkForce name;
        serviceConfig.Group = lib.mkForce name;
        unitConfig.RequiresMountsFor =
          [ chosenBindTarget ]
          ++ lib.optional persistCache chosenCacheBindTarget;
      };

      microvm.shares =
        [
          {
            proto = "virtiofs";
            tag = virtioTag;
            source = source;
            mountPoint = stateMount;
          }
        ]
        ++ lib.optional persistCache {
          proto = "virtiofs";
          tag = cacheVirtioTag;
          source = cacheSource;
          mountPoint = cacheMount;
        };

      fileSystems =
        {
          ${chosenBindTarget} = {
            device = stateMount;
            fsType = "none";
            options = [ "bind" ];
          };
        }
        // lib.optionalAttrs persistCache {
          ${chosenCacheBindTarget} = {
            device = cacheMount;
            fsType = "none";
            options = [ "bind" ];
          };
        };
    };

  mkMany = names: map (n: mkOne { name = n; }) names;

in {
  inherit
    mkOne
    mkMany
    uids
    base
    cacheBase
    privateStateDir
    privateCacheDir;
}
