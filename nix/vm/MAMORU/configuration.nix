{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "MAMORU";
    netLib = import ../../lib/network-topology.nix {inherit lib; };
in {
  imports = [
    (import ../../common/vm-common.nix { hostname = hostname; })
    netLib.mkGateway
  ] ;

  microvm.vcpu = 4;
  microvm.mem = 2048;

}
