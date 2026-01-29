{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.wg_client_systemd;
in
{
  options.services.wg_client_systemd = {
    enable = mkEnableOption "Wireguard client with networkd";

    port = mkOption {
      default = "51821";
      type = types.str;
    };

    localDns = mkOption {
      type = types.str;
      description = "Local dns server on the server. ";
    };

    serverPubKey = mkOption {
      type = types.str;
    };

    localSubnet = mkOption {
      type = types.str;
      description = "Local subnet on server to allow access to.";
    };

    subnet = mkOption {
      type = types.str;
      default = "10.0.0.0";
      description = "Wireguard subnet.";
    };

    endpoint = mkOption {
      type = types.str;
    };

    clientIp = mkOption {
      default = "10.100.0.2";
      type = types.str;
    };

    serverIp = mkOption {
      default = "10.100.0.1";
      type = types.str;
    };

    pskFile = mkOption {
      default = config.sops.secrets."wg/${config.networking.hostName}".path;
      type = types.path;
    };

    device = mkOption {
      default = "wg0";
      type = types.str;
    };

    bypassMullvad = mkOption {
      default = true;
      description = "Enables local dns through this tunnel work when Mullvad VPN client is running.";
      type = types.bool;

    };

  };
  config = mkIf cfg.enable {
    systemd.network.enable = true;
    services.resolved.enable = true;
    systemd.network.networks."50-${cfg.device}" = {
      matchConfig.Name = "${cfg.device}";


      networkConfig = {
        Address = [ "${cfg.clientIp}/24" ];
        DNS     = [ "${cfg.localDns}" ];
        Domains = [ "~lan" ];
      };
      routes = [
        { Destination = "${cfg.serverIp}/32";  }
        { Destination = "${cfg.localSubnet}/24"; }
        { Destination = "${cfg.subnet}/24";  }
      ];

      # ENSURE ENDPOINT DOESNT GET ROUTE THROUGH MULLVAD
      routingPolicyRules = lib.optionals cfg.bypassMullvad [
        {
          Priority = 50;
          Family = "ipv4";
          IPProtocol = "udp";
          DestinationPort = cfg.port;
          Table = "main";
        }
      ];



      linkConfig.RequiredForOnline = "no";
    };

    systemd.network.netdevs."50-${cfg.device}" = {
      netdevConfig = {
        Kind = "wireguard";
        Name = "${cfg.device}";
        MTUBytes = "1420";
      };

      wireguardConfig = {
        PrivateKeyFile = cfg.pskFile;
        ListenPort     = cfg.port;
      };

      wireguardPeers = [
        {
          PublicKey           = cfg.serverPubKey;
          Endpoint            = "${cfg.endpoint}:${cfg.port}";
          AllowedIPs          = [
            "${cfg.serverIp}/32"
            "${cfg.localSubnet}/24"
            "${cfg.subnet}/24"
          ];
          PersistentKeepalive = 25;
        }
      ];
    };

    networking.nftables = mkIf cfg.bypassMullvad {
      enable = true;
      tables.excludeDNSTraffic = {
        family = "inet";
        content = ''
          define RESOLVER_ADDRS = { ${cfg.localDns} }

          chain excludeDns {
          type filter hook output priority -10; policy accept;
          ip daddr $RESOLVER_ADDRS udp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
          ip daddr $RESOLVER_ADDRS tcp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
          }
        '';
      };
      tables.excludeTailscale = {
        family = "inet";
        content = ''
            chain output {
              type route hook output priority 0; policy accept;
              ip daddr 100.64.0.0/10 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
            }
     '';
      };
      # FOR NOW THIS IS USING A FIXED IP WHICH CAN CHANGE. PROBABLY SHOULD FETCH WITH A SYSTEMD TIMER OR SOMETHING..
      tables.excludeWG_ENDPOINT = {
        family = "inet";
        content = ''
        chain excludeOutgoing {
          type route hook output priority 0; policy accept;
          ip daddr ${cfg.endpoint} ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
        }
        '';
      };
    };
  };
}
