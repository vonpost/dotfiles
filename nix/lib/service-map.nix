{
    mullvad = { name="mullvad"; uid=0; unit="mullvad-daemon"; user="root"; hasCacheDir=true; };
    prowlarr = { name="prowlarr"; uid=2101; };
    radarr = { name="radarr"; uid=2102; downloadsGroup = true; mediaGroup=true; hasMediaDir=true; };
    sonarr = { name="sonarr"; uid=2103; downloadsGroup = true; mediaGroup=true; hasMediaDir=true; };
    jellyfin = { name = "jellyfin"; uid=2104; mediaGroup = true; hasCacheDir= true; };
    jellyseerr = { name="jellyseerr"; uid=2105; };
    sabnzbd = { name="sabnzbd"; uid=2106; downloadsGroup = true; hasDownloadsDir=true; };
    qbittorrent = { name="qbittorrent"; uid=2107; downloadsGroup = true; hasDownloadsDir=true; bindTarget="qBittorrent";};
    wolf = { name="wolf"; uid=2108; };
    "llama-cpp" = { name="llama-cpp"; uid=2109; };
    dailyLlmJournal = { name="dailyLlmJournal"; uid=2110; };
    acme = { name="acme"; uid=2111; unit="acme-setup"; };
    geoipupdate={name="geoipupdate"; uid=2112; user="geoip"; unit="geoipupdate"; };
}
