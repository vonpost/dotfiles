{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types nameValuePair listToAttrs;
  cfg = config.my.infra.loggingAgent;
  infra = config.my.infra;
  observability = infra.observability;
  services = infra.services;
  vmServiceMounts = infra.vmServiceMounts;
  topology = infra.topology;

  sanitize =
    name:
    lib.replaceStrings [ "-" "." " " "/" ] [ "_" "_" "_" "_" ] name;

  hostnameConfig = vmServiceMounts.${cfg.hostname} or { serviceMounts = [ ]; logProfiles = [ ]; };
  assignedServices = map (serviceName: services.${serviceName} // { _serviceKey = serviceName; }) hostnameConfig.serviceMounts;
  loggedServices = builtins.filter (service: service.logging.enable) assignedServices;
  assignedProfiles = map (profileName: observability.logProfiles.${profileName} // { _profileKey = profileName; }) (hostnameConfig.logProfiles or [ ]);

  lowerLokiVm = lib.toLower observability.lokiVM;
  lokiEndpoint = "http://${lowerLokiVm}.${topology.domain}:3100";

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

  serviceFileTargets =
    builtins.concatLists (
      map
        (service:
          lib.imap0
            (idx: fileTarget: {
              name = "${service._serviceKey}_file_${toString idx}";
              service = service._serviceKey;
              path = fileTarget.path;
              labels = service.logging.labels // fileTarget.labels;
            })
            service.logging.files)
        loggedServices
    );

  profileFileTargets =
    builtins.concatLists (
      map
        (profile:
          lib.imap0
            (idx: fileTarget: {
              name = "${profile._profileKey}_file_${toString idx}";
              service = profile._profileKey;
              path = fileTarget.path;
              labels = profile.labels // fileTarget.labels;
            })
            profile.files)
        assignedProfiles
    );

  journalTargets = serviceJournalTargets ++ profileJournalTargets;
  fileTargets = serviceFileTargets ++ profileFileTargets;
  hasJournalTargets = journalTargets != [ ];
  hasAnyTargets = journalTargets != [ ] || fileTargets != [ ];

  extraLabelKeys =
    lib.unique (
      builtins.concatLists (
        map (target: builtins.attrNames target.labels) (journalTargets ++ fileTargets)
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

  fileSources =
    listToAttrs (
      map
        (target:
          nameValuePair
            "log_${sanitize target.name}_file"
            {
              type = "file";
              include = [ target.path ];
              read_from = "beginning";
            })
        fileTargets
    );

  fileTransforms =
    listToAttrs (
      builtins.concatLists (
        map
          (target:
            let
              sourceName = "log_${sanitize target.name}_file";
              remapName = "log_${sanitize target.name}_file_labels";
            in
            [
              (nameValuePair remapName {
                type = "remap";
                inputs = [ sourceName ];
                source = mkLabelScript {
                  serviceName = target.service;
                  sourceType = "file";
                  labels = target.labels;
                };
              })
            ])
          fileTargets
      )
    );

  sinkInputs =
    map (target: "log_${sanitize target.name}_journal_labels") journalTargets
    ++ map (target: "log_${sanitize target.name}_file_labels") fileTargets;

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
      default = "MAMORU";
      description = "VM hostname key in my.infra.vmServiceMounts.";
    };
    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/vector";
      description = "Mounted state directory used by Vector for checkpoints.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.hostname vmServiceMounts;
        message = "my.infra.loggingAgent.hostname '${cfg.hostname}' does not exist in my.infra.vmServiceMounts";
      }
      {
        assertion = observability.lokiVM == "" || builtins.hasAttr observability.lokiVM topology.vms;
        message = "my.infra.observability.lokiVM must reference a VM in my.infra.topology.vms";
      }
    ];

    services.vector = mkIf hasAnyTargets {
      enable = true;
      journaldAccess = hasJournalTargets;
      settings = {
        data_dir = cfg.stateDir;
        sources =
          journalSources
          // fileSources;
        transforms = journalTransforms // fileTransforms;
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
