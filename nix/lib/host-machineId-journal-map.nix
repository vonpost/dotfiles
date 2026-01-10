{ config, lib, pkgs, ... }:
let
  addr = import ./lan-address.nix;
  vms = builtins.filter (n : (n != "gateway") && (n != "MOTHER")) (builtins.attrNames addr);
in
{
  systemd.tmpfiles.rules = map (vmHost:
  let
    machineId = addr.${vmHost}.machineId;
  in
  # creates a symlink of each MicroVM's journal under the host's /var/log/journal
  "L+ /var/log/journal/${machineId} - - - - /aleph/vm-pool/microvm/${vmHost}/journal/${machineId}"
  ) vms;

}
