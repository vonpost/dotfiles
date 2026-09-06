# Transport/port definitions shared by service settings and network policy.
{
  dns_tcp = { port = 53; proto = "tcp"; };
  dns_udp = { port = 53; proto = "udp"; };
  grafana_http = { port = 3000; proto = "tcp"; };
  jellyfin = { port = 8096; proto = "tcp"; };
  llama_server = { port = 8888; proto = "tcp"; };
  loki_http = { port = 3100; proto = "tcp"; };
  node_exporter = { port = 9100; proto = "tcp"; };
  prowlarr = { port = 9696; proto = "tcp"; };
  qbit = { port = 8080; proto = "tcp"; };
  radarr = { port = 7878; proto = "tcp"; };
  sabnzbd = { port = 1337; proto = "tcp"; };
  sonarr = { port = 8989; proto = "tcp"; };
  ssh = { port = 22; proto = "tcp"; };
  sshJellyfin = { port = 22; proto = "tcp"; };
  wolf_audio_ping = { port = 48200; proto = "udp"; };
  wolf_control = { port = 47999; proto = "udp"; };
  wolf_den = { port = 8080; proto = "tcp"; };
  wolf_http = { port = 47989; proto = "tcp"; };
  wolf_https = { port = 47984; proto = "tcp"; };
  wolf_rtsp_setup = { port = 48010; proto = "tcp"; };
  wolf_video_ping = { port = 48100; proto = "udp"; };
  battle_net = { port = 1119; proto = "tcp"; };
  http = { port = 80; proto = "tcp"; };
  https = { port = 443; proto = "tcp"; };
  wireguard = { port = 51820; proto = "udp"; };
}
