{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "SOTO";
in {
  imports = [
    (import ../../common/vm-common.nix { hostname = hostname; media = true; })
    (svc.mkOne { name = "jellyfin"; persistCache = true; })
    (svc.mkOne  { name = "jellyseerr"; })
    ../../common/nginx.nix
    ../../common/myaddr.nix
  ];

  services.jellyseerr.enable = true;
  services.jellyfin =  {
    enable = true;
    package = bleeding.jellyfin;
  };

  microvm.vcpu = 8;
  microvm.mem = 8000;
  #microvm.hotplugMem = 8400;

}
