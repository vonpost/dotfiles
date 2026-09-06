{
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
}
