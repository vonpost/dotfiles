{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "SOTO";
in {
  imports = [
    (import ../../common/vm-common.nix { hostname = hostname;  })
    ../../common/nginx.nix
    ../../common/myaddr.nix
  ] ;

  services.jellyseerr.enable = true;
  services.jellyfin =  {
    enable = true;
    package = bleeding.jellyfin.override { jellyfin-ffmpeg = pkgs.rffmpeg; };
  };
  users.users.jellyseerr.extraGroups = [ "media" ];
  services.geoipupdate = {
    enable = true;
    settings = {
      AccountID = 1286842;
      EditionIDs = [ "GeoLite2-Country" ];
      LicenseKey = { _secret = "/run/credentials/geoipupdate.service/maxmind_license_key"; };
      DatabaseDirectory = "/var/lib/geoipupdate";
    };
  };

  environment.systemPackages = with pkgs; [
      jellyfin-ffmpeg
  ];

  microvm.vcpu = 8;
  microvm.mem = 8000;
  #microvm.hotplugMem = 8400;

}
