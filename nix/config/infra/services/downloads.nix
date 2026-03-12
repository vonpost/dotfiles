{ config, lib, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  vlanNames = builtins.attrNames svc.vlans;
  primaryVlan = lib.head svc.vm.assignedVlans;
  routedLabSubnets =
    map
      (vlan: {
        Destination = "${svc.getSubnet vlan}.0/24";
        Gateway = svc.getGateway primaryVlan;
      })
      (builtins.filter (vlan: !(builtins.elem vlan svc.vm.assignedVlans)) vlanNames);
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

    (lib.mkIf (svc.hasService "mullvad") {
      nixpkgs.config.allowUnfree = true;
      services.mullvad-vpn.enable = true;

      systemd.services.mullvad-daemon.environment = {
        MULLVAD_SETTINGS_DIR = "/var/lib/mullvad";
        MULLVAD_CACHE_DIR = "/var/cache/mullvad";
      };

      systemd.network.networks."20-${primaryVlan}".routes = lib.mkAfter routedLabSubnets;
    })
  ];
}
