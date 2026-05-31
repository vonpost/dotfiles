# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, bleeding, ssh_master_keys, ... }:
let
  hostname = "MOTHER";
  br0Mac = "70:88:88:88:6c:e1";
  infra = config.my.infra;
  topology = infra.topology;
  vlans = topology.vlans;
  getSubnet = vlan: "10.10.${toString vlans.${vlan}.id}";
  getIp = name: vlan: "${getSubnet vlan}.${toString topology.vms.${name}.id}";
  dnsIp = getIp topology.dnsVM "srv";
in
{
  imports =
    [ # Include the results of the hardware scan.
    ./filesystems.nix
    ./hardware-configuration.nix
    ./vfio.nix
    ./vm.nix
    ./wifi.nix
    ./exported_secrets.nix
    ../common/wg_server_systemd.nix
    ../config/infra/site-defaults.nix
    ../lib/modules/infra/schema.nix
    ../lib/modules/infra/service-state.nix
    ../lib/modules/infra/host-service-mounts.nix
    ../lib/modules/infra/network-host.nix
    ];

  my.infra = {
    hostServiceMounts.enable = true;
    networkHost.enable = true;
  };

  services.tailscale.enable = true;
  services.tailscale.extraDaemonFlags = ["--no-logs-no-support"];

  services.wg_server_systemd = {
    enable = true;
    peers = [
      "THFP2zsn0GlmX6aAqAIKdHfmg2hxXNSPd4eDoGdHKD8="
      "qMgS5iWMuDG4XG19MIXLz89Q3R6gSuWfnhQ0Xdl7T1E="
    ];
  };
    systemd.network.wait-online = {
      anyInterface = true;
      timeout = 0;
    };

    # IF SYSTEM CRASHES WE NEED TO REBOOT SINCE HEADLESS
    boot.kernel.sysctl."kernel.panic" = 20;

    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;
    };

    systemd.targets.sleep.enable = false;
    systemd.targets.suspend.enable = false;
    systemd.targets.hibernate.enable = false;
    systemd.targets.hybrid-sleep.enable = false;
    systemd.settings.Manager.DefaultTimeoutStopSec = "10s";
    boot.initrd.kernelModules = [ "8812au" ];
    boot.extraModulePackages = [ config.boot.kernelPackages.rtl8812au ];
    nix.gc.automatic = true;
    nix.gc.dates = "weekly";
    nix.gc.options = "--delete-older-than 60d";

    services.sysstat.enable = true;
    nixpkgs.config.allowUnfree = true;
    services.getty.autologinUser = "root";
    systemd.network.enable = true;

    # Bridge device
    systemd.network.netdevs."10-br0" = {
      netdevConfig = {
        Name = "br0";
        Kind = "bridge";
        MACAddress = br0Mac;
      };
    };

    # Wired NIC: bridge port (no IP)
    systemd.network.networks."10-enp8s0" = {
      matchConfig.Name = "enp8s0";
      networkConfig.Bridge = "br0";
      linkConfig.RequiredForOnline = "no";
    };
    # Bridge: static IP + default route + DNS
    systemd.network.networks."20-br0" = {
      matchConfig.Name = "br0";
      linkConfig.RequiredForOnline = "no";
      networkConfig = {
        DHCP="yes";
        BindCarrier = "enp8s0";
        IPv6AcceptRA="yes";
      };
      dhcpV4Config = {
        UseDNS=false;
        RouteMetric=300;
      };
    };

    #boot.kernelParams = [ "ipv6.disable=1" ];
    networking = {
      hostName = "MOTHER";
      nameservers = [ dnsIp "9.9.9.9" ];
      firewall.enable = true;
      firewall.checkReversePath = false; # Needed for wireguard for some reason.. bad.
      firewall.trustedInterfaces = ["tailscale0" "wgvpn"];
      #enableIPv6 = false;
      useNetworkd = true;
      useDHCP = false;
      iproute2 = {
        enable = true;
        rttablesExtraConfig = "200 wifi";
      };
    };
    # Select internationalisation properties.
    nix.extraOptions = ''
      experimental-features = nix-command
    '';

    time.timeZone = "Europe/Amsterdam";
    vfio.enable = true;
    environment.systemPackages = with pkgs; [
      wget
      git
      infra-flake-update
    ];
    services.openssh.enable = true;
    services.openssh.settings.PasswordAuthentication = false;
    users.extraUsers.root.shell = pkgs.bash;

    users.users.root.openssh.authorizedKeys.keys = ssh_master_keys;
    # This value determines the NixOS release with which your system is to be
    # compatible, in order to avoid breaking some software such as database
    # servers. You should change this only after NixOS release notes say you
    # should.
    system.stateVersion = "25.11"; # Did you read the comment?
}
