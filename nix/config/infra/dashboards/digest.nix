{ hostname }:
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
        h = 10;
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
          expr = "{vm=\"${hostname}\", service=\"logDigest\", kind=\"summary\"}";
          queryType = "range";
          refId = "A";
        }
      ];
      title = "Overnight Digests and Investigation Follow-ups";
      type = "logs";
    }
    {
      datasource = {
        type = "loki";
        uid = "loki";
      };
      gridPos = {
        h = 10;
        w = 24;
        x = 0;
        y = 10;
      };
      id = 2;
      options = {
        dedupStrategy = "none";
        enableLogDetails = true;
        showLabels = true;
        sortOrder = "Descending";
      };
      targets = [
        {
          expr = "{vm=\"${hostname}\", service=\"logDigest\", source_type=\"journald\"}";
          queryType = "range";
          refId = "A";
        }
      ];
      title = "Digest Run Log (GPU budget, tool calls, warnings)";
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
        h = 5;
        w = 8;
        x = 0;
        y = 20;
      };
      id = 3;
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
          expr = "sum(count_over_time({vm=\"${hostname}\", service=\"logDigest\", kind=\"summary\"}[7d]))";
          queryType = "instant";
          refId = "A";
        }
      ];
      title = "Digests Last 7d";
      type = "stat";
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
        h = 5;
        w = 8;
        x = 8;
        y = 20;
      };
      id = 4;
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
          expr = "sum(count_over_time({vm=\"${hostname}\", service=\"logDigest\"} |~ `synthesis failed|FAILED` [7d]))";
          queryType = "instant";
          refId = "A";
        }
      ];
      title = "Failed Runs Last 7d";
      type = "stat";
    }
  ];
  schemaVersion = 39;
  tags = [ "homelab" "loki" "digest" ];
  templating.list = [ ];
  # Bounded by Loki's 168h retention. The durable copies live on disk in the
  # logDigest state directory, which is where to look for anything older.
  time = {
    from = "now-7d";
    to = "now";
  };
  timezone = "browser";
  title = "Homelab Digest";
  uid = "homelab-digest";
  version = 1;
}
