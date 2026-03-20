{ lib, pkgs, config, ... }:

let
  cfg = config.services.logDigest;
  topology = config.my.infra.topology;
  serviceDef = config.my.infra.services.logDigest or { uid = 2110; };
  digestVm = config.networking.hostName;
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
          ${pkgs.jq}/bin/jq -r \
            --argjson priorityMax ${if query.priorityMax == null then "null" else toString query.priorityMax} \
            --argjson topRepeats ${toString cfg.topRepeatsPerQuery} \
            --argjson sampleLines ${toString cfg.sampleLinesPerQuery} '
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
              | (msg($o) | norm) as $message
              | select($message != "")
              | {
                  ts: ($ts | tonumber),
                  vm: (($o.vm // $stream.stream.vm // "-") | norm),
                  unit: (($o.unit // $o.service // $o.SYSLOG_IDENTIFIER // "-") | norm),
                  priority: (($o.PRIORITY // "-") | norm),
                  message: $message
                }
            ] as $entries
            | if ($entries | length) == 0 then
                "No matching log lines."
              else
                [
                  "Total lines: \($entries | length)",
                  "Unique message signatures: \($entries | map(.unit + "\u0000" + .message) | unique | length)",
                  (
                    ($entries | map(select(.priority != "-") | .priority)) as $priorities
                    | if ($priorities | length) == 0 then
                        "Priority counts: none"
                      else
                        "Priority counts:\n"
                        + ($priorities
                           | group_by(.)
                           | map("  p=\(.[0]): \(length)")
                           | join("\n"))
                      end
                  ),
                  "Top repeated messages:",
                  (
                    $entries
                    | group_by(.vm + "\u0000" + .unit + "\u0000" + .priority + "\u0000" + .message)
                    | map({
                        count: length,
                        vm: .[0].vm,
                        unit: .[0].unit,
                        priority: .[0].priority,
                        message: .[0].message
                      })
                    | sort_by(-.count, .vm, .unit, .message)
                    | .[:$topRepeats]
                    | if length == 0 then
                        "  (none)"
                      else
                        map("  [x\(.count)] \(.vm) \(.unit) p=\(.priority) \(.message)")
                        | join("\n")
                      end
                  ),
                  "Recent samples:",
                  (
                    $entries
                    | sort_by(.ts) | reverse
                    | .[:$sampleLines]
                    | if length == 0 then
                        "  (none)"
                      else
                        map("  \(.vm) \(.unit) p=\(.priority) \(.message)")
                        | join("\n")
                      end
                  )
                ]
                | join("\n")
              end
          '
        echo
      '') cfg.logQueries
    );

  program = pkgs.writeShellApplication {
    name = "log-digest";

    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.curl
      pkgs.gnugrep
    ];

    text = ''
      set -euo pipefail

      NOW_NS="$(date -u +%s)000000000"
      END_NS="$(date -u +%s)000000000"
      START_NS="$(date -u -d "${cfg.lookback}" +%s)000000000"
      MEMORY_START_NS="$(date -u -d "${cfg.memoryLookback}" +%s)000000000"
      INPUT="$(mktemp)"
      SUMMARY_TMP="$(mktemp)"
      MEMORY_TMP="$(mktemp)"
      PREV_SUMMARY_TMP="$(mktemp)"
      SUMMARY_REQ="$(mktemp)"
      MEMORY_REQ="$(mktemp)"
      RESPONSE_TMP="$(mktemp)"
      TMP="$(mktemp)"

      cleanup() {
        rm -f "$INPUT" "$SUMMARY_TMP" "$MEMORY_TMP" "$PREV_SUMMARY_TMP" \
          "$SUMMARY_REQ" "$MEMORY_REQ" "$RESPONSE_TMP" "$TMP"
      }
      trap cleanup EXIT

      fetch_latest_digest() {
        local kind="$1"
        local out="$2"
        local max_chars="$3"

        ${pkgs.curl}/bin/curl -sSfG \
          --data-urlencode "query={vm=\"${digestVm}\",service=\"logDigest\",kind=\"''${kind}\"}" \
          --data-urlencode "start=$MEMORY_START_NS" \
          --data-urlencode "end=$END_NS" \
          --data-urlencode "limit=1" \
          --data-urlencode "direction=backward" \
          "${cfg.lokiUrl}/loki/api/v1/query_range" |
          ${pkgs.jq}/bin/jq -r '
            .data.result[0].values[0][1] // empty
          ' | head -c "$max_chars" > "$out"
      }

      push_digest() {
        local kind="$1"
        local file="$2"

        jq -n \
          --arg ts "$NOW_NS" \
          --arg vm "${digestVm}" \
          --arg kind "$kind" \
          --rawfile content "$file" '
          {
            streams: [
              {
                stream: {
                  vm: $vm,
                  service: "logDigest",
                  kind: $kind,
                  source_type: "digest"
                },
                values: [[ $ts, $content ]]
              }
            ]
          }
          ' | ${pkgs.curl}/bin/curl -sSf \
                -H 'Content-Type: application/json' \
                "${cfg.lokiUrl}/loki/api/v1/push" \
                --data-binary @- > /dev/null
      }

      is_retryable_llama_error() {
        local file="$1"

        ${pkgs.jq}/bin/jq -e '
          .error.type? == "exceed_context_size_error"
        ' "$file" > /dev/null 2>&1
      }

      request_llama() {
        local request_file="$1"
        local stage="$2"
        local attempts=0
        local max_attempts=$((1 + ${toString cfg.gpuBusyRetryCount}))

        while [ "$attempts" -lt "$max_attempts" ]; do
          local http_code
          http_code="$(${pkgs.curl}/bin/curl -sS --max-time 120 \
            -H 'Content-Type: application/json' \
            -o "$RESPONSE_TMP" \
            -w '%{http_code}' \
            "${cfg.url}:${toString cfg.port}${cfg.endpoint}" \
            --data-binary "@$request_file")"

          if [ "$http_code" = "200" ]; then
            cat "$RESPONSE_TMP"
            return 0
          fi

          echo "llama-server response during $stage (HTTP $http_code):" >&2
          cat "$RESPONSE_TMP" >&2

          if is_retryable_llama_error "$RESPONSE_TMP" && [ "$attempts" -lt $((max_attempts - 1)) ]; then
            echo "llama-server returned a retryable context-size error during $stage, retrying in ${cfg.gpuBusyRetryDelay}" >&2
            sleep "${cfg.gpuBusyRetryDelay}"
            attempts=$((attempts + 1))
            continue
          fi

          echo "llama-server request failed during $stage (HTTP $http_code)" >&2
          return 1
        done
      }

      {
        echo "Daily system log summary"
        echo "Window: last ${cfg.lookback}"
        echo "Generated (UTC): $(date -u --iso-8601=seconds)"
        echo
        ${lokiFragments}
      } > "$TMP"

      tail -n ${toString cfg.maxLinesTotal} "$TMP" > "$INPUT"

      fetch_latest_digest memory "$MEMORY_TMP" ${toString cfg.rollingMemoryMaxChars}
      fetch_latest_digest summary "$PREV_SUMMARY_TMP" ${toString cfg.previousSummaryMaxChars}

      jq -n \
        --rawfile content "$INPUT" \
        --rawfile memory "$MEMORY_TMP" \
        --rawfile previous "$PREV_SUMMARY_TMP" '
        {
          model: "'"${cfg.model}"'",
          messages: [
            { role: "system", content:
              "You are producing a concise operational digest for a homelab. " +
              "Use the rolling memory to avoid repeating stable known issues or routine noise unless something materially changed today. " +
              "The current logs are already pre-aggregated into counts, repeated-message summaries, and a few recent samples per query. " +
              "Focus on changes, actionable issues, and anything newly resolved. " +
              "Output short markdown with these sections when relevant: New Issues, Ongoing Issues, Resolved/Changed, Routine Noise."
            },
            { role: "user", content:
              "Rolling memory:\\n" +
              (if ($memory | length) > 0 then $memory else "(none)\\n" end) +
              "\\nPrevious summary:\\n" +
              (if ($previous | length) > 0 then $previous else "(none)\\n" end) +
              "\\nCurrent logs:\\n" + $content
            }
          ],
          temperature: '"${toString cfg.temperature}"',
          max_tokens: '"${toString cfg.summaryMaxTokens}"'
        }
      ' > "$SUMMARY_REQ"

      SUMMARY_RESPONSE="$(request_llama "$SUMMARY_REQ" "summary generation")"

      SUMMARY="$(${pkgs.jq}/bin/jq -r '.choices[0].message.content // empty' <<<"$SUMMARY_RESPONSE")"

      if [ -z "$SUMMARY" ]; then
        echo "llama-server returned an invalid summary response" >&2
        exit 1
      fi

      printf 'Generated (UTC): %s\n\n%s\n' "$(date -u --iso-8601=seconds)" "$SUMMARY" > "$SUMMARY_TMP"

      jq -n \
        --rawfile previous "$MEMORY_TMP" \
        --rawfile summary "$SUMMARY_TMP" '
        {
          model: "'"${cfg.model}"'",
          messages: [
            { role: "system", content:
              "Maintain a compact rolling memory for future daily log digests. " +
              "Keep only durable context: ongoing issues, recurring benign noise, and recent changes that may still matter tomorrow. " +
              "Drop stale one-off incidents that are fully resolved. " +
              "Output concise markdown under the headings Active Issues, Known Noise, and Watch Items."
            },
            { role: "user", content:
              "Previous rolling memory:\\n" +
              (if ($previous | length) > 0 then $previous else "(none)\\n" end) +
              "\\nSummary for today:\\n" + $summary
            }
          ],
          temperature: '"${toString cfg.temperature}"',
          max_tokens: '"${toString cfg.memoryMaxTokens}"'
        }
      ' > "$MEMORY_REQ"

      MEMORY_RESPONSE="$(request_llama "$MEMORY_REQ" "rolling memory compaction")"

      UPDATED_MEMORY="$(${pkgs.jq}/bin/jq -r '.choices[0].message.content // empty' <<<"$MEMORY_RESPONSE")"

      if [ -z "$UPDATED_MEMORY" ]; then
        echo "llama-server returned an invalid rolling memory response" >&2
        exit 1
      fi

      printf '%s\n' "$UPDATED_MEMORY" | head -c ${toString cfg.rollingMemoryMaxChars} > "$MEMORY_TMP"

      push_digest summary "$SUMMARY_TMP"
      push_digest memory "$MEMORY_TMP"
    '';
  };

in
{
  options.services.logDigest = {
    enable = lib.mkEnableOption "rolling Loki-backed log digest via llama-server";

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

    memoryLookback = lib.mkOption {
      type = lib.types.str;
      default = "30 days ago";
      description = "Relative date string passed to `date -d` for looking up previous summary and rolling memory entries in Loki.";
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

    summaryMaxTokens = lib.mkOption {
      type = lib.types.int;
      default = 2000;
      description = "Token budget for the daily summary generation step.";
    };

    memoryMaxTokens = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Token budget for the rolling memory compaction step.";
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

    rollingMemoryMaxChars = lib.mkOption {
      type = lib.types.int;
      default = 6000;
      description = "Maximum number of characters retained in the rolling memory file and passed back to the model.";
    };

    previousSummaryMaxChars = lib.mkOption {
      type = lib.types.int;
      default = 4000;
      description = "Maximum number of characters taken from the previous summary when building today's prompt.";
    };

    topRepeatsPerQuery = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Maximum number of repeated-message groups retained per query section.";
    };

    sampleLinesPerQuery = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Maximum number of recent sample log lines retained per query section after aggregation.";
    };

    gpuBusyRetryDelay = lib.mkOption {
      type = lib.types.str;
      default = "4h";
      description = "Delay before retrying a llama-server request when the response looks like a GPU memory exhaustion error.";
    };

    gpuBusyRetryCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of delayed retries to allow for GPU-memory exhaustion style llama-server failures.";
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
    users.groups.logDigest.gid = serviceDef.uid;
    users.users.logDigest = {
      uid = serviceDef.uid;
      group = "logDigest";
      isSystemUser = true;
    };

    systemd.services.logDigest = {
      description = "Daily rolling Loki log digest via llama-server";
      serviceConfig = {
        Type = "oneshot";
        User = "logDigest";
        Group = "logDigest";
        ExecStart = "${program}/bin/log-digest";
        # no retry loop for a daily job
        Restart = "on-failure";
        RestartSec = "360s";
        TimeoutStartSec = "5min";
      };
    };

    systemd.timers.logDigest = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
