{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
hostname = "KAIZOKU";
in {
  imports =
    [
      (import ../../common/vm-common.nix { hostname = hostname; })
      (import ../../common/sabnzbd_config.nix { secretFilePath = "/run/credentials/sabnzbd.service/sabnzbd_secret_config"; } )
    ];

    systemd.services = {
      mullvad-daemon.environment = {
        MULLVAD_SETTINGS_DIR = "/var/lib/mullvad";
        MULLVAD_CACHE_DIR = "/var/cache/mullvad";
      };
      qbittorrent.serviceConfig.UMask = lib.mkForce "0007";
      sabnzbd.serviceConfig = {
        UMask = lib.mkForce "0007";
      };
    };

    nixpkgs.config.allowUnfree = true;
    services = {
      sabnzbd.enable = true;
      qbittorrent.enable = true;
      mullvad-vpn.enable = true;
    };

    microvm.vcpu = 2;
    microvm.mem = 4000;

}
