{ config, lib, ... }:
let
  svc = import ./lib.nix { inherit config; };
  hasDownloader = svc.hasAnyService [ "qbittorrent" "sabnzbd" ];
in
{
  config = lib.mkMerge [
    (lib.mkIf (svc.hasService "qbittorrent") {
      services.qbittorrent.enable = true;
      systemd.services.qbittorrent.serviceConfig.UMask = lib.mkForce "0007";
    })

    (lib.mkIf (svc.hasService "sabnzbd") {
      services.sabnzbd.enable = true;
      systemd.services.sabnzbd.serviceConfig.UMask = lib.mkForce "0007";
    })

    (lib.mkIf (hasDownloader || svc.hasService "mullvad") {
      nixpkgs.config.allowUnfree = true;
      services.mullvad-vpn.enable = true;

      systemd.services.mullvad-daemon.environment = {
        MULLVAD_SETTINGS_DIR = "/var/lib/mullvad";
        MULLVAD_CACHE_DIR = "/var/cache/mullvad";
      };
    })
  ];
}
