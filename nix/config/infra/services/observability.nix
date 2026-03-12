{ config, lib, pkgs, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  topology = config.my.infra.topology;
  topo = import ../../../lib/infra-topology.nix { inherit topology; };
  grafanaHost = "${lib.toLower svc.hostname}.${topology.domain}";
  scrapeTargets =
    map
      (vmName: {
        targets = [ "${topo.getIp vmName (lib.head topology.vms.${vmName}.assignedVlans)}:9100" ];
        labels.vm = vmName;
      })
      (builtins.filter
        (vmName: builtins.elem "node_exporter" (topology.vms.${vmName}.provides or [ ]))
        (builtins.attrNames topology.vms));

  starterDashboard = pkgs.writeText "homelab-logs-dashboard.json" (builtins.toJSON {
    annotations.list = [ ];
    editable = true;
    panels = [
      {
        datasource = {
          type = "loki";
          uid = "loki";
        };
        gridPos = {
          h = 8;
          w = 24;
          x = 0;
          y = 0;
        };
        id = 1;
        options = {
          dedupStrategy = "none";
          enableLogDetails = true;
          showLabels = true;
          sortOrder = "Descending";
        };
        targets = [
          {
            expr = "{vm=~\".+\"}";
            queryType = "range";
            refId = "A";
          }
        ];
        title = "All Logs";
        type = "logs";
      }
      {
        datasource = {
          type = "loki";
          uid = "loki";
        };
        fieldConfig = {
          defaults = {
            color.mode = "thresholds";
            thresholds = {
              mode = "absolute";
              steps = [
                {
                  color = "green";
                  value = null;
                }
              ];
            };
          };
          overrides = [ ];
        };
        gridPos = {
          h = 6;
          w = 8;
          x = 0;
          y = 8;
        };
        id = 2;
        options = {
          colorMode = "value";
          graphMode = "none";
          justifyMode = "auto";
          orientation = "auto";
          reduceOptions = {
            calcs = [ "lastNotNull" ];
            fields = "";
            values = false;
          };
          textMode = "auto";
        };
        targets = [
          {
            expr = "sum(count_over_time({vm=~\".+\"}[5m]))";
            queryType = "instant";
            refId = "A";
          }
        ];
        title = "Log Lines Last 5m";
        type = "stat";
      }
      {
        datasource = {
          type = "loki";
          uid = "loki";
        };
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
          };
          overrides = [ ];
        };
        gridPos = {
          h = 6;
          w = 16;
          x = 8;
          y = 8;
        };
        id = 3;
        options = {
          legend = {
            calcs = [ ];
            displayMode = "list";
            placement = "bottom";
          };
          tooltip = {
            mode = "single";
            sort = "none";
          };
        };
        targets = [
          {
            expr = "sum by (service) (count_over_time({service=~\".+\"}[5m]))";
            queryType = "range";
            refId = "A";
          }
        ];
        title = "Logs by Service";
        type = "timeseries";
      }
    ];
    schemaVersion = 39;
    tags = [ "homelab" "loki" ];
    templating.list = [ ];
    time = {
      from = "now-6h";
      to = "now";
    };
    timezone = "browser";
    title = "Homelab Logs";
    uid = "homelab-logs";
    version = 1;
  });

  metricsDashboard = pkgs.writeText "homelab-metrics-dashboard.json" (builtins.toJSON {
    annotations.list = [ ];
    editable = true;
    panels = [
      {
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
            unit = "percent";
          };
          overrides = [ ];
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 0;
        };
        id = 1;
        options = {
          legend = {
            calcs = [ ];
            displayMode = "list";
            placement = "bottom";
          };
          tooltip = {
            mode = "single";
            sort = "none";
          };
        };
        targets = [
          {
            expr = "100 * (1 - avg by (vm) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))";
            refId = "A";
          }
        ];
        title = "CPU Usage";
        type = "timeseries";
      }
      {
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
            unit = "percent";
          };
          overrides = [ ];
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 0;
        };
        id = 2;
        options = {
          legend = {
            calcs = [ ];
            displayMode = "list";
            placement = "bottom";
          };
          tooltip = {
            mode = "single";
            sort = "none";
          };
        };
        targets = [
          {
            expr = "100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))";
            refId = "A";
          }
        ];
        title = "Memory Usage";
        type = "timeseries";
      }
      {
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
            unit = "decgbytes";
          };
          overrides = [ ];
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 0;
          y = 8;
        };
        id = 3;
        options = {
          legend = {
            calcs = [ ];
            displayMode = "list";
            placement = "bottom";
          };
          tooltip = {
            mode = "single";
            sort = "none";
          };
        };
        targets = [
          {
            expr = "node_filesystem_avail_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay|squashfs\"}";
            refId = "A";
          }
        ];
        title = "Root Filesystem Free";
        type = "timeseries";
      }
      {
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        fieldConfig = {
          defaults = {
            color.mode = "palette-classic";
          };
          overrides = [ ];
        };
        gridPos = {
          h = 8;
          w = 12;
          x = 12;
          y = 8;
        };
        id = 4;
        options = {
          legend = {
            calcs = [ ];
            displayMode = "list";
            placement = "bottom";
          };
          tooltip = {
            mode = "single";
            sort = "none";
          };
        };
        targets = [
          {
            expr = "up{job=\"node\"}";
            refId = "A";
          }
        ];
        title = "Exporter Up";
        type = "timeseries";
      }
    ];
    schemaVersion = 39;
    tags = [ "homelab" "prometheus" ];
    templating.list = [ ];
    time = {
      from = "now-6h";
      to = "now";
    };
    timezone = "browser";
    title = "Homelab Metrics";
    uid = "homelab-metrics";
    version = 1;
  });

  dashboardsPath = pkgs.linkFarm "grafana-dashboards" [
    {
      name = "homelab-logs.json";
      path = starterDashboard;
    }
    {
      name = "homelab-metrics.json";
      path = metricsDashboard;
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
            http_listen_port = 3100;
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
            http_port = 3000;
            domain = grafanaHost;
          };
          security = {
            # Bootstrap-only default. Replace with a file-provider-backed secret.
            secret_key = "grafana-bootstrap-secret-key-change-me";
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
              url = "http://127.0.0.1:3100";
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
