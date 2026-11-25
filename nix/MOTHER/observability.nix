{ config, ... }:
let
  topology = config.my.infra.topology;
  topo = import ../lib/infra-topology.nix { inherit topology; };
  lokiIp = topo.getPrimaryIp config.my.infra.observability.lokiVM;
  nodePort = topo.getPort "node_exporter";
in
{
  # Host evidence must survive a guest/monitoring outage. This does not replace
  # an independent off-host heartbeat or a crash console for a complete lockup.
  services.journald.extraConfig = ''
    Storage=persistent
    SyncIntervalSec=30s
  '';
  # Keep useful local evidence even if the monitoring VM stops. Ten-minute
  # samples left seven minutes unmeasured before the November 14 freeze.
  services.sysstat = {
    collect-frequency = "*:*:00";
    collect-args = "-S DISK 1 1";
  };
  services.prometheus.exporters.node = {
    enable = true;
    port = nodePort;
    listenAddress = topology.hostIp;
    enabledCollectors = [ "systemd" ];
  };
  networking.firewall.extraInputRules = ''
    iifname "br-mgmt" ip saddr ${lokiIp} ip daddr ${topology.hostIp} tcp dport ${toString nodePort} accept
  '';

  services.vector = {
    enable = true;
    journaldAccess = true;
    settings = {
      data_dir = "/var/lib/vector";
      sources.host_journal = {
        type = "journald";
        current_boot_only = false;
        # Older local records are retained for manual diagnosis, but Loki only
        # retains seven days. Avoid replaying years of journal on first startup.
        extra_args = [ "--since" "7 days ago" ];
      };
      transforms.host_events = {
        type = "filter";
        inputs = [ "host_journal" ];
        condition = ''
          ._TRANSPORT == "kernel" || ._PID == "1" ||
          starts_with(to_string(._SYSTEMD_UNIT) ?? "", "microvm@") ||
          starts_with(to_string(._SYSTEMD_UNIT) ?? "", "btrbk-") ||
          ._SYSTEMD_UNIT == "systemd-pstore.service"
        '';
      };
      transforms.host_labels = {
        type = "remap";
        inputs = [ "host_events" ];
        source = ''
          .vm = "${config.networking.hostName}"
          .service = if ._TRANSPORT == "kernel" { "kernel" } else { "host-system" }
          .source_type = "journald"
          .unit = to_string(._SYSTEMD_UNIT) ?? "kernel"
        '';
      };
      sinks.loki = {
        type = "loki";
        inputs = [ "host_labels" ];
        endpoint = "http://${lokiIp}:${toString (topo.getPort "loki_http")}";
        encoding.codec = "json";
        labels = {
          vm = "{{ vm }}"; service = "{{ service }}";
          source_type = "{{ source_type }}"; unit = "{{ unit }}";
        };
        # Loki runs on this host: retain evidence while its VM is unavailable.
        buffer = { type = "disk"; max_size = 268435488; when_full = "block"; };
      };
    };
  };
}
