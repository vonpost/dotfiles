{ ... }:
{
  services.sabnzbd = {
    secretFiles = [ "/run/credentials/sabnzbd.service/sabnzbd_secret_config" ];
    settings = {
      misc = {
        port = 1337;
        host = "0.0.0.0";
        # Load-bearing: sabnzbd chmods every completed job dir to this. Some of
        # its dir creation ignores the process umask, and the arrs need group
        # rwx here (x to enter, w to delete after import). Unlike the arrs,
        # sab's unit has no PrivateUsers/RestrictSUIDSGID sandbox, so this
        # chmod actually works. Do not remove again (see 8701d3b fallout).
        permissions = "2775";
        download_dir = "/var/lib/sabnzbd/Download";
        download_free = "500M";
        complete_dir = "/data/downloads/sabnzbd";
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
