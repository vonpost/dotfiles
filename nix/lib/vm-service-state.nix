{ lib }:

let
  base = "/aleph/state/services";

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

  defaultBindTarget = name: "/var/lib/${name}";
  privateBindTarget = sd: "/var/lib/private/${sd}";

  mkOne =
    { name
    , unit ? name
    , uid ? uids.${name}
    , source ? "${base}/${name}"          # host path
    , stateMount ? "/state/${name}"       # inside VM (virtiofs mountpoint)
    , bindTarget ? null                   # explicit override
    , stateDirName ? (privateStateDir.${name} or null)  # auto from map
    , virtioTag ? "svc-${name}"
    , disableDynamicUser ? true
    }:
    { ... }:
    let
      chosenBindTarget =
        if bindTarget != null then bindTarget
        else if stateDirName != null then privateBindTarget stateDirName
        else defaultBindTarget name;
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
        unitConfig.RequiresMountsFor = [ chosenBindTarget ];
      };

      microvm.shares = [
        {
          proto = "virtiofs";
          tag = virtioTag;
          source = source;
          mountPoint = stateMount;
        }
      ];

      fileSystems.${chosenBindTarget} = {
        device = stateMount;
        fsType = "none";
        options = [ "bind" ];
      };
    };

  mkMany = names: map (n: mkOne { name = n; }) names;

in {
  inherit mkOne mkMany uids base privateStateDir;
}
