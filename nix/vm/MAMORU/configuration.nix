{ self, config, pkgs, lib, microvm, bleeding, ... }:
let hostname = "MAMORU";
    netLib = import ../../lib/network-topology.nix {inherit lib; };
in {
  imports = [
    (import ../../common/vm-common.nix { hostname = hostname; })
    netLib.mkGateway
  ];
  microvm.vcpu = 4;
  microvm.mem = 2148;
}
