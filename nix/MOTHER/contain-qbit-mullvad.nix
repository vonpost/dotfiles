{ config, pkgs, libs, ssh_master_keys, ... }:
let
  qbit = pkgs.qbittorrent.override {
    guiSupport = false;
  };
  mullvad_secret = "${config.sops.secrets.mullvad.path}";
in
with libs;
{
  systemd.network.enable  = true;

  fileSystems."/tmp/net_cls" = {
    device = "net_cls";
    fsType = "cgroup";
    options = [ "net_cls" ];
  };

  containers.qbit = {
    privateNetwork = true;
    hostBridge = "br0";
    bindMounts = { "/theta" = { hostPath = "/theta/"; isReadOnly = false; };
                   "/aleph" = { hostPath = "/aleph"; isReadOnly = false; };
                   "/run/secrets/mullvad" = { hostPath = "${mullvad_secret}"; isReadOnly = true; };
                 };
    autoStart = true;
    config =
      { config, pkgs, ... }:
      {
        services.mullvad-vpn.enable = true;
        systemd.services."mullvad-daemon".postStart = ''
          while ! ${pkgs.mullvad}/bin/mullvad status >/dev/null; do sleep 1; done

          # REPLACE with your actual mullvad account number
          account="$(cat ${mullvad_secret})"

          # only login if we're not already logged in otherwise we'll get a new device
          current_account="$(${pkgs.mullvad}/bin/mullvad account get | grep "account:" | sed 's/.* //')"
          if [[ "$current_account" != "$account" ]]; then
          ${pkgs.mullvad}/bin/mullvad account login "$account"
          fi

          ${pkgs.mullvad}/bin/mullvad lan set allow
          ${pkgs.mullvad}/bin/mullvad lockdown-mode set on
          ${pkgs.mullvad}/bin/mullvad auto-connect set on

          # disconnect/reconnect is dirty hack to fix mullvad-daemon not reconnecting after a suspend
          ${pkgs.mullvad}/bin/mullvad disconnect
          sleep 0.1
          ${pkgs.mullvad}/bin/mullvad connect
      '';

        services.openssh.enable = true;
        users.users.root.openssh.authorizedKeys.keys = ssh_master_keys;
        nixpkgs.config.allowUnfree = true;
        networking.firewall.enable = false;
        networking.useHostResolvConf = false;
        networking.enableIPv6 = false;
        networking.hostName = "qbit";
        networking.defaultGateway = "192.168.1.1";
        networking.interfaces."eth0".useDHCP = true;

        environment.systemPackages = [ qbit pkgs.speedtest-cli ];
        services.sabnzbd.enable = true;
        systemd.services.qbitd = {
          enable = true;
          after = [ "network-online.target" ];
          description = "Qbittorrent Daemon";
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            ExecStart="${qbit}/bin/qbittorrent-nox";
            ExecStop="${pkgs.psmisc}/bin/killall qbittorrent-nox";
          };
        };
      };
  };
}
