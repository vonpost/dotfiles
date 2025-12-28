{ lib }:

let
  base = "/aleph/state/services";

  # Stable IDs (portable across VMs)
  uids = {
    prowlarr    = 2101;
    radarr      = 2102;
    sonarr      = 2103;
    jellyfin    = 2104;
    jellyseerr  = 2105;
    sabnzbd     = 2106;
    qbittorrent = 2107;
  };

  defaultBindTarget = name: "/var/lib/${name}";

  mkOne =
    { name
    , uid ? uids.${name}
    , source ? "${base}/${name}"          # host path
    , stateMount ? "/state/${name}"       # inside VM
    , bindTarget ? defaultBindTarget name # inside VM
    , virtioTag ? "svc-${name}"
    }:
    { ... }:
    {
      users.groups.${name}.gid = lib.mkForce uid;
      users.users.${name} = {
        uid = lib.mkForce uid;
        group = lib.mkForce name;
        isSystemUser = lib.mkForce true;
      };
      microvm.shares = [
        {
          proto = "virtiofs";
          tag = virtioTag;
          source = source;
          mountPoint = stateMount;
        }
      ];

      fileSystems.${bindTarget} = {
        device = stateMount;
        options = [ "bind" ];
      };
    };

  mkMany = names: map (n: mkOne { name = n; }) names;

in {
  inherit mkOne mkMany uids base;
}
