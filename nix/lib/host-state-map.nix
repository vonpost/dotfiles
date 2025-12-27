{ lib, ... }:
let
  svc = import ./vm-service-state.nix { inherit lib; };
  mkRule = name: uid: "d ${svc.base}/${name} 0750 ${toString uid} ${toString uid} -";
in {
  systemd.tmpfiles.rules =
    [ "d ${svc.base} 0755 root root -" ]
    ++ lib.mapAttrsToList mkRule svc.uids;
}
