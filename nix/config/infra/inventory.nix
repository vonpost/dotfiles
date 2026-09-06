# Order preserves the existing host autostart list. Network policy is in
# topology.nix; all per-VM identity, resources and assignments live here.
[
  {
    name = "UCHI";
    id = 20;
    assignedVlans = [ "srv" ];
    primaryVlan = "srv";
    ipv6 = false;
    vcpu = 2;
    mem = 3000;
    services = [ "radarr" "sonarr" "recyclarr" "prowlarr" ];
    provides = [ "ssh" "sonarr" "radarr" "prowlarr" "node_exporter" ];
  }
  {
    name = "SOTO";
    id = 25;
    assignedVlans = [ "dmz" ];
    primaryVlan = "dmz";
    ipv6 = false;
    vcpu = 8;
    mem = 8000;
    services = [ "jellyfin" "seerr" "acme" "geoipupdate" "nginx" "myaddr" ];
    provides = [ "ssh" "jellyfin" "node_exporter" ];
    portForward = [ "http" "https" ];
  }
  {
    name = "KAIZOKU";
    id = 15;
    assignedVlans = [ "srv" ];
    primaryVlan = "srv";
    ipv6 = true;
    vcpu = 2;
    mem = 3000;
    services = [ "sabnzbd" "qbittorrent" "mullvad" ];
    provides = [ "ssh" "qbit" "sabnzbd" "node_exporter" ];
  }
  {
    name = "DARE";
    id = 53;
    assignedVlans = [ "srv" ];
    primaryVlan = "srv";
    ipv6 = false;
    services = [ "unbound" ];
    provides = [ "dns_tcp" "dns_udp" "ssh" "node_exporter" ];
  }
  {
    name = "OKAMI";
    id = 30;
    assignedVlans = [ "srv" ];
    primaryVlan = "srv";
    ipv6 = true;
    vcpu = 12;
    mem = 22000;
    services = [ "wolf" "llama-cpp" "transcode-worker" ];
    provides = [ "ssh" "sshJellyfin" "wolf_http" "wolf_https" "wolf_control" "wolf_rtsp_setup" "wolf_video_ping" "wolf_audio_ping" "llama_server" "wolf_den" "node_exporter" ];
    portForward = [ "battle_net" ];
    modules = [ ./vms/OKAMI.nix ];
  }
  {
    name = "MAMORU";
    id = 10;
    assignedVlans = [ "mgmt" "srv" "dmz" ];
    primaryVlan = "mgmt";
    ipv6 = true;
    vcpu = 4;
    mem = 2148;
    logProfiles = [ "firewall" ];
    provides = [ "node_exporter" ];
  }
  {
    name = "NIKKI";
    id = 35;
    assignedVlans = [ "mgmt" ];
    primaryVlan = "mgmt";
    ipv6 = false;
    vcpu = 2;
    mem = 3000;
    services = [ "loki" "grafana" "prometheus" "logDigest" ];
    provides = [ "ssh" "loki_http" "grafana_http" "node_exporter" ];
  }
]
