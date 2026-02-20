{ config, lib, pkgs, ... }:
let
  svc = import ./lib.nix { inherit config; };
  geoDbCountryPath = "/var/lib/geoipupdate/GeoLite2-Country.mmdb";
  allowedCountries = [ "SE" ];
in
{
  config = lib.mkIf (svc.hasService "geoipupdate") {
    services.geoipupdate = {
      enable = true;
      settings = {
        AccountID = 1286842;
        EditionIDs = [ "GeoLite2-Country" ];
        LicenseKey = { _secret = "/run/credentials/geoipupdate.service/maxmind_license_key"; };
        DatabaseDirectory = "/var/lib/geoipupdate";
      };
    };
    users.users.nginx.extraGroups = [ "geoip" ];
    services.nginx = {
      package = pkgs.nginx.override {
        modules = with pkgs.nginxModules; [geoip2];
      };
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
    };
  };
}
