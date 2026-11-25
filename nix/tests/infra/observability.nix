{ lib, nixosConfigurations }:
let
  nikki = nixosConfigurations.NIKKI.config.services.vector.settings;
  mamoru = nixosConfigurations.MAMORU.config.services.vector.settings;
  okami = nixosConfigurations.OKAMI.config.services.vector.settings;
  configs = builtins.attrValues (builtins.removeAttrs nixosConfigurations [ "MOTHER" ]);
  digest = nixosConfigurations.NIKKI.config;
  host = nixosConfigurations.MOTHER.config;
  llm = nixosConfigurations.OKAMI.config;
  window = import ../../config/infra/services/llama-cpp-config.nix;
  checks = {
    physicalHostIsObserved =
      host.services.prometheus.exporters.node.enable
      && host.services.prometheus.exporters.node.listenAddress == host.my.infra.topology.hostIp
      && !host.services.prometheus.exporters.node.openFirewall
      && builtins.any (target: (target.labels.vm or "") == "MOTHER")
        (builtins.head digest.services.prometheus.scrapeConfigs).static_configs
      && digest.services.logDigest.infrastructureHost == "MOTHER";
    hostScrapeFirewallUsesActiveBackend =
      host.networking.firewall.backend == "nftables"
      && host.networking.firewall.extraCommands == ""
      && lib.hasInfix ''iifname "br-mgmt" ip saddr 10.10.10.35 ip daddr 10.10.10.99 tcp dport 9100 accept''
        host.networking.firewall.extraInputRules;
    hostJournalSurvivesMonitoringOutage =
      !host.services.vector.settings.sources.host_journal.current_boot_only
      && host.services.vector.settings.sinks.loki.buffer.type == "disk"
      && lib.hasInfix "Storage=persistent" host.services.journald.extraConfig
      && lib.hasInfix ''._TRANSPORT == "kernel"'' host.services.vector.settings.transforms.host_events.condition;
    hostLocalResourceHistory =
      host.services.sysstat.enable
      && host.services.sysstat.collect-frequency == "*:*:00"
      && host.services.sysstat.collect-args == "-S DISK 1 1";
    grafanaCredentialDelivered =
      digest.microvm.credentialFiles.grafana_secret_key == host.sops.secrets."grafana/secret_key".path
      && host.sops.secrets."grafana/secret_key".key == "grafana/secret_key"
      && builtins.elem "grafana_secret_key" digest.systemd.services.grafana.serviceConfig.LoadCredential
      && digest.services.grafana.settings.security.secret_key ==
        "$__file{/run/credentials/grafana.service/grafana_secret_key}";
    grafanaCredentialScoped = builtins.all (system:
      (system.config.microvm.credentialFiles ? grafana_secret_key)
        == system.config.services.grafana.enable
    ) configs;
    allDigestUnits = nikki.sources.log_logDigest_journal.include_units ==
      [ "logDigest.service" "logDigest-collect.service" "logDigest-observe.service" ];
    firewallNativeMatch = mamoru.sources.log_firewall_journal.include_matches == {
      _TRANSPORT = [ "kernel" ];
    };
    noInactiveJellyfinSource = !(okami.sources ? log_jellyfin_journal);
    journalsOnly = builtins.all (system: builtins.all (source: source.type == "journald")
      (builtins.attrValues system.config.services.vector.settings.sources)) configs;
    checkpointsUnchanged = builtins.all
      (system: system.config.services.vector.settings.data_dir == "/var/lib/vector") configs;
    logLabelsPreserved = nikki.sinks.loki.labels == {
      vm = "{{ vm }}"; service = "{{ service }}";
      source_type = "{{ source_type }}"; unit = "{{ unit }}";
    };
    digestDashboardHost = lib.hasInfix "NIKKI" (builtins.toJSON
      (import ../../config/infra/dashboards/digest.nix { hostname = "NIKKI"; }));
    twoOvernightSessions = digest.systemd.timers.logDigest.timerConfig.OnCalendar ==
      [ "01:30" "04:30" ] && window.gpuWindowOpen == [ "01:25" "04:25" ]
      && window.gpuWindowClose == [ "02:00" "05:00" ];
    noDaytimeCatchup = !digest.systemd.timers.logDigest.timerConfig.Persistent
      && !llm.systemd.timers.llama-cpp-window.timerConfig.Persistent
      && !llm.systemd.timers.llama-cpp-window-close.timerConfig.Persistent;
    gpuWindowHasMainProcess = llm.systemd.services.llama-cpp-window.serviceConfig.Type == "exec"
      && llm.systemd.services.llama-cpp-window.serviceConfig.RuntimeMaxSec != "infinity";
    modelCannotStartOutsideWindow = builtins.elem "llama-cpp-window.service"
      llm.systemd.services.llama-cpp.requisite
      && builtins.elem "llama-cpp-window.service" llm.systemd.services.llama-cpp.partOf
      && llm.systemd.services.llama-cpp.wantedBy == [ ];
    oneshotTimeoutsAreEffective = digest.systemd.services.logDigest.serviceConfig.TimeoutStartSec == "28min"
      && digest.systemd.services.logDigest-collect.serviceConfig.TimeoutStartSec == "10min";
    sandboxBothDigestPhases = builtins.all (name:
      let s = digest.systemd.services.${name}.serviceConfig;
      in s.ProtectSystem == "strict" && s.ReadWritePaths == [ digest.services.logDigest.stateDir ]
        && s.NoNewPrivileges && s.PrivateDevices && s.ProtectHome
        && s.CapabilityBoundingSet == "" && s.IPAddressDeny == "any"
        && !(builtins.elem "AF_UNIX" s.RestrictAddressFamilies)
    ) [ "logDigest" "logDigest-collect" ];
    largerBoundedAllowance = digest.services.logDigest.gpuBudgetSeconds == 1200
      && digest.services.logDigest.synthesisReserveSeconds == 360
      && digest.services.logDigest.maxToolCalls == 48;
    cpuObserver = let s = digest.systemd.services.logDigest-observe.serviceConfig; in
      s.ReadWritePaths == [ "${digest.services.logDigest.stateDir}/observations" ]
      && s.IPAddressAllow == [ "127.0.0.1/32" "::1/128" "10.10.10.35" ]
      && !(builtins.elem "10.10.20.30" s.IPAddressAllow)
      && s.IPAddressDeny == "any" && s.PrivateDevices && s.NoNewPrivileges
      && s.ProtectSystem == "strict" && s.CPUQuota == "25%"
      && !(builtins.elem "AF_UNIX" s.RestrictAddressFamilies)
      && s.TimeoutStartSec == "3min"
      && digest.systemd.timers.logDigest-observe.timerConfig.OnCalendar == "*-*-* *:00/5:00";
  };
in
assert lib.assertMsg (builtins.all (x: x) (builtins.attrValues checks))
  "Observability contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: x: !x) checks))}";
checks
