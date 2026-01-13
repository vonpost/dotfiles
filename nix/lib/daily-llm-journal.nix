{ lib, pkgs, config, ... }:

let
  cfg = config.services.dailyLlmJournal;

  journalFragments =
    lib.concatStringsSep "\n" (
      map (slice: ''
        echo "=== ${slice.title} ==="
        ${pkgs.systemd}/bin/journalctl -m --since "24 hours ago" ${slice.filter} \
          -o json |
          ${pkgs.jq}/bin/jq -nRr '
            def norm: tostring | gsub("[\t\r\n]+"; " ");

            def msg($o):
              ($o.MESSAGE? // "")
              | if type == "array" then implode
                else tostring
                end;

            inputs
            | fromjson?                         # each line -> JSON (or null)
            | select(type == "object") as $o    # only objects
            | [ ($o._SYSTEMD_UNIT // $o.SYSLOG_IDENTIFIER // "-") | norm,
                ($o.PRIORITY // "-") | norm,
                (msg($o)) | norm ]
            | @tsv
          ' | tail -n ${toString cfg.maxLinesPer}
        echo
      '') cfg.logSlices
    );

  program = pkgs.writeShellApplication {
    name = "daily-llm-journal";

    runtimeInputs = [
      pkgs.systemd
      pkgs.coreutils
      pkgs.jq
      pkgs.curl
    ];

    text = ''
      set -euo pipefail

      DATE="$(date -u +%Y%m%d)"
      OUTDIR="${cfg.outputDir}"
      INPUT="$OUTDIR/input-$DATE.txt"
      OUTPUT="$OUTDIR/summary-$DATE.txt"
      TMP="$(mktemp)"

      mkdir -p "$OUTDIR"

      {
        echo "Daily system log summary"
        echo "Window: last 24 hours"
        echo "Generated (UTC): $(date -u --iso-8601=seconds)"
        echo
        ${journalFragments}
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
    enable = lib.mkEnableOption "daily journal summarization via llama-server";

    outputDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/daily-llm-logs";
      description = "Directory for daily log inputs and summaries.";
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

    logSlices = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          title = lib.mkOption {
            type = lib.types.str;
          };
          filter = lib.mkOption {
            type = lib.types.str;
            description = "journalctl filter arguments.";
          };
        };
      });
      default = [
        {
          title = "PRIORITY: warning..emerg";
          filter = "-p warning..emerg";
        }
        {
          title = "UNIT: sshd.service (info+)";
          filter = "_SYSTEMD_UNIT=sshd.service";
        }
      ];
      description = "Ordered list of journalctl slices to include.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.outputDir} 0750 llm-summarizer systemd-journal - -"
    ];

    users.users.llm-summarizer = {
      isSystemUser = true;
      group = "systemd-journal";
    };

    systemd.services.dailyLlmJournal = {
      description = "Daily journal summary via llama-server";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${program}/bin/daily-llm-journal";
        User = "llm-summarizer";
        Group = "systemd-journal";
        UMask = "0027";

        # security hardening
        CapabilityBoundingSet = "";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "full";
        ProtectHome = true;
        ReadWriteDirectories = cfg.outputDir;

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
