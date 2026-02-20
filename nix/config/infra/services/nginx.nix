{ config, lib, pkgs, ... }:
let
    geoIpConfig = ''
      set $allow_access 0;

      if ($allowed_country = 1) {
        set $allow_access 1;
      }
      if ($remote_addr ~ ^192\.168\.1\.) {
        set $allow_access 1;
      }
      if ($remote_addr ~ ^172\.16\.\.) {
        set $allow_access 1;
      }
      if ($remote_addr ~ ^10\.\.\.) {
        set $allow_access 1;
      }
      if ($remote_addr ~ ^127\.\.\.) {
        set $allow_access 1;
      }
      if ($allow_access = 0) {
        return 403;
      }
    '';
  svc = import ./lib.nix { inherit config; };
  url = "daddyz.myaddr.io";
  jellyfin_host = "localhost";
  extraCfg = lib.concatStringsSep "\n" ([ ''proxy_buffering off;'' ] ++ (lib.optional (svc.hasService "geoipupdate")  geoIpConfig));
in
{
  config = lib.mkIf (svc.hasService "nginx") {
    services.nginx = {
      enable = true;
      enableReload = true;
      clientMaxBodySize = "40M";
      mapHashMaxSize = 4096;
      resolver.ipv6 = false;

      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      sslCiphers = "AES256+EECDH:AES256+EDH:!aNULL";


      virtualHosts."_" = {
        serverName = "_";
        default = true;
        rejectSSL = true;
        locations."/" = {
          return = "444";    # nginx: close connection, no response :contentReference[oaicite:3]{index=3}
        };
      };

      virtualHosts."jellyfin.${url}" = {
        enableACME = svc.hasService "acme";
        forceSSL = true;
        locations."/robots.txt" = {
          extraConfig = ''
            rewrite ^/(.*)  $1;
            return 200 "User-agent: *\nDisallow: /";
          '';
        };

        locations."/" = {
          proxyPass = "http://${jellyfin_host}:8096";
          proxyWebsockets = true;
          extraConfig = extraCfg;
        };
      };
      virtualHosts."requests.${url}" = {
        enableACME = svc.hasService "acme";
        forceSSL = true;
        locations."/robots.txt" = {
          extraConfig = ''
            rewrite ^/(.*)  $1;
            return 200 "User-agent: *\nDisallow: /";
          '';
        };
        locations."/" = {
          proxyPass = "http://${jellyfin_host}:5055";
          proxyWebsockets = true;
          extraConfig = extraCfg;
        };
      };
    };
  };
}
