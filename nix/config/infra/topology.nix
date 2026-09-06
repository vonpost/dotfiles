let endpoints = import ./endpoints.nix;
in
{
  domain = "lan";
  gatewayVM = "MAMORU";
  dnsVM = "DARE";
  hostIp = "10.10.10.99";
  wanMac = "02:00:00:00:00:90";
  wanBridge = "br0";
  # These are additional cross-network permissions. Same-network traffic is
  # handled by guest port openings; mgmt retains its existing blanket access.
  firewallRules = builtins.mapAttrs (name: routedFrom:
    endpoints.${name} // { inherit routedFrom; }) {
    dns_tcp = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" ];
    dns_udp = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" ];
    grafana_http = [  ];
    jellyfin = [ "UCHI" ];
    llama_server = [ "NIKKI" ];
    loki_http = [ "SOTO" "MAMORU" "OKAMI" "UCHI" "KAIZOKU" "DARE" ];
    node_exporter = [ "NIKKI" ];
    prowlarr = [  ];
    qbit = [ "UCHI" ];
    radarr = [ "SOTO" "KAIZOKU" ];
    sabnzbd = [ "UCHI" ];
    sonarr = [ "SOTO" "KAIZOKU" ];
    ssh = [  ];
    sshJellyfin = [ "SOTO" ];
    wolf_audio_ping = [  ];
    wolf_control = [  ];
    wolf_den = [  ];
    wolf_http = [  ];
    wolf_https = [  ];
    wolf_rtsp_setup = [  ];
    wolf_video_ping = [  ];
  };
  natRules = builtins.mapAttrs (name: externalPort:
    endpoints.${name} // { inherit externalPort; }) {
    battle_net = 1119;
    http = 80;
    https = 443;
    wireguard = 51822;
  };
  vlans = {
    mgmt = { id = 10; };
    srv = { id = 20; };
    dmz = { id = 30; };
  };
}
