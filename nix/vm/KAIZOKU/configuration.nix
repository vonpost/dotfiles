{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    hostname = "KAIZOKU";
in {
  imports =
    [
      (import ../../common/vm-common.nix { hostname = hostname; media = true; })
      (svc.mkOne {name = "qbittorrent"; bindTarget="/var/lib/qBittorrent"; downloadsGroup = true; })
      (svc.mkOne {name = "sabnzbd"; downloadsGroup=true; })
    ];
  services.mullvad-vpn.enable = true;
  systemd.services.mullvad-daemon.environment = {
    MULLVAD_SETTINGS_DIR = "/var/lib/mullvad";
  };


  nixpkgs.config.allowUnfree = true;
  services.sabnzbd.enable = true;
  services.qbittorrent.enable = true;

  microvm.shares = [
    {
      proto = "virtiofs";
      tag = "mullvad";
      source = "/aleph/state/services/lib/mullvad";
      mountPoint = "/var/lib/mullvad";
    }
  ];
  microvm.vcpu = 2;
  microvm.mem = 4000;

}
