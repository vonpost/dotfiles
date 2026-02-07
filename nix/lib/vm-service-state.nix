{ lib }:
let
  base = "/aleph/state/services";
  mediaRoot = "/omega/media";
  downloadsRoot = "/aleph/state/services/downloads";
  libPath = "./lib";
  cachePath = "./cache";
  downloadsPath = "./downloads";
  mediaPath = "./media";
  # uids = {
  #   prowlarr    = 2101;
  #   radarr      = 2102;
  #   sonarr      = 2103;
  #   jellyfin    = 2104;
  #   jellyseerr  = 2105;
  #   sabnzbd     = 2106;
  #   qbittorrent = 2107;
  #   wolf = 2108;
  #   llama-cpp = 2109;
  #   dailyLlmJournal = 2110;
  #   acme = 2111;
  #   geoipupdate = 2112;
  # };

  downloadsGID= 3000;
  mediaGID= 3001;
  mkOne =
    { name
    , unit ? name
    , user ? name
    , group ? user
    , uid ? uid
    , gid ? uid
    , bindTarget ? name                   # explicit override
    , disableDynamicUser ? true
    , downloadsGroup ? false
    , mediaGroup ? false
    , hasCacheDir ? false
    , hasDownloadsDir ? false
    , hasMediaDir ? false
    }:
    { ... }:
    {
      users.groups.${group}.gid = lib.mkForce gid;
      users.users.${user} = {
        uid = lib.mkForce uid;
        group = lib.mkForce group;
        isSystemUser = lib.mkForce true;
        extraGroups = (lib.optional downloadsGroup "downloads") ++ (lib.optional mediaGroup "media") ;
      };

      users.groups.downloads = lib.mkIf downloadsGroup {
        gid = downloadsGID;
      };

      users.groups.media = lib.mkIf mediaGroup {
        gid = mediaGID;
      };

      systemd.services.${unit} = {
        serviceConfig.DynamicUser = lib.mkForce false;
        serviceConfig.User = lib.mkForce user;
        serviceConfig.Group = lib.mkForce group;
        unitConfig.RequiresMountsFor =
          [ "/var/lib/${bindTarget}" ]
          ++ lib.optional hasCacheDir "/var/cache/${bindTarget}";
      };

      fileSystems =
        {
          "/var/lib/${bindTarget}" = {
            device = "/state/${libPath}/${name}";
            fsType = "none";
            options = [ "bind" ];
          };
        }
        // lib.optionalAttrs hasCacheDir {
          "/var/cache/${bindTarget}" = {
            device = "/state/${cachePath}/${name}";
            fsType = "none";
            options = [ "bind" ];
          };
        }

        // lib.optionalAttrs downloadsGroup {
          "/downloads" = {
            device = "/state/${downloadsPath}";
            fsType = "none";
            options = [ "bind" ];
          };
        }

        // lib.optionalAttrs mediaGroup {
          "/media" = {
            device = "/state/${mediaPath}";
            fsType = "none";
            options = [ "bind" ];
          };
        };
    };

  mkMany = svcs: map (s: mkOne s) svcs;

in {
  inherit
    mkOne
    mkMany
    base
    libPath
    cachePath
    downloadsPath
    mediaPath
    downloadsRoot
    mediaRoot
    # uids
    # base
    # cacheBase
    # mediaRoot
    # hasDownloadsDir
    # hasMediaDir
    downloadsGID
    mediaGID
    ;
}
