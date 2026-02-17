{ lib }:
let
  base = "/state/services";
  mediaRoot = "/omega/media";
  downloadsRoot = "/omega/downloads";
  libPath = "./lib";
  cachePath = "./cache";
  downloadsPath = "./downloads";
  mediaPath = "./media";

  downloadsGID = 3000;
  mediaGID = 3001;

  mkOne =
    { name
    , unit ? name
    , user ? name
    , group ? user
    , uid ? uid
    , gid ? uid
    , bindTarget ? name
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
        isSystemUser = lib.mkDefault true;
        extraGroups = (lib.optional downloadsGroup "downloads") ++ (lib.optional mediaGroup "media");
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
          "/data/downloads" = {
            device = "/state/${downloadsPath}";
            fsType = "none";
            options = [ "bind" ];
          };
        }

        // lib.optionalAttrs mediaGroup {
          "/data/media" = {
            device = "/state/${mediaPath}";
            fsType = "none";
            options = [ "bind" ];
          };
        };
    };

  mkMany = svcs: map (s: mkOne s) svcs;
in
{
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
    downloadsGID
    mediaGID;
}
