{ lib, pkgs, config, ... }:

let
  cfg = config.services.dailyLlmJournal;
  topology = config.my.infra.topology;
  defaultLokiHost =
    let
      lokiVm = config.my.infra.observability.lokiVM;
    in
    if lokiVm != "" && topology.domain != ""
    then "http://${lib.toLower lokiVm}.${topology.domain}:3100"
    else "http://nikki.lan:3100";

  lokiFragments =
    lib.concatStringsSep "\n" (
      map (query: ''
        echo "=== ${query.title} ==="
        ${pkgs.curl}/bin/curl -sSfG \
          --data-urlencode 'query=${query.expr}' \
          --data-urlencode "start=$START_NS" \
          --data-urlencode "end=$END_NS" \
          --data-urlencode "limit=${toString cfg.maxLinesPer}" \
          --data-urlencode "direction=backward" \
          "${cfg.lokiUrl}/loki/api/v1/query_range" |
          ${pkgs.jq}/bin/jq -r --argjson priorityMax ${if query.priorityMax == null then "null" else toString query.priorityMax} '
            def norm: tostring | gsub("[\t\r\n]+"; " ");

            def msg($o):
              ($o.MESSAGE? // $o.message? // "")
              | if type == "array" then implode
                else tostring
                end;

            [ .data.result[]? as $stream
              | $stream.values[]?
              | .[0] as $ts
              | (.[1] | fromjson?) as $o
              | select($o != null and ($o | type) == "object")
              | select(
                  $priorityMax == null
                  or (
                    ($o.PRIORITY? | tonumber?) != null
                    and (($o.PRIORITY | tonumber) <= $priorityMax)
                  )
                )
              | [
                  ($ts | tonumber),
                  (($o.vm // $stream.stream.vm // "-") | norm),
                  (($o.unit // $o.service // $o.SYSLOG_IDENTIFIER // "-") | norm),
                  (($o.PRIORITY // "-") | norm),
                  (msg($o) | norm)
                ]
            ]
            | sort_by(.[0]) | reverse[]
            | @tsv
          ' | cut -f2-
        echo
      '') cfg.logQueries
    );

  program = pkgs.writeShellApplication {
    name = "daily-llm-journal";

    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.curl
    ];

    text = ''
      set -euo pipefail

      DATE="$(date -u +%Y%m%d)"
      END_NS="$(date -u +%s)000000000"
      START_NS="$(date -u -d "${cfg.lookback}" +%s)000000000"
      OUTDIR="${cfg.outputDir}"
      INPUT="$OUTDIR/input-$DATE.txt"
      OUTPUT="$OUTDIR/summary-$DATE.txt"
      TMP="$(mktemp)"

      mkdir -p "$OUTDIR"

      {
        echo "Daily system log summary"
        echo "Window: last ${cfg.lookback}"
        echo "Generated (UTC): $(date -u --iso-8601=seconds)"
        echo
        ${lokiFragments}
      } > "$TMP"

      tail -n ${toString cfg.maxLinesTotal} "$TMP" > "$INPUT"
      rm -f "$TMP"
      RESPONSE="$(
        jq -n --rawfile content "$INPUT" '
          {
            model: "'"${cfg.model}"'",
            messages: [
              { role: "system", content:
                "Summarize the following system logs from the last 24 hours. " +
                "Identify anything requiring attention. " +
                "If the events are routine background noise, say so explicitly. " +
                "Be concise and operational. Make sure to have enough space for all services."
              },
              { role: "user", content: $content }
            ],
            temperature: '"${toString cfg.temperature}"',
            max_tokens: '"${toString cfg.maxTokens}"'
          }
        ' | curl -sSf --max-time 120 \
              -H 'Content-Type: application/json' \
              ${cfg.url}:${toString cfg.port}${cfg.endpoint} \
              --data-binary @-
      )"

      SUMMARY="$(${pkgs.jq}/bin/jq -r '.choices[0].message.content // empty' <<<"$RESPONSE")"

      if [ -z "$SUMMARY" ]; then
        echo "llama-server returned an invalid response" >&2
        exit 1
      fi

      {
        echo "Source: $INPUT"
        echo "Generated (UTC): $(date -u --iso-8601=seconds)"
        echo
        echo "$SUMMARY"
      } > "$OUTPUT"
    '';
  };

in
{
  options.services.dailyLlmJournal = {
    enable = lib.mkEnableOption "daily Loki-backed log summarization via llama-server";

    outputDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/dailyLlmJournal";
      description = "Directory for daily log inputs and summaries.";
    };

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = defaultLokiHost;
      description = "Base Loki URL used for LogQL query_range requests.";
    };

    lookback = lib.mkOption {
      type = lib.types.str;
      default = "24 hours ago";
      description = "Relative date string passed to `date -d` for the Loki query window start.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1";
      description = "llama-server OpenAI-compatible endpoint.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "/v1/chat/completions";
      description = "API endpoint";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 8080;
      description = "Port that runs llama-server.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "local-model";
      description = "Model name passed to llama-server.";
    };

    temperature = lib.mkOption {
      type = lib.types.float;
      default = 0.2;
    };

    maxTokens = lib.mkOption {
      type = lib.types.int;
      default = 2000;
    };

    maxLinesTotal = lib.mkOption {
      type = lib.types.int;
      default = 4000;
      description = "Hard cap on log lines fed to the LLM.";
    };

    maxLinesPer = lib.mkOption {
      type = lib.types.int;
      default = 200;
      description = "Hard cap on log lines per entry.";
    };

    logQueries = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          title = lib.mkOption {
            type = lib.types.str;
          };
          expr = lib.mkOption {
            type = lib.types.str;
            description = "LogQL expression queried from Loki.";
          };
          priorityMax = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Optional maximum journald PRIORITY to retain after parsing the Loki log payload.";
          };
        };
      });
      default = [
        {
          title = "PRIORITY: warning..emerg";
          expr = "{vm=~\".+\"}";
          priorityMax = 4;
        }
        {
          title = "SERVICE: vector";
          expr = "{service=\"vector\"}";
        }
      ];
      description = "Ordered list of Loki queries to include in the daily summary.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.dailyLlmJournal = {
      description = "Daily Loki log summary via llama-server";
      serviceConfig = {
        Type = "oneshot";
        User = "dailyLlmJournal";
        Group = "dailyLlmJournal";
        ExecStart = "${program}/bin/daily-llm-journal";
        # no retry loop for a daily job
        Restart = "on-failure";
        RestartSec = "360s";
        TimeoutStartSec = "5min";
      };
    };

    systemd.timers.dailyLlmJournal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
