{ self, config, pkgs, lib, microvm, bleeding, ... }:
let svc = import ../../lib/vm-service-state.nix { inherit lib; };
    addrs = import ../../lib/lan-address.nix;
    hostname = "KAIZOKU";
in {
  imports = ( [ (svc.mkOne {name = "qbittorrent"; bindTarget="/var/lib/qBittorrent"; downloadsGroup = true; }) (svc.mkOne {name = "sabnzbd"; downloadsGroup=true; }) ]) ++ [ ../../common/share_journald.nix ];
  services.mullvad-vpn.enable = true;
  systemd.services.mullvad-daemon.environment = {
    MULLVAD_SETTINGS_DIR = "/var/lib/mullvad";
  };


  nixpkgs.config.allowUnfree = true;
  services.sabnzbd.enable = true;
  services.qbittorrent.enable = true;

  networking.hostName = hostname;
  networking.useDHCP = false;
  networking.enableIPv6 = false;
  networking.firewall.enable = false;
  networking.useNetworkd = true;
  networking.nameservers = [ addrs.DARE.ip ];
  systemd.network.enable = true;
  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "${addrs.${hostname}.mac}";
    networkConfig = {
      Address = "${addrs.${hostname}.ip}/24";
      Gateway = addrs.gateway.ip;

      # Upstream DNS for the VM itself (nix, ntp, etc.)
      DNS = [ addrs.DARE.ip ];
    };
    linkConfig.RequiredForOnline = "yes";
  };
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
  ];

  microvm.shares = [
    {
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
    }
    {
      proto = "virtiofs";
      tag = "theta";
      source = "/theta/";
      mountPoint = "/theta";
    }
    {
      proto = "virtiofs";
      tag = "mullvad";
      source = "/aleph/state/services/lib/mullvad";
      mountPoint = "/var/lib/mullvad";
    }
  ];

  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-${hostname}";
      mac = addrs.${hostname}.mac;
    }
  ];
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vcpu = 2;
  microvm.mem = 4000;

}
