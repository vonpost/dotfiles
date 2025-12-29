{ lib, ... }:
let
  svc = import ./vm-service-state.nix { inherit lib; };
  mkStateRule = name: uid: "d ${svc.base}/${name} 0750 ${toString uid} ${toString uid} -";
  mkCacheRule = name: uid: "d ${svc.cacheBase}/${name} 0750 ${toString uid} ${toString uid} -";
in {
  systemd.tmpfiles.rules =
    [
      "d ${svc.base} 0755 root root -"
      "d ${svc.cacheBase} 0755 root root -"
    ]
    ++ lib.mapAttrsToList mkStateRule svc.uids
    ++ lib.mapAttrsToList mkCacheRule svc.uids;
}
