{ config, lib, pkgs, ... }:
let
  url = "daddyz.myaddr.io";
  in
{
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "daniel.j.collin@gmail.com";
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    sslCiphers = "AES256+EECDH:AES256+EDH:!aNULL";

    virtualHosts."jellyfin.${url}" = {
      forceSSL = true;
      enableACME = true;
      locations."/robots.txt" = {
        extraConfig = ''
          rewrite ^/(.*)  $1;
          return 200 "User-agent: *\nDisallow: /";
        '';
      };

      locations."/" = {
        proxyPass = "http://SOTO.lan:8096";
        proxyWebsockets = true;
        extraConfig =
          "proxy_buffering off;";
      };
    };

    virtualHosts."requests.${url}" = {
      forceSSL = true;
      enableACME = true;
      locations."/robots.txt" = {
        extraConfig = ''
          rewrite ^/(.*)  $1;
          return 200 "User-agent: *\nDisallow: /";
        '';
      };

      locations."/" = {
        proxyPass = "http://SOTO.lan:5055";
        proxyWebsockets = true;
        extraConfig =
          "proxy_buffering off;";
      };
    };
  };
}
