{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
hostname = "KAIZOKU";
sabnzbdSecretMount = "/secrets/sabnzbd";
in {
  imports =
    [
      (import ../../common/vm-common.nix { hostname = hostname; media = true; })
      (svc.mkOne { name = "qbittorrent"; bindTarget="/var/lib/qBittorrent"; downloadsGroup = true; })
      (svc.mkOne { name = "sabnzbd"; downloadsGroup=true; })
      (svc.mkOne { name = "mullvad"; unit = "mullvad-daemon"; user="root"; uid=0; persistCache=true; })
      (import ../../common/sabnzbd_config.nix { secretFilePath = "${sabnzbdSecretMount}/secretConfig"; } )
    ];

    systemd.services = {
      mullvad-daemon.environment = {
        MULLVAD_SETTINGS_DIR = "/var/lib/mullvad";
        MULLVAD_CACHE_DIR = "/var/cache/mullvad";
      };
      qbittorrent.serviceConfig.UMask = "002";
      sabnzbd.serviceConfig.UMask = "002";
    };

    nixpkgs.config.allowUnfree = true;
    services = {
      sabnzbd.enable = true;
      qbittorrent.enable = true;
      mullvad-vpn.enable = true;
    };

    microvm.shares = [
      {
        proto = "virtiofs";
        tag = "sabnzbdSecret";
        source = "/run/secrets/sabnzbd";
        mountPoint = sabnzbdSecretMount;
      }
    ];

    microvm.vcpu = 2;
    microvm.mem = 4000;

}
