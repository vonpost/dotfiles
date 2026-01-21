{ lib }:
let
  base = "/aleph/state/services";
  libBase = "${base}/lib";
  cacheBase = "${base}/cache";

  uids = {
    prowlarr    = 2101;
    radarr      = 2102;
    sonarr      = 2103;
    jellyfin    = 2104;
    jellyseerr  = 2105;
    sabnzbd     = 2106;
    qbittorrent = 2107;
    wolf = 2108;
    llama-cpp = 2109;
    dailyLlmJournal = 2110;
    acme = 2111;
  };

  downloadsGID= 3000;
  hasDownloadsDir = [ "qbittorrent" "sabnzbd" ];

  # Services we *know* use StateDirectory -> /var/lib/private/<name>
  privateStateDir = {
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
    , user ? name
    , group ? user
    , uid ? uids.${name}
    , gid ? uid
    , source ? "${libBase}/${name}"       # host path
    , stateMount ? "/state/${name}"       # inside VM (virtiofs mountpoint)
    , bindTarget ? null                   # explicit override
    , stateDirName ? (privateStateDir.${name} or null)  # auto from map
    , virtioTag ? "svc-${name}"
    , persistCache ? false
    , cacheSource ? "${cacheBase}/${name}"       # host path
    , cacheMount ? "/cache/${name}"              # inside VM (virtiofs mountpoint)
    , cacheBindTarget ? null                     # explicit override
    , cacheDirName ? (privateCacheDir.${name} or null)  # auto from map
    , cacheVirtioTag ? "cache-${name}"
    , disableDynamicUser ? true
    , downloadsGroup ? false
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
      users.groups.${group}.gid = lib.mkForce gid;
      users.users.${user} = {
        uid = lib.mkForce uid;
        group = lib.mkForce group;
        isSystemUser = lib.mkForce true;
        extraGroups = lib.mkIf downloadsGroup ["downloads"] ;
      };

      users.groups.downloads = lib.mkIf downloadsGroup {
        gid = downloadsGID;
      };

      systemd.services.${unit} = {
        serviceConfig.DynamicUser = lib.mkForce false;
        serviceConfig.User = lib.mkForce user;
        serviceConfig.Group = lib.mkForce group;
        unitConfig.RequiresMountsFor =
          [ chosenBindTarget ]
          ++ lib.optional persistCache chosenCacheBindTarget;
      };

      microvm.shares =
        [
          {
            proto = "virtiofs";
            tag = virtioTag;
            source = "${base}";
            mountPoint = "/state";
          }
        ];
        # ++ lib.optional persistCache {
        # proto = "virtiofs";
        # tag = cacheVirtioTag;
        # source = cacheSource;
        # mountPoint = cacheMount;
        # }
        # ++ lib.optional downloadsGroup {
        # proto = "virtiofs";
        # tag = "downloadsDir-${name}";
        # source = "${base}/downloads/${name}";
        # mountPoint = "/downloads/${name}";
        # };

      fileSystems =
        {
          ${chosenBindTarget} = {
            device = "/state/lib/${name}";
            fsType = "none";
            options = [ "bind" ];
          };
        }
        // lib.optionalAttrs persistCache {
          ${chosenCacheBindTarget} = {
            device = "/state/cache/${name}";
            fsType = "none";
            options = [ "bind" ];
          };
        }
      // lib.optionalAttrs downloadsGroup {
        "/downloads" = {
            device = "/state/downloads";
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
    libBase
    cacheBase
    hasDownloadsDir
    downloadsGID
    privateStateDir
    privateCacheDir;
}
