{ config, lib, pkgs, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  topology = config.my.infra.topology;
  topo = import ../../../lib/infra-topology.nix { inherit topology; };
  grafanaHost = "${lib.toLower svc.hostname}.${topology.domain}";
  scrapeTargets =
    map
      (vmName: {
        targets = [ "${topo.getPrimaryIp vmName}:${toString (topo.getPort "node_exporter")}" ];
        labels.vm = vmName;
      })
      (builtins.filter
        (vmName: builtins.elem "node_exporter" (topology.vms.${vmName}.provides or [ ]))
        (builtins.attrNames topology.vms));

  starterDashboard = pkgs.writeText "homelab-logs-dashboard.json" (builtins.toJSON (import ../dashboards/logs.nix));

  metricsDashboard = pkgs.writeText "homelab-metrics-dashboard.json" (builtins.toJSON (import ../dashboards/metrics.nix));

  digestDashboard = pkgs.writeText "homelab-digest-dashboard.json" (builtins.toJSON (import ../dashboards/digest.nix { hostname = svc.hostname; }));

  dashboardsPath = pkgs.linkFarm "grafana-dashboards" [
    {
      name = "homelab-logs.json";
      path = starterDashboard;
    }
    {
      name = "homelab-metrics.json";
      path = metricsDashboard;
    }
    {
      name = "homelab-digest.json";
      path = digestDashboard;
    }
  ];
in
{
  config = lib.mkMerge [
    (lib.mkIf (svc.hasService "prometheus") {
      services.prometheus = {
        enable = true;
        stateDir = "prometheus";
        listenAddress = "127.0.0.1";
        retentionTime = "7d";
        globalConfig = {
          scrape_interval = "15s";
          evaluation_interval = "15s";
        };
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = scrapeTargets;
          }
        ];
      };
    })

    (lib.mkIf (svc.hasService "loki") {
      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_address = "0.0.0.0";
            http_listen_port = svc.getPort "loki_http";
            # Loki's own info-level housekeeping was 55k lines/day, over 60% of
            # all fleet log volume, and crowded real events out of every query.
            log_level = "warn";
          };
          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
          };
          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          storage_config.filesystem.directory = "/var/lib/loki/chunks";
          compactor = {
            working_directory = "/var/lib/loki/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          limits_config.retention_period = "168h";
        };
      };
    })

    (lib.mkIf (svc.hasService "grafana") {
      services.grafana = {
        enable = true;
        settings = {
          analytics.reporting_enabled = false;
          server = {
            http_addr = "0.0.0.0";
            http_port = svc.getPort "grafana_http";
            domain = grafanaHost;
          };
          security = {
            secret_key = "$__file{/run/credentials/grafana.service/grafana_secret_key}";
          };
          users = {
            allow_sign_up = false;
          };
        };
        provision = {
          enable = true;
          datasources.settings.datasources = [
            {
              name = "Loki";
              type = "loki";
              uid = "loki";
              access = "proxy";
              url = "http://127.0.0.1:${toString (svc.getPort "loki_http")}";
              isDefault = true;
            }
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:9090";
            }
          ];
          dashboards.settings.providers = [
            {
              name = "Homelab";
              options.path = dashboardsPath;
              orgId = 1;
              type = "file";
            }
          ];
        };
      };
    })
  ];
}
