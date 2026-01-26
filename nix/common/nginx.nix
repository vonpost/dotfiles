{ config, lib, pkgs, ... }:
let
  url = "daddyz.myaddr.io";
  geoDbCountryPath = "/var/lib/geoipupdate/GeoLite2-Country.mmdb";
  allowedCountries = [ "SE" ];
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

  in
{

  security.acme.acceptTerms = true;
  security.acme.defaults.email = "daniel.j.collin@gmail.com";
  services.nginx = {
    package = pkgs.nginx.override {
      modules = with pkgs.nginxModules; [geoip2];
    };
    enable = true;
    enableReload = true;
    clientMaxBodySize = "40M";
    mapHashMaxSize = 4096;
    resolver.ipv6 = false;
    appendHttpConfig = ''
      geoip2 ${geoDbCountryPath} {
        auto_reload 5m;
        $geoip2_country_code country iso_code;
      }
      map $geoip2_country_code $allowed_country {
        default 0;
        ${builtins.concatStringsSep "\n  " (map (c: "${c} 1;") allowedCountries)}
      }
    '';

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
        extraConfig = ''
          proxy_buffering off;
          ${geoIpConfig}
        '';
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
        extraConfig = ''
          proxy_buffering off;
          ${geoIpConfig}
        '';
      };
    };
  };
}
