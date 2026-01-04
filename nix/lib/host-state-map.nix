{ lib, ... }:
let
  svc = import ./vm-service-state.nix { inherit lib; };
  mkStateRule = name: uid: "d ${svc.libBase}/${name} 0750 ${toString uid} ${toString uid} -";
  mkCacheRule = name: uid: "d ${svc.cacheBase}/${name} 0750 ${toString uid} ${toString uid} -";
  mkDownloadsDir = service: [
    "d ${svc.base}/downloads/${service} 2775 root ${toString svc.downloadsGID} -"
    "d ${svc.base}/downloads/${service}/complete 2775 root ${toString svc.downloadsGID} -"
    "d ${svc.base}/downloads/${service}/incomplete 2775 root ${toString svc.downloadsGID} -"
  ];
in {
  systemd.tmpfiles.rules =
    [
      "d ${svc.base} 0755 root root -"
      "d ${svc.libBase} 0755 root root -"
      "d ${svc.cacheBase} 0755 root root -"
    ]
    ++ lib.lists.flatten (map mkDownloadsDir svc.hasDownloadsDir)
    ++ lib.mapAttrsToList mkStateRule svc.uids
    ++ lib.mapAttrsToList mkCacheRule svc.uids
    ;
}
