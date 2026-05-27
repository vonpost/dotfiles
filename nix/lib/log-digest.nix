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

  configFile = pkgs.writeText "log-digest-config.json" (builtins.toJSON {
    charsPerTokenEstimate = cfg.charsPerTokenEstimate;
    contextReserveTokens = cfg.contextReserveTokens;
    contextWindow = cfg.contextWindow;
    contextWindowFallback = cfg.contextWindowFallback;
    digestVm = digestVm;
    endpoint = cfg.endpoint;
    gpuBusyRetryCount = cfg.gpuBusyRetryCount;
    gpuBusyRetryDelay = cfg.gpuBusyRetryDelay;
    investigationEnable = cfg.investigationEnable;
    investigationMaxLinesPerQuery = cfg.investigationMaxLinesPerQuery;
    investigationMaxQueriesPerRound = cfg.investigationMaxQueriesPerRound;
    investigationMaxRounds = cfg.investigationMaxRounds;
    investigationMaxTotalQueries = cfg.investigationMaxTotalQueries;
    investigationPlannerMaxTokens = cfg.investigationPlannerMaxTokens;
    investigationPlannerMaxPromptChars = cfg.investigationPlannerMaxPromptChars;
    investigationQueryTimeoutSeconds = cfg.investigationQueryTimeoutSeconds;
    investigationSampleLinesPerQuery = cfg.investigationSampleLinesPerQuery;
    investigationTopRepeatsPerQuery = cfg.investigationTopRepeatsPerQuery;
    llamaRequestTimeoutSeconds = cfg.llamaRequestTimeoutSeconds;
    lokiUrl = cfg.lokiUrl;
    logQueries = map (query: {
      inherit (query) title expr priorityMax;
    }) cfg.logQueries;
    lookback = cfg.lookback;
    maxLinesPer = cfg.maxLinesPer;
    memoryLookback = cfg.memoryLookback;
    memoryMaxTokens = cfg.memoryMaxTokens;
    model = cfg.model;
    port = cfg.port;
    promptBudgetPercent = cfg.promptBudgetPercent;
    rollingMemoryMaxChars = cfg.rollingMemoryMaxChars;
    runBudgetSeconds = cfg.runBudgetSeconds;
    sampleLinesPerQuery = cfg.sampleLinesPerQuery;
    shutdownWarningSeconds = cfg.shutdownWarningSeconds;
    staleMemoryWarnAfter = cfg.staleMemoryWarnAfter;
    summaryMaxPromptChars = cfg.summaryMaxPromptChars;
    summaryMaxTokens = cfg.summaryMaxTokens;
    temperature = cfg.temperature;
    topRepeatsPerQuery = cfg.topRepeatsPerQuery;
    url = cfg.url;
    memoryMaxPromptChars = cfg.memoryMaxPromptChars;
  });

  program = pkgs.writeShellApplication {
    name = "log-digest";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.python3
    ];
    text = ''
      exec ${pkgs.python3}/bin/python ${./log-digest-agent.py} --config ${configFile}
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

    summaryMaxPromptChars = lib.mkOption {
      type = lib.types.int;
      default = 36000;
      description = "Hard cap on serialized summary request size before compaction is forced.";
    };

    memoryMaxPromptChars = lib.mkOption {
      type = lib.types.int;
      default = 28000;
      description = "Hard cap on serialized rolling-memory request size before compaction is forced.";
    };

    contextWindow = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Configured llama-server context window used for prompt budgeting.";
    };

    contextWindowFallback = lib.mkOption {
      type = lib.types.int;
      default = 32768;
      description = "Fallback llama-server context window used when a static value is not configured.";
    };

    contextReserveTokens = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Reserved tokens kept free for chat template overhead and estimation error.";
    };

    charsPerTokenEstimate = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Approximate character-to-token ratio used when deriving prompt size budgets.";
    };

    promptBudgetPercent = lib.mkOption {
      type = lib.types.int;
      default = 85;
      description = "Percent of the estimated available prompt space that logDigest is allowed to occupy before compaction kicks in.";
    };

    maxLinesPer = lib.mkOption {
      type = lib.types.int;
      default = 200;
      description = "Hard cap on Loki log lines per query before aggregation.";
    };

    rollingMemoryMaxChars = lib.mkOption {
      type = lib.types.int;
      default = 6000;
      description = "Soft warning threshold for the serialized rolling memory entry.";
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

    llamaRequestTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "HTTP timeout for llama-server requests so long summary runs are not aborted prematurely.";
    };

    gpuBusyRetryDelay = lib.mkOption {
      type = lib.types.str;
      default = "4h";
      description = "Delay before retrying a llama-server request when the response looks like a GPU-memory exhaustion error.";
    };

    gpuBusyRetryCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of delayed retries to allow for GPU-memory exhaustion style llama-server failures.";
    };

    staleMemoryWarnAfter = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Emit a warning when the rolling memory content hash stays unchanged for this many consecutive runs.";
    };

    runBudgetSeconds = lib.mkOption {
      type = lib.types.int;
      default = 3300;
      description = "Soft controller runtime budget; the Python agent will stop investigating and finalize before systemd kills the service.";
    };

    shutdownWarningSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "When the remaining soft runtime budget drops below this threshold, the agent stops issuing new follow-up queries and finalizes.";
    };

    investigationEnable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable iterative follow-up LogQL queries before the final digest is written.";
    };

    investigationMaxRounds = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Maximum number of planning rounds in the follow-up investigation loop.";
    };

    investigationMaxQueriesPerRound = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Maximum number of follow-up queries the model can request per planning round.";
    };

    investigationMaxTotalQueries = lib.mkOption {
      type = lib.types.int;
      default = 16;
      description = "Maximum total number of follow-up queries across the entire investigation loop.";
    };

    investigationMaxLinesPerQuery = lib.mkOption {
      type = lib.types.int;
      default = 200;
      description = "Log line cap for each follow-up query run by the investigation loop.";
    };

    investigationSampleLinesPerQuery = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Sample line cap for each follow-up query after aggregation.";
    };

    investigationTopRepeatsPerQuery = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Repeat-group cap for each follow-up query after aggregation.";
    };

    investigationQueryTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "HTTP timeout for each follow-up Loki query.";
    };

    investigationPlannerMaxTokens = lib.mkOption {
      type = lib.types.int;
      default = 1200;
      description = "Token budget for each investigation planning round.";
    };

    investigationPlannerMaxPromptChars = lib.mkOption {
      type = lib.types.int;
      default = 16000;
      description = "Hard character cap for planner prompts before extra compaction is applied.";
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
      description = "Ordered list of baseline Loki queries to seed the daily investigation.";
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
        Restart = "on-failure";
        RestartSec = "360s";
        TimeoutStartSec = "1h";
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
