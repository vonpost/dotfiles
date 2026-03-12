{
  SOTO = {
    machineId = "056de0236c6346f795b053689ca0468f";
    serviceMounts = [ "jellyfin" "jellyseerr" "acme" "geoipupdate" "nginx" "myaddr" ];
  };
  OKAMI = {
    machineId = "72a6254779a04b32976185f178e50ea0";
    serviceMounts = [ "wolf" "llama-cpp" "dailyLlmJournal" "jellyfin" ];
  };
  KAIZOKU = {
    machineId = "d7c79cedf4a24584ad28503505507e04";
    serviceMounts = [ "sabnzbd" "qbittorrent" "mullvad" ];
  };
  UCHI = {
    machineId = "3692d4ba23994c3a818e8d577625d60c";
    serviceMounts = [ "radarr" "sonarr" "recyclarr" "prowlarr" ];
  };
  MAMORU = {
    machineId = "d13cdd34121748a997cfa8d4e2355da3";
    serviceMounts = [ ];
    logProfiles = [ "firewall" ];
  };
  DARE = {
    machineId = "332120c0300145b2b762d1db81546caf";
    serviceMounts = [ "unbound" ];
  };
  NIKKI = {
    machineId = "5035f0c3bf5a4afc9e3ce44c4c96e2b4";
    serviceMounts = [ "loki" "grafana" "prometheus" ];
  };
}
