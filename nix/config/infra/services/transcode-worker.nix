{ config, lib, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  servers = builtins.filter
    (name: builtins.elem "jellyfin" config.my.infra.vms.${name}.services)
    (builtins.attrNames config.my.infra.vms);
  serverIps = map (name:
    svc.getIp name (svc.topology.vms.${name}.primaryVlan)) servers;
in
{
  config = lib.mkIf (svc.hasService "transcode-worker") {
    assertions = [{
      assertion = servers != [ ];
      message = "The transcode worker requires a Jellyfin server assignment.";
    }];
    services.okuri-target = {
      enable = true;
      authorizedKeys = [
        "from=\"${lib.concatStringsSep "," serverIps}\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzH2Gt2Xs7mNeSpqNCJy2lwT19XC3OiSBNWBHK6zrzF dcol@TERRA"
      ];
    };
  };
}
