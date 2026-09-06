{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types nameValuePair listToAttrs;
  cfg = config.my.infra.loggingAgent;
  infra = config.my.infra;
  observability = infra.observability;
  services = infra.services;
  vms = infra.vms;
  topology = infra.topology;

  sanitize =
    name:
    lib.replaceStrings [ "-" "." " " "/" ] [ "_" "_" "_" "_" ] name;

  hostnameConfig = vms.${cfg.hostname} or { services = [ ]; logProfiles = [ ]; };
  assignedServices = map (serviceName: services.${serviceName} // { _serviceKey = serviceName; }) hostnameConfig.services;
  loggedServices = builtins.filter (service: service.logging.enable) assignedServices;
  assignedProfiles = map (profileName: observability.logProfiles.${profileName} // { _profileKey = profileName; }) (hostnameConfig.logProfiles or [ ]);

  lowerLokiVm = lib.toLower observability.lokiVM;
  lokiEndpoint = "http://${lowerLokiVm}.${topology.domain}:${toString topology.firewallRules.loki_http.port}";

  normalizeCondition =
    condition:
    if condition == null || condition == ""
    then null
    else condition;

  serviceJournalUnits =
    service:
    if service.logging.journalUnits != [ ]
    then service.logging.journalUnits
    else if service.logging.journalMatches != { }
    then [ ]
    else [ "${service.unit}.service" ];

  serviceJournalTargets =
    map
      (service: {
        name = service._serviceKey;
        service = service._serviceKey;
        journalUnits = serviceJournalUnits service;
        journalMatches = service.logging.journalMatches;
        condition = normalizeCondition service.logging.condition;
        labels = service.logging.labels;
      })
      loggedServices;

  profileJournalTargets =
    map
      (profile: {
        name = profile._profileKey;
        service = profile._profileKey;
        journalUnits = [ ];
        journalMatches = profile.journalMatches;
        condition = normalizeCondition profile.condition;
        labels = profile.labels;
      })
      assignedProfiles;

  journalTargets = serviceJournalTargets ++ profileJournalTargets;
  hasJournalTargets = journalTargets != [ ];

  extraLabelKeys =
    lib.unique (
      builtins.concatLists (
        map (target: builtins.attrNames target.labels) journalTargets
      )
    );

  mkLabelScript =
    { serviceName
    , sourceType
    , labels
    }:
    ''
      .vm = "${cfg.hostname}"
      .service = "${serviceName}"
      .source_type = "${sourceType}"
      if exists(._SYSTEMD_UNIT) {
        .unit = string!(._SYSTEMD_UNIT)
      } else {
        del(.unit)
      }
    ''
    + lib.concatMapStringsSep "\n"
      (labelKey: ''."${labelKey}" = "${labels.${labelKey}}"'' )
      (builtins.attrNames labels);

  journalSources =
    listToAttrs (
      map
        (target:
          let
            sourceName = "log_${sanitize target.name}_journal";
          in
          nameValuePair sourceName ({
            type = "journald";
            current_boot_only = false;
          }
          // lib.optionalAttrs (target.journalUnits != [ ]) {
            include_units = target.journalUnits;
          }
          // lib.optionalAttrs (target.journalMatches != { }) {
            include_matches = target.journalMatches;
          }))
        journalTargets
    );

  journalTransforms =
    builtins.listToAttrs (
      builtins.concatLists (
        map
          (target:
            let
              baseName = sanitize target.name;
              sourceName = "log_${baseName}_journal";
              filterName = "log_${baseName}_journal_filter";
              remapName = "log_${baseName}_journal_labels";
            in
            (lib.optional (target.condition != null)
              (nameValuePair filterName {
                type = "filter";
                inputs = [ sourceName ];
                condition = target.condition;
              }))
            ++ [
              (nameValuePair remapName {
                type = "remap";
                inputs = [ (if target.condition != null then filterName else sourceName) ];
                source = mkLabelScript {
                  serviceName = target.service;
                  sourceType = "journald";
                  labels = target.labels;
                };
              })
            ])
          journalTargets
      )
    );

  sinkInputs = map (target: "log_${sanitize target.name}_journal_labels") journalTargets;

  sinkLabels =
    {
      vm = "{{ vm }}";
      service = "{{ service }}";
      source_type = "{{ source_type }}";
      unit = "{{ unit }}";
    }
    // builtins.listToAttrs (
      map
        (labelKey: nameValuePair labelKey "{{ ${labelKey} }}")
        extraLabelKeys
    );
in
{
  options.my.infra.loggingAgent = {
    enable = mkEnableOption "Vector agent derived from infra service/log profile declarations";
    hostname = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "VM hostname key in my.infra.vms.";
    };
    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/vector";
      description = "Vector checkpoint directory; ephemeral on the current guests.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.all (service: service.unit != null
          || service.logging.journalUnits != [ ] || service.logging.journalMatches != { }) loggedServices;
        message = "Logged resource-only roles must name explicit journal units or matches.";
      }
      {
        assertion = builtins.hasAttr cfg.hostname vms;
        message = "my.infra.loggingAgent.hostname '${cfg.hostname}' does not exist in my.infra.vms";
      }
      {
        assertion = observability.lokiVM == "" || builtins.hasAttr observability.lokiVM topology.vms;
        message = "my.infra.observability.lokiVM must reference a VM in my.infra.topology.vms";
      }
    ];

    services.vector = mkIf hasJournalTargets {
      enable = true;
      journaldAccess = hasJournalTargets;
      settings = {
        data_dir = cfg.stateDir;
        sources = journalSources;
        transforms = journalTransforms;
        sinks.loki = {
          type = "loki";
          inputs = sinkInputs;
          endpoint = lokiEndpoint;
          encoding.codec = "json";
          labels = sinkLabels;
        };
      };
    };
  };
}
