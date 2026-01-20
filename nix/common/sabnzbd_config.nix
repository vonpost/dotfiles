{ secretFilePath }:
{lib, config, pkgs, ... }:
{
  services.sabnzbd = {
    secretFiles = [ secretFilePath ];
    settings = {
      misc = {
        port = 1337;
        host = "0.0.0.0";
        permissions = 775;
        download_dir = "/downloads/sabnzbd/incomplete";
        download_free = "500M";
        complete_dir = "/downloads/sabnzbd/complete";
        complete_free = "500M";
        cache_limit = "1G";
      };
      servers = {
        "eunews.frugalusenet.com" = {
          priority = 0;
          displayname = "eunews.frugalusenet.com";
          name = "eunews.frugalusenet.com";
          host = "eunews.frugalusenet.com";
        };
        "bonus.frugalusenet.com" = {
          priority = 1;
          displayname = "bonus.frugalusenet.com";
          name = "eunews.frugalusenet.com";
          host = "bonus.frugalusenet.com";
        };
      };
    };
  };
}
