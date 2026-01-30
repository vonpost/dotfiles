{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.wg_server_systemd;

  # Convert your subnet attrset into useful strings
  wgAddr = "${cfg.subnet.prefix}${toString cfg.subnet.hostIdentifier}${cfg.subnet.suffix}";
  wgNet  = "${cfg.subnet.prefix}0${cfg.subnet.suffix}"; # e.g. 10.100.0.0/24

  # Build peers list: hostIdentifier+1..+N
  peerIds =
    map toString
      (lib.range (cfg.subnet.hostIdentifier + 1)
                 (cfg.subnet.hostIdentifier + builtins.length cfg.peers));

  wgPeers =
    lib.lists.zipListsWith
      (pubKey: id: {
        PublicKey = pubKey;
        AllowedIPs = [ "${cfg.subnet.prefix}${id}/32" ];
      })
      cfg.peers
      peerIds;
in
{
  options.services.wg_server_systemd = {
    enable = mkEnableOption "WireGuard server (networkd-managed)";

    pskFile = mkOption {
      default = config.sops.secrets."wg/${config.networking.hostName}".path;
      type = types.str;
      description = "Path to WireGuard private key file.";
    };

    internalInterface = mkOption {
      default = "wgvpn";
      type = types.str;
      description = "Name of the WireGuard interface.";
    };

    port = mkOption {
      default = 51820;
      type = types.port;
      description = "UDP listen port for WireGuard.";
    };

    peers = mkOption {
      default = [];
      description = "List of peer public keys.";
      type  = types.listOf types.str;
    };

    subnet = mkOption {
      default = { prefix = "10.100.0."; hostIdentifier = 1; suffix = "/24"; };
      type = types.attrs;
      description = "WireGuard subnet definition.";
    };

    # Optional: if you want to restrict which uplinks are allowed for NAT,
    # you can add allowEgressInterfaces and use it in nftables. Default is any.
    allowEgressInterfaces = mkOption {
      default = [];
      type = types.listOf types.str;
      description = "Optional allowlist of egress interfaces for WG NAT. Empty = any uplink.";
    };
  };

  config = mkIf cfg.enable {

    # If you are not already using networkd globally, you can enable it here,
    # but note: this is a system-wide choice in NixOS.
    # If you already have it enabled elsewhere, leave as-is.
    networking.useNetworkd = mkDefault true;

    environment.systemPackages = [ pkgs.wireguard-tools ];

    # Required for routing/NAT
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # Open WireGuard port on the host firewall
    networking.firewall.allowedUDPPorts = [ cfg.port ];

    # ---- WireGuard via systemd-networkd ----
    systemd.network.netdevs."90-${cfg.internalInterface}" = {
      netdevConfig = {
        Name = cfg.internalInterface;
        Kind = "wireguard";
      };
      wireguardConfig = {
        PrivateKeyFile = cfg.pskFile;
        ListenPort = cfg.port;
      };
      wireguardPeers = wgPeers;
    };

    systemd.network.networks."90-${cfg.internalInterface}" = {
      matchConfig.Name = cfg.internalInterface;
      networkConfig = {
        Address = [ wgAddr ];
        # You usually do not want networkd to install a default route for WG server mode.
        # The host's default route should come from whichever uplink is active.
      };
    };

    # ---- NAT + forwarding without choosing an external interface ----
    #
    # This is the critical change: masquerade based on source subnet, not -o eth0.
    # It will NAT out whichever interface the kernel selects via routing.
    #
    networking.nftables.enable = true;

    networking.nftables.ruleset =
      let
        # Optional allowlist support: if empty, allow any oifname.
        oifClause =
          if cfg.allowEgressInterfaces == []
          then ""
          else
            "oifname { ${lib.concatStringsSep ", " (map (i: "\"${i}\"") cfg.allowEgressInterfaces)} } ";
      in
      ''
        table inet wg {
          chain forward {
            type filter hook forward priority 0; policy drop;

            ct state established,related accept

            iifname "${cfg.internalInterface}" accept
          }

          chain postrouting {
            type nat hook postrouting priority 100; policy accept;

            # Masquerade ONLY traffic from WG subnet; do not pin to a specific uplink.
            ip saddr ${wgNet} ${oifClause} masquerade
          }
        }
      '';
  };
}
