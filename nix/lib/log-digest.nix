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
    then "http://${lib.toLower lokiVm}.${topology.domain}:${toString topology.firewallRules.loki_http.port}"
    else "http://nikki.lan:3100";

  # Which services live on which VM. Handed to the model so it can reason about
  # blast radius: two services failing together on one VM is a different story
  # from the same two failing across VMs.
  vmTopology = lib.mapAttrs (_vm: vmCfg: vmCfg.services) config.my.infra.vms;

  configData = {
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
    inherit (cfg) sessionWallSeconds queryMaxLookbackHours queryMaxPoints
      maxFollowups followupsPerSession followupMaxAttempts followupMaxAgeDays;
    inherit (cfg) observeEnable observeMaxPlans observeMaxQueriesPerRun
      observeDailyQueryBudget observeDailyCaptureBudget observeWallSeconds
      observeKeepDays observeMaxStorageMiB observeStandardWatchers;

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
  };
  configFile = pkgs.writeText "log-digest-config.json" (builtins.toJSON configData);
  # The daytime executable receives no inference endpoint configuration.
  observerConfig = pkgs.writeText "log-digest-observer.json" (builtins.toJSON
    (builtins.removeAttrs configData [ "url" "port" "endpoint" "model"
      "temperature" "llamaRequestTimeoutSeconds" ]));

  program = pkgs.writeShellApplication {
    name = "log-digest";
    runtimeInputs = [ pkgs.coreutils pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python ${./log-digest-agent.py} --config ${configFile} "$@"
    '';
  };

  sandbox = {
    User = "logDigest";
    Group = "logDigest";
    UMask = "0077";
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ cfg.stateDir ];
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    # No Unix sockets: in particular no systemd, Docker, or Nix daemon control.
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    SystemCallArchitectures = "native";
    IPAddressDeny = "any";
    IPAddressAllow = cfg.allowedIPAddresses;
    TasksMax = 16;
    MemoryMax = "512M";
    CPUQuota = "50%";
    TimeoutStopSec = "10s";
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
      type = lib.types.ints.positive;
      default = 30;
      description = "HTTP timeout for Loki and Prometheus queries.";
    };

    observeEnable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Execute typed read-only observation plans all day without model inference.";
    };
    observeAllowedIPAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1/32" "::1/128" ];
      description = "Observer network allowlist: only Loki and Prometheus addresses, never the inference server.";
    };
    observeStandardWatchers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Always watch failed systemd units and unavailable Prometheus targets.";
    };
    observeMaxPlans = lib.mkOption {
      type = lib.types.ints.between 1 20;
      default = 20;
      description = "Maximum durable model-created observation plans.";
    };
    observeMaxQueriesPerRun = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 16;
      description = "Maximum API reads per five-minute observer tick.";
    };
    observeDailyQueryBudget = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2000;
      description = "Maximum observer API reads per UTC day, including failures.";
    };
    observeDailyCaptureBudget = lib.mkOption {
      type = lib.types.ints.positive;
      default = 96;
      description = "Maximum observation snapshots per UTC day.";
    };
    observeWallSeconds = lib.mkOption {
      type = lib.types.ints.between 10 120;
      default = 120;
      description = "Observer execution deadline; the service also has a three-minute hard timeout.";
    };
    observeKeepDays = lib.mkOption {
      type = lib.types.ints.between 1 30;
      default = 7;
      description = "Maximum age of observation snapshots.";
    };
    observeMaxStorageMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = "Snapshot storage cap after each tick; also limited to 512 snapshots.";
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
      type = lib.types.ints.positive;
      default = 1200;
      description = ''
        Target GPU compute allowance per session, in seconds.

        Accounts for prompt_ms and predicted_ms after every response, with
        conservative token/timeout admission for each request including retries.
        Actual compute is known only after a request completes, so the hard
        ceiling is the separate service timeout and GPU window.
      '';
    };

    synthesisReserveSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 360;
      description = ''
        Portion of gpuBudgetSeconds held back for the final synthesis call, so a
        truncated investigation still produces a digest rather than nothing.

        At the measured ~18 tok/s decode this covers roughly 5000 tokens, which
        is enough for a thinking pass plus the digest itself.
      '';
    };

    maxToolCalls = lib.mkOption {
      type = lib.types.ints.positive;
      default = 48;
      description = ''
        Strict maximum per session, including notebook operations and failed
        calls. Parallel calls emitted by the model cannot bypass this limit.
      '';
    };

    toolResultMaxChars = lib.mkOption {
      type = lib.types.int;
      default = 4000;
      description = "Cap on a single tool result. Truncation is reported to the model so it can narrow instead of guessing.";
    };

    investigatorMaxTokens = lib.mkOption {
      type = lib.types.int;
      default = 1400;
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

        Allows up to three findings with explicit impact and current-state refs.
        If thinkingForSynthesis is enabled, this also includes the reasoning block.
      '';
    };

    synthesisTemperature = lib.mkOption {
      type = lib.types.float;
      default = 0.2;
      description = "Sampling temperature for factual digest synthesis.";
    };

    thinkingForSynthesis = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable reasoning mode on the first synthesis attempt. Disabled by default
        because reasoning can consume the entire output allowance without a digest.
        Investigation and fallback attempts use no thinking. Retries share the
        existing GPU and wall-clock budgets and may be skipped when those run out.
      '';
    };

    # -- collection ------------------------------------------------------

    sessionWallSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1500;
      description = "Reasoning wall-clock allowance after pack preparation; HTTP calls are capped to time remaining.";
    };

    allowedIPAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1/32" "::1/128" ];
      description = "systemd network allowlist: only observability/model servers and DNS if names are used. Prefer literal IP endpoints.";
    };

    queryMaxLookbackHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 168;
      description = "Maximum lookback for investigation queries; matches seven-day raw data retention.";
    };

    queryMaxPoints = lib.mkOption {
      type = lib.types.ints.positive;
      default = 169;
      description = "Maximum evaluation timestamps per range query, with a minimum 60-second step.";
    };

    maxFollowups = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Maximum durable investigation tasks. Only resolved tasks can be evicted when full.";
    };

    followupsPerSession = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "Number of due tasks highlighted per session, ordered by priority then oldest check.";
    };

    followupMaxAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "Revisits before an unresolved task is marked needs_human; at most one attempt counted per session.";
    };

    followupMaxAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Age at which an open task requires human review instead of automatic investigation.";
    };

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
      type = lib.types.either lib.types.str (lib.types.listOf lib.types.str);
      default = [ "01:30" "04:30" ];
      description = ''
        systemd OnCalendar for the reasoning run. Local time, so it tracks the host
        timezone across DST. Must fall inside the llama-cpp GPU window.
      '';
    };

    reasonRuntimeMaxSec = lib.mkOption {
      type = lib.types.str;
      default = "28min";
      description = "Hard wall-clock ceiling including pack preparation; applied as TimeoutStartSec for the oneshot service.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.synthesisReserveSeconds < cfg.gpuBudgetSeconds
          && cfg.gpuBudgetSeconds < cfg.sessionWallSeconds;
        message = "logDigest requires synthesisReserveSeconds < gpuBudgetSeconds < sessionWallSeconds.";
      }
      {
        assertion = cfg.followupsPerSession <= cfg.maxFollowups;
        message = "logDigest followupsPerSession must not exceed maxFollowups.";
      }
    ];
    users.groups.logDigest.gid = lib.mkDefault serviceDef.uid;
    users.users.logDigest = {
      uid = lib.mkDefault serviceDef.uid;
      group = lib.mkDefault "logDigest";
      isSystemUser = lib.mkDefault true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 logDigest logDigest -"
      "d ${cfg.stateDir}/observations 0750 logDigest logDigest -"
    ];

    systemd.services.logDigest-observe = lib.mkIf cfg.observeEnable {
      description = "logDigest observation plans (CPU only, no inference)";
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = sandbox // {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python ${./log-digest-agent.py} --config ${observerConfig} observe";
        ReadWritePaths = [ "${cfg.stateDir}/observations" ];
        IPAddressAllow = cfg.observeAllowedIPAddresses;
        CPUQuota = "25%";
        Nice = 10;
        TimeoutStartSec = "3min";
        Restart = "no";
      };
    };

    systemd.timers.logDigest-observe = lib.mkIf cfg.observeEnable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:00/5:00";
        Persistent = false;
        AccuracySec = "1s";
        RandomizedDelaySec = "20s";
      };
    };

    # Phase A: no GPU. Builds the baseline and signature catalog that make
    # "new", "escalating" and "went silent" statements factual.
    systemd.services.logDigest-collect = {
      description = "logDigest collector (no GPU)";
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "logDigest";
        Group = "logDigest";
        ExecStart = "${program}/bin/log-digest collect";
        Restart = "no";
        TimeoutStartSec = "10min";
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

    # Phase B: a fresh pack uses the hourly catalog plus current API readings.
    # Do not collect another overlapping hour: that inflates catalog/baseline
    # counts twice every night. The agent can query the latest logs directly.
    systemd.services.logDigest = {
      description = "logDigest reasoning run (GPU window)";
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "logDigest";
        Group = "logDigest";
        ExecStart = "${program}/bin/log-digest reason --refresh";
        # Deliberately no restart. A retry loop against a GPU that is only
        # available inside a fixed window either wastes the window or fires
        # outside it. If a run fails, the next scheduled session is the retry.
        Restart = "no";
        TimeoutStartSec = cfg.reasonRuntimeMaxSec;
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
