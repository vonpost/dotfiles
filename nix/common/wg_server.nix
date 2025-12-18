{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.wg_server;
in
{
  options = {
    enable = mkEnableOption "Wireguard server";

    pskFile = mkOption {
      default = config.sops.secrets."wg/${config.networking.hostName}".path;
      type = types.str;
    };

    internalInterface = mkOption {
      default = "wgvpn";
      type = types.str;
    };

    externalInterface = mkOption {
      default = "eth0";
      type = types.str;
    };

    port = mkOption {
      default = 51821;
      type = types.port;
    };

    peers = mkOption {
      default = [];
      description = "List of peer public keys";
      type  = types.list;
    };

    subnet = mkOption {
      default = { prefix = "10.100.0."; hostIdentifier = 1; suffix = "/24"; };
      type = type.attrs;
    };
  };

  config = mkIf cfg.enable {

    environment.systemPackages = [ pkgs.wireguard-tools pkgs.iptables];
    networking = {
      nat = {
        enable = true;
        externalInterface = externalInterface;
        internalInterfaces = [ internalInterface ];
      };
      firewall = {
        allowedUDPPorts = [ externalPort ];
      };
      wireguard.interfaces = {
        "${cfg.internalInterface}" = {
          ips = [ "${cfg.subnet.prefix + cfg.subnet.hostIdentifier + cfg.subnet.suffix}" ];
          listenPort = cfg.externalPort;

          postSetup = ''
            ${pkgs.iptables}/bin/iptables -A FORWARD -i ${cfg.internalInterface} -j ACCEPT
            ${pkgs.iptables}/bin/iptables -A FORWARD -o ${cfg.internalInterface} -j ACCEPT
            ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -o ${externalInterface} -j MASQUERADE
          '';

          postShutdown = ''
            ${pkgs.iptables}/bin/iptables -D FORWARD -i ${cfg.internalInterface} -j ACCEPT
            ${pkgs.iptables}/bin/iptables -D FORWARD -o ${cfg.internalInterface} -j ACCEPT
            ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -o ${cfg.externalInterface} -j MASQUERADE
          '';

          privateKeyFile = "${cfg.pskFile}";

          peers =  lib.lists.zipListsWith (x : y: { publicKey = x; allowedIPs = [ (cfg.subnet.prefix + "${y}" + cfg.subnet.suffix) ]; } )
          cfg.peers (lib.range cfg.hostIdentifier builtins.length(cfg.peers));
        };
      };
    };
  };
}
