{
    mullvad = { name = "mullvad"; uid = 0; unit = "mullvad-daemon"; user = "root"; hasCacheDir = true; logging.enable = true; };
    prowlarr = {
      name = "prowlarr";
      uid = 2101;
      logging.enable = true;
    };
    radarr = {
      name = "radarr";
      uid = 2102;
      downloadsGroup = true;
      mediaGroup = true;
      hasMediaDir = true;
      logging.enable = true;
    };
    sonarr = {
      name = "sonarr";
      uid = 2103;
      downloadsGroup = true;
      mediaGroup = true;
      hasMediaDir = true;
      logging.enable = true;
    };
    recyclarr = {
      name = "recyclarr";
      uid = 2108;
      unit = "recyclarr";
      managedState = false;
      logging.enable = true;
      secrets = {
        recyclarr_radarr_api_key = {
          source = "/run/secrets/arrApiKeys/radarr";
        };
        recyclarr_sonarr_api_key = {
          source = "/run/secrets/arrApiKeys/sonarr";
        };
      };
    };
    jellyfin = {
      name = "jellyfin";
      uid = 2104;
      mediaGroup = true;
      hasCacheDir = true;
      logging.enable = true;
      secrets = {
        jellyfin_transcode_ssh_key = {
          source = "/run/secrets/ssh/jellyfin";
        };
      };
    };
    seerr = { name = "seerr"; uid = 2105; mediaGroup = true; logging.enable = true; };
    sabnzbd = {
      name = "sabnzbd";
      uid = 2106;
      downloadsGroup = true;
      hasDownloadsDir = true;
      logging.enable = true;
      secrets = {
        sabnzbd_secret_config = {
          source = "/run/secrets/sabnzbd/secretConfig";
          sops = {
            format = "ini";
            sopsFile = ../../secrets/sabnzbd.ini;
            key = "";
          };
        };
      };
    };
    qbittorrent = {
      name = "qbittorrent";
      uid = 2107;
      downloadsGroup = true;
      hasDownloadsDir = true;
      bindTarget = "qBittorrent";
      logging.enable = true;
    };
    wolf = {
      name = "wolf";
      uid = 1000;
      logging.enable = true;
    };
    "llama-cpp" = { name = "llama-cpp"; uid = 2109; logging.enable = true; };
    # managedState: the signature catalog and volume baseline are the digest's
    # only long-term memory, and they must outlive both reboots and Loki's much
    # shorter retention.
    logDigest = { name = "logDigest"; uid = 2110; logging.enable = true; };
    acme = { name = "acme"; uid = 2111; unit = "acme-setup"; logging.enable = true; };
    nginx = {
      name = "nginx";
      uid = 2115;
      managedState = false;
      logging.enable = true;
    };
    geoipupdate = {
      name = "geoipupdate";
      uid = 2112;
      user = "geoip";
      unit = "geoipupdate";
      logging.enable = true;
      secrets = {
        maxmind_license_key = {
          source = "/run/secrets/maxmind/license_key";
        };
      };
    };
    myaddr = {
      name = "myaddr";
      uid = 2116;
      unit = "myaddr-update";
      managedState = false;
      logging.enable = true;
      secrets = {
        myaddr_api_key = {
          source = "/run/secrets/myaddr/api_key";
        };
      };
    };
    unbound = {
      name = "unbound";
      uid = 2118;
      managedState = false;
      logging.enable = true;
    };
    prometheus = {
      name = "prometheus";
      uid = 2119;
    };
    loki = {
      name = "loki";
      uid = 2113;
      logging.enable = true;
    };
    grafana = {
      name = "grafana";
      uid = 2114;
      logging.enable = true;
    };
    vector = {
      name = "vector";
      uid = 2117;
      managedState = false;
    };
}
