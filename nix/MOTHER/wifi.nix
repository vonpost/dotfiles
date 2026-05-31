{ config,  ... }:
let
  wifiIp="192.168.1.200";
in
{
  networking.wireless = {
    enable = true;
    secretsFile = "${config.sops.secrets."wifi".path}";
    networks = {
      puppa = {
        ssid="puppa";
        pskRaw = "ext:puppa";
      };
    };
  };
  systemd.network.networks."90-wlp1s0f0u2" = {
    matchConfig.Name = "wlp1s0f0u2";
    address = [ "${wifiIp}/24" ];
    dhcpV4Config = {
      RouteMetric=300;
    };
  };

}
