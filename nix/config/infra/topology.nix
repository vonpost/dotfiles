{
  domain = "lan";
  gatewayVM = "MAMORU";
  dnsVM = "DARE";
  hostIp = "10.10.10.99";
  wanMac = "02:00:00:00:00:90";
  wanBridge = "br0";
  firewallRules = {
    dns_udp = { port = 53; proto = "udp"; allowFrom = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" ]; };
    dns_tcp = { port = 53; proto = "tcp"; allowFrom = [ "OKAMI" "SOTO" "UCHI" "KAIZOKU" ]; };
    sonarr = { port = 8989; proto = "tcp"; allowFrom = [ "SOTO" "KAIZOKU" ]; };
    radarr = { port = 7878; proto = "tcp"; allowFrom = [ "SOTO" "KAIZOKU" ]; };
    prowlarr = { port = 9696; proto = "tcp"; allowFrom = [ ]; };
    qbit = { port = 8080; proto = "tcp"; allowFrom = [ "UCHI" ]; };
    sabnzbd = { port = 1337; proto = "tcp"; allowFrom = [ "UCHI" ]; };
    jellyfin = { port = 8096; proto = "tcp"; allowFrom = [ "UCHI" ]; };
    ssh = { port = 22; proto = "tcp"; allowFrom = [ ]; };
    sshJellyfin = { port = 22; proto = "tcp"; allowFrom = [ "SOTO" ]; };
    wolf_https = { port = 47984; proto = "tcp"; allowFrom = [ ]; };
    wolf_http = { port = 47989; proto = "tcp"; allowFrom = [ ]; };
    wolf_control = { port = 47999; proto = "udp"; allowFrom = [ ]; };
    wolf_rtsp_setup = { port = 48010; proto = "tcp"; allowFrom = [ ]; };
    wolf_video_ping = { port = 48100; proto = "udp"; allowFrom = [ ]; };
    wolf_audio_ping = { port = 48200; proto = "udp"; allowFrom = [ ]; };
    wolf_den = { port = 8080; proto = "tcp"; allowFrom = [ ]; };
    llama_server = { port = 8888; proto = "tcp"; allowFrom = [ ]; };
  };
  natRules = {
    http = { port = 80; proto = "tcp"; externalPort = 80; };
    wireguard = { port = 51820; proto = "udp"; externalPort = 51822; };
    https = { port = 443; proto = "tcp"; externalPort = 443; };
    battle_net = { port = 1119; proto = "tcp"; externalPort = 1119; };
  };
  vms = {
    MAMORU = {
      id = 10;
      assignedVlans = [ "mgmt" "srv" "dmz" ];
      ipv6 = true;
      provides = [ ];
      portForward = [ ];
    };
    KAIZOKU = {
      id = 15;
      assignedVlans = [ "srv" ];
      ipv6 = true;
      provides = [ "ssh" "qbit" "sabnzbd" ];
      portForward = [ ];
    };
    UCHI = {
      id = 20;
      assignedVlans = [ "srv" ];
      ipv6 = false;
      provides = [ "ssh" "sonarr" "radarr" "prowlarr" ];
      portForward = [ ];
    };
    DARE = {
      id = 53;
      assignedVlans = [ "srv" ];
      ipv6 = false;
      provides = [ "dns_tcp" "dns_udp" "ssh" ];
      portForward = [ ];
    };
    SOTO = {
      id = 25;
      assignedVlans = [ "dmz" ];
      ipv6 = false;
      provides = [ "ssh" "jellyfin" ];
      portForward = [ "http" "https" ];
    };
    OKAMI = {
      id = 30;
      assignedVlans = [ "srv" ];
      ipv6 = true;
      provides = [ "ssh" "sshJellyfin" "wolf_http" "wolf_https" "wolf_control" "wolf_rtsp_setup" "wolf_video_ping" "wolf_audio_ping" "llama_server" "wolf_den" ];
      portForward = [ "battle_net" ];
    };
  };
  vlans = {
    mgmt = { id = 10; };
    srv = { id = 20; };
    dmz = { id = 30; };
  };
}
