{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "MAMORU";
in {
  imports = [
    (import ../../common/vm-common.nix { hostname = hostname; })
  ] ;

  microvm.vcpu = 4;
  microvm.mem = 2048;

}
