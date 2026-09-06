{
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
}
