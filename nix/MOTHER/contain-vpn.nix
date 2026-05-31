{ config, pkgs, libs, ssh_master_keys, ... }:
let
  pskPath = "${config.sops.secrets."wg/${config.networking.hostName}".path}";
in
{
containers.vpn = {
  privateNetwork = true;
  hostBridge = "br0";
  autoStart = true;
  bindMounts."${pskPath}" = { hostPath = "${pskPath}"; isReadOnly = true; };
  config =
      { config, pkgs, ... }:
      {
      imports = [ ../common/wg_server.nix ];
      services.wg_server = {
        enable = true;
        peers = [
          "THFP2zsn0GlmX6aAqAIKdHfmg2hxXNSPd4eDoGdHKD8="
          "qMgS5iWMuDG4XG19MIXLz89Q3R6gSuWfnhQ0Xdl7T1E="
        ];
        pskFile = pskPath;
      };
      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keys = ssh_master_keys;
      networking.firewall.enable = false;
      networking.enableIPv6 = false;
      networking.useHostResolvConf = false;
      networking.defaultGateway = "192.168.1.1";
      networking.hostName = "vpn";
      networking.interfaces."eth0".useDHCP = true;
      };
  };
}
