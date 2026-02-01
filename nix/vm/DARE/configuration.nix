{ self, config, lib, pkgs, ... }:

let
  netLib = import ../../lib/network-topology.nix {inherit lib;};
  hostname = "DARE";
in
{
  imports = [
    (import ../../common/vm-common.nix {
      inherit hostname;
    })
    netLib.mkDns
  ];
}
