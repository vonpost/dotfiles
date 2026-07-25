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

  # Which services live on which VM. Handed to the model so it can reason about
  # blast radius: two services failing together on one VM is a different story
  # from the same two failing across VMs.
  vmTopology = lib.mapAttrs (_vm: vmCfg: vmCfg.serviceMounts) config.my.infra.vmServiceMounts;

  configFile = pkgs.writeText "log-digest-config.json" (builtins.toJSON {
    inherit digestVm;
    topology = vmTopology;

    lokiUrl = cfg.lokiUrl;
    prometheusUrl = cfg.prometheusUrl;
    stateDir = cfg.stateDir;
    queryTimeoutSeconds = cfg.queryTimeoutSeconds;

    url = cfg.url;
    port = cfg.port;
    endpoint = cfg.endpoint;
    model = cfg.model;
    temperature = cfg.temperature;
    llamaRequestTimeoutSeconds = cfg.llamaRequestTimeoutSeconds;

    gpuBudgetSeconds = cfg.gpuBudgetSeconds;
    synthesisReserveSeconds = cfg.synthesisReserveSeconds;
    maxToolCalls = cfg.maxToolCalls;
    toolResultMaxChars = cfg.toolResultMaxChars;
    investigatorMaxTokens = cfg.investigatorMaxTokens;
    synthesisMaxTokens = cfg.synthesisMaxTokens;
    synthesisTemperature = cfg.synthesisTemperature;
    thinkingForSynthesis = cfg.thinkingForSynthesis;

    baselineDays = cfg.baselineDays;
    collectIntervalSeconds = cfg.collectIntervalSeconds;
    catalogMaxEntries = cfg.catalogMaxEntries;
    anomalyZThreshold = cfg.anomalyZThreshold;
    severityRegex = cfg.severityRegex;
    severityMaxLines = cfg.severityMaxLines;
    noiseServices = cfg.noiseServices;

    packMaxAgeHours = cfg.packMaxAgeHours;
    keepDigestDays = cfg.keepDigestDays;
    alwaysBuildPack = false;
  });

  program = pkgs.writeShellApplication {
    name = "log-digest";
    runtimeInputs = [ pkgs.coreutils pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python ${./log-digest-agent.py} --config ${configFile} "$@"
    '';
  };
in
{
  options.services.logDigest = {
    enable = lib.mkEnableOption "Loki/Prometheus-backed homelab digest via llama-server";

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = defaultLokiHost;
      description = "Base Loki URL used for LogQL queries.";
    };

    prometheusUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9090";
      description = "Base Prometheus URL. Defaults to the local instance, since the digest runs on the observability VM.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/logDigest";
      description = ''
        Persistent directory for the signature catalog, volume baseline, evidence
        packs and rendered digests. This must survive reboots: it is the only
        long-term memory the digest has, and Loki's retention is far shorter than
        the history the baseline needs.
      '';
    };

    queryTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "HTTP timeout for Loki and Prometheus queries.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1";
      description = "llama-server OpenAI-compatible base URL.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "/v1/chat/completions";
      description = "Chat completions endpoint path.";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 8080;
      description = "Port that llama-server listens on.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "local-model";
      description = "Model name passed to llama-server.";
    };

    temperature = lib.mkOption {
      type = lib.types.float;
      default = 0.2;
      description = "Sampling temperature for tool-selection turns.";
    };

    llamaRequestTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = "HTTP timeout for a single llama-server request.";
    };

    # -- GPU budget ------------------------------------------------------

    gpuBudgetSeconds = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = ''
        Total GPU compute budget for one digest run, in seconds.

        Enforced against the prompt_ms and predicted_ms that llama-server reports
        per response, so it measures actual compute rather than wall clock. Time
        spent waiting on Loki does not count against it, and prefill skipped
        because the KV cache already held the prefix does not either.

        Sized to fill the GPU window rather than to be as small as possible: the
        window is a fixed daily cost once opened, so leaving two thirds of it
        idle buys nothing. Must stay below reasonRuntimeMaxSec with room for
        collection and Loki round trips.
      '';
    };

    synthesisReserveSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        Portion of gpuBudgetSeconds held back for the final synthesis call, so a
        truncated investigation still produces a digest rather than nothing.

        At the measured ~18 tok/s decode this covers roughly 5000 tokens, which
        is enough for a thinking pass plus the digest itself.
      '';
    };

    maxToolCalls = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = ''
        Backstop on tool calls per run. The GPU budget is the real limit.

        Kept low deliberately: given a large allowance the model keeps querying
        past the point of diminishing returns instead of concluding.
      '';
    };

    toolResultMaxChars = lib.mkOption {
      type = lib.types.int;
      default = 2400;
      description = "Cap on a single tool result. Truncation is reported to the model so it can narrow instead of guessing.";
    };

    investigatorMaxTokens = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = ''
        Token cap per investigation turn. Kept modest because a tool call is only
        60-100 tokens and decode is the expensive axis, roughly 20 tok/s against
        220 tok/s for prefill.

        Do not set this too low. At 600 a turn emitting several calls at once was
        truncated mid-argument, which llama.cpp then refused to re-parse on every
        subsequent request. The agent recovers from that now, but the wasted turn
        costs more than the tokens saved.
      '';
    };

    synthesisMaxTokens = lib.mkOption {
      type = lib.types.int;
      default = 5000;
      description = ''
        Token cap for the final digest.

        Must be large enough to hold a reasoning block AND the JSON that follows
        it. Sized at 2600 the reasoning block consumed the entire allowance and
        the run emitted no digest at all.
      '';
    };

    synthesisTemperature = lib.mkOption {
      type = lib.types.float;
      default = 0.4;
      description = "Sampling temperature for synthesis. Slightly above the tool-turn value, for readable prose.";
    };

    thinkingForSynthesis = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the model's reasoning mode for the single synthesis call.

        Tool-selection turns stay non-thinking because they are mechanical.
        Ranking findings by consequence, and spotting that several signatures are
        one causal chain rather than several incidents, is where reasoning pays.

        Needs synthesisMaxTokens large enough for the reasoning block plus the
        digest; undersized, the reasoning consumes everything and nothing is
        emitted. The run always retries without thinking, so this degrades rather
        than fails.
      '';
    };

    # -- collection ------------------------------------------------------

    baselineDays = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = ''
        Days of history kept for anomaly detection and novelty.

        Independent of Loki's retention: the collector stores compact aggregates on
        disk, so the baseline can outlive the raw logs it was derived from.
      '';
    };

    collectIntervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "Window each collector run aggregates over. Must match the collector timer interval.";
    };

    catalogMaxEntries = lib.mkOption {
      type = lib.types.int;
      default = 4000;
      description = "Cap on distinct message signatures retained. Pruned by severity, then by total count.";
    };

    anomalyZThreshold = lib.mkOption {
      type = lib.types.float;
      default = 3.5;
      description = "Robust z-score (median/MAD) at which a count is treated as anomalous.";
    };

    severityRegex = lib.mkOption {
      type = lib.types.str;
      default = "(?i)\\b(error|fatal|panic|critical|exception|traceback|failed|failure|refused|denied|unreachable|timeout|timed out|corrupt|warn|warning)\\b";
      description = ''
        RE2 pattern used to find severity-bearing lines, applied server-side by Loki.

        Content matching rather than journald PRIORITY, because this fleet's .NET,
        Java and Go services log at PRIORITY 6 and put severity in the message text.
        PRIORITY<=4 finds only firewall drops here; this finds the real events, and
        few enough of them per day to capture exhaustively rather than sample.
      '';
    };

    severityMaxLines = lib.mkOption {
      type = lib.types.int;
      default = 5000;
      description = "Cap on severity lines fetched per collector run. Hitting it is reported as a collection warning.";
    };

    noiseServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Regexes for services excluded from signature cataloging.

        These still get a one-line volume figure so a structural change is visible,
        but they never generate findings. Intended for high-volume inert streams
        such as internet background radiation hitting the firewall.
      '';
    };

    packMaxAgeHours = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Warn if the evidence pack is older than this when reasoning starts.";
    };

    keepDigestDays = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = "How long rendered digests, packs and traces are kept on disk.";
    };

    # -- schedule --------------------------------------------------------

    collectOnCalendar = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar for the GPU-free collector.";
    };

    reasonOnCalendar = lib.mkOption {
      type = lib.types.str;
      default = "03:30";
      description = ''
        systemd OnCalendar for the reasoning run. Local time, so it tracks the host
        timezone across DST. Must fall inside the llama-cpp GPU window.
      '';
    };

    reasonRuntimeMaxSec = lib.mkOption {
      type = lib.types.str;
      default = "18min";
      description = "Hard ceiling on the reasoning run, so it can never outlive the GPU window.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.logDigest.gid = lib.mkDefault serviceDef.uid;
    users.users.logDigest = {
      uid = lib.mkDefault serviceDef.uid;
      group = lib.mkDefault "logDigest";
      isSystemUser = lib.mkDefault true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 logDigest logDigest -"
    ];

    # Phase A: no GPU. Builds the baseline and signature catalog that make
    # "new", "escalating" and "went silent" statements factual.
    systemd.services.logDigest-collect = {
      description = "logDigest collector (no GPU)";
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "logDigest";
        Group = "logDigest";
        ExecStart = "${program}/bin/log-digest collect";
        Restart = "no";
        RuntimeMaxSec = "10min";
      };
    };

    systemd.timers.logDigest-collect = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.collectOnCalendar;
        Persistent = true;
        RandomizedDelaySec = "2m";
      };
    };

    # Phase B: the GPU window. A fresh collection plus evidence pack runs first,
    # so the model always reasons over data minutes old rather than hours.
    systemd.services.logDigest = {
      description = "logDigest reasoning run (GPU window)";
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "logDigest";
        Group = "logDigest";
        ExecStartPre = "${program}/bin/log-digest collect --build-pack";
        ExecStart = "${program}/bin/log-digest reason";
        # Deliberately no restart. A retry loop against a GPU that is only
        # available inside a fixed window either wastes the window or fires
        # outside it. If a run fails, the next day's run is the retry.
        Restart = "no";
        RuntimeMaxSec = cfg.reasonRuntimeMaxSec;
      };
    };

    systemd.timers.logDigest = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.reasonOnCalendar;
        # Not Persistent: a missed run must not fire at an arbitrary time after
        # boot, because the GPU window will not be open then.
        Persistent = false;
        AccuracySec = "1s";
      };
    };
  };
}
