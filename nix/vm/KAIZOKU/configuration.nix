{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
hostname = "KAIZOKU";
sabnzbdSecretMount = "/sabnzbd";
in {
  imports =
    [
      (import ../../common/vm-common.nix { hostname = hostname; })
      (import ../../common/sabnzbd_config.nix { secretFilePath = "${sabnzbdSecretMount}/secretConfig"; } )
    ];

    systemd.services = {
      mullvad-daemon.environment = {
        MULLVAD_SETTINGS_DIR = "/var/lib/mullvad";
        MULLVAD_CACHE_DIR = "/var/cache/mullvad";
      };
      qbittorrent.serviceConfig.UMask = lib.mkForce "0007";
      sabnzbd.serviceConfig = {
        PermissionsStartOnly=true; # Needed to read the virtiofs mounted secret properly.
        UMask = lib.mkForce "0007";
      };
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
