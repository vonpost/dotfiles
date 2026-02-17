{
    mullvad = { name = "mullvad"; uid = 0; unit = "mullvad-daemon"; user = "root"; hasCacheDir = true; };
    prowlarr = { name = "prowlarr"; uid = 2101; };
    radarr = {
      name = "radarr";
      uid = 2102;
      downloadsGroup = true;
      mediaGroup = true;
      hasMediaDir = true;
    };
    sonarr = {
      name = "sonarr";
      uid = 2103;
      downloadsGroup = true;
      mediaGroup = true;
      hasMediaDir = true;
    };
    recyclarr = {
      name = "recyclarr";
      unit = "recyclarr";
      managedState = false;
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
      secrets = {
        jellyfin_transcode_ssh_key = {
          source = "/run/secrets/ssh/jellyfin";
        };
      };
    };
    jellyseerr = { name = "jellyseerr"; uid = 2105; mediaGroup = true; };
    sabnzbd = {
      name = "sabnzbd";
      uid = 2106;
      downloadsGroup = true;
      hasDownloadsDir = true;
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
    qbittorrent = { name = "qbittorrent"; uid = 2107; downloadsGroup = true; hasDownloadsDir = true; bindTarget = "qBittorrent"; };
    wolf = { name = "wolf"; uid = 2108; };
    "llama-cpp" = { name = "llama-cpp"; uid = 2109; };
    dailyLlmJournal = { name = "dailyLlmJournal"; uid = 2110; };
    acme = { name = "acme"; uid = 2111; unit = "acme-setup"; };
    geoipupdate = {
      name = "geoipupdate";
      uid = 2112;
      user = "geoip";
      unit = "geoipupdate";
      secrets = {
        maxmind_license_key = {
          source = "/run/secrets/maxmind/license_key";
        };
      };
    };
    myaddr = {
      name = "myaddr";
      unit = "myaddr-update";
      managedState = false;
      secrets = {
        myaddr_api_key = {
          source = "/run/secrets/myaddr/api_key";
        };
      };
    };
}
