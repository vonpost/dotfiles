{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  infraServices = config.my.infra.services;
  infraVms = config.my.infra.vms;
  infraTopology = config.my.infra.topology;

  secretType = types.submodule ({ ... }: {
    options = {
      source = mkOption {
        type = types.str;
        description = "Absolute secret source path.";
      };
      sops = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "Optional sops-nix secret overrides.";
      };
    };
  });

  loggingTargetType = types.submodule ({ ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
      };
      journalUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      journalMatches = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
        description = "Native journald match groups such as { _TRANSPORT = [ \"kernel\" ]; }.";
      };
      condition = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Optional Vector VRL filter condition.";
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
    };
  });

  serviceType = types.submodule ({ name, config, ... }:
    let
      serviceCfg = config;
    in
    {
      options = {
      name = mkOption {
        type = types.str;
        default = name;
      };
      unit = mkOption {
        type = types.nullOr types.str;
        description = "Systemd unit, or null for a resource-only role.";
        default = config.name;
      };
      user = mkOption {
        type = types.str;
        default = config.name;
      };
      group = mkOption {
        type = types.str;
        default = config.user;
      };
      uid = mkOption {
        type = types.int;
      };
      gid = mkOption {
        type = types.int;
        default = config.uid;
      };
      bindTarget = mkOption {
        type = types.str;
        default = config.name;
      };
      downloadsGroup = mkOption {
        type = types.bool;
        default = false;
      };
      mediaGroup = mkOption {
        type = types.bool;
        default = false;
      };
      hasCacheDir = mkOption {
        type = types.bool;
        default = false;
      };
      uncachedCacheDirectories = mkOption {
        type = types.listOf (types.strMatching "[a-zA-Z0-9_-]+");
        default = [ ];
        description = ''
          Immediate cache subdirectories exported through separate uncached
          VirtioFS shares. Use only for files that another VM modifies while
          this VM reads them; the rest of the service state keeps its cache.
        '';
      };
      hasDownloadsDir = mkOption {
        type = types.bool;
        default = false;
      };
      hasMediaDir = mkOption {
        type = types.bool;
        default = false;
      };
      managedState = mkOption {
        type = types.bool;
        default = true;
      };
      secrets = mkOption {
        type = types.attrsOf secretType;
        default = { };
      };
      logging = mkOption {
        type = loggingTargetType;
        default = {
          journalUnits = lib.optional (serviceCfg.unit != null) "${serviceCfg.unit}.service";
        };
        description = "Observability metadata used to derive Vector collection rules.";
      };
      };
    });

  logProfileType = types.submodule ({ name, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
      };
      description = mkOption {
        type = types.str;
        default = "";
      };
      condition = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Vector VRL filter condition for journal-derived logs.";
      };
      journalMatches = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
        description = "Native journald match groups such as { _TRANSPORT = [ \"kernel\" ]; }.";
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
    };
  });

  vmType = types.submodule ({ ... }: {
    options = vmNetworkOptions // {
      vcpu = mkOption { type = types.nullOr types.ints.positive; default = null; };
      mem = mkOption { type = types.nullOr types.ints.positive; default = null; };
      hotplugMem = mkOption { type = types.nullOr types.ints.unsigned; default = null; };
      services = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      logProfiles = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  });

  firewallRuleType = types.submodule ({ ... }: {
    options = {
      port = mkOption { type = types.int; };
      proto = mkOption { type = types.enum [ "tcp" "udp" ]; };
      routedFrom = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  });

  natRuleType = types.submodule ({ ... }: {
    options = {
      port = mkOption { type = types.int; };
      externalPort = mkOption { type = types.int; };
      proto = mkOption { type = types.enum [ "tcp" "udp" ]; };
    };
  });

  vmNetworkOptions = {
      id = mkOption { type = types.int; };
      primaryVlan = mkOption {
        type = types.str;
        description = "Network used for the VM's DNS address, monitoring and inbound NAT.";
      };
      assignedVlans = mkOption {
        type = types.listOf types.str;
      };
      ipv6 = mkOption { type = types.bool; };
      provides = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      portForward = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };

  vmTopologyType = types.submodule { options = vmNetworkOptions; };

  vlanType = types.submodule ({ ... }: {
    options = {
      id = mkOption { type = types.int; };
    };
  });

  topologyType = types.submodule ({ ... }: {
    options = {
      domain = mkOption { type = types.str; };
      gatewayVM = mkOption { type = types.str; };
      dnsVM = mkOption { type = types.str; };
      hostIp = mkOption { type = types.str; };
      wanMac = mkOption { type = types.str; };
      wanBridge = mkOption { type = types.str; };
      firewallRules = mkOption {
        type = types.attrsOf firewallRuleType;
      };
      natRules = mkOption {
        type = types.attrsOf natRuleType;
      };
      vms = mkOption {
        readOnly = true;
        type = types.attrsOf vmTopologyType;
      };
      vlans = mkOption {
        type = types.attrsOf vlanType;
      };
    };
  });

  serviceNames = builtins.attrNames infraServices;
  topologyVmNames = builtins.attrNames infraTopology.vms;
  firewallRuleNames = builtins.attrNames infraTopology.firewallRules;
  natRuleNames = builtins.attrNames infraTopology.natRules;
  logProfileNames = builtins.attrNames config.my.infra.observability.logProfiles;

  missingMountedServices =
    builtins.concatLists (
      lib.mapAttrsToList (_vm: vmCfg:
        builtins.filter (serviceName: !(builtins.elem serviceName serviceNames)) vmCfg.services
      ) infraVms
    );

  missingLogProfiles =
    builtins.concatLists (
      lib.mapAttrsToList (_vm: vmCfg:
        builtins.filter (profileName: !(builtins.elem profileName logProfileNames)) (vmCfg.logProfiles or [ ])
      ) infraVms
    );

  missingFirewallRoutedFrom =
    builtins.concatLists (
      lib.mapAttrsToList (_rule: ruleCfg:
        builtins.filter (vm: !(builtins.elem vm topologyVmNames)) ruleCfg.routedFrom
      ) infraTopology.firewallRules
    );

  missingProvidedFirewallRules =
    builtins.concatLists (
      lib.mapAttrsToList (_vm: vmCfg:
        builtins.filter (rule: !(builtins.elem rule firewallRuleNames)) vmCfg.provides
      ) infraTopology.vms
    );

  missingNatReferences =
    builtins.concatLists (
      lib.mapAttrsToList (_vm: vmCfg:
        builtins.filter (rule: !(builtins.elem rule natRuleNames)) vmCfg.portForward
      ) infraTopology.vms
    );

  missingAssignedVlanRefs =
    let vlanNames = builtins.attrNames infraTopology.vlans;
    in builtins.concatLists (
      lib.mapAttrsToList (_vm: vmCfg:
        builtins.filter (vlan: !(builtins.elem vlan vlanNames)) vmCfg.assignedVlans
      ) infraTopology.vms
    );

in
{
  options.my.infra = {
    services = mkOption {
      type = types.attrsOf serviceType;
      default = { };
      description = "Service catalog used to derive users/state mounts/credentials.";
    };

    vms = mkOption {
      type = types.attrsOf vmType;
      default = { };
      description = "VM inventory: identity, resources, services and network membership.";
    };

    topology = mkOption {
      type = topologyType;
      description = "Typed network topology model.";
      default = {
        domain = "";
        gatewayVM = "";
        dnsVM = "";
        hostIp = "";
        wanMac = "";
        wanBridge = "";
        firewallRules = { };
        natRules = { };
        vms = { };
        vlans = { };
      };
    };

    observability = {
      lokiVM = mkOption {
        type = types.str;
        default = "";
        description = "VM name that hosts Loki.";
      };
      logProfiles = mkOption {
        type = types.attrsOf logProfileType;
        default = { };
        description = "Catalog of reusable Vector collection profiles not tied to a single service.";
      };
    };
  };

  config = {
    my.infra.topology.vms = lib.mapAttrs (_: vm:
      builtins.intersectAttrs vmNetworkOptions vm) infraVms;
    assertions = [
      {
        assertion = builtins.all (vm: builtins.elem vm.primaryVlan vm.assignedVlans)
          (builtins.attrValues infraVms);
        message = "Each VM primaryVlan must be present in assignedVlans.";
      }
      {
        assertion = let ids = map (vm: vm.id) (builtins.attrValues infraVms);
          in builtins.length ids == builtins.length (lib.unique ids);
        message = "VM IDs must be unique (they also identify vsock endpoints).";
      }
      {
        assertion = builtins.all (service: service.unit != null || service.secrets == { })
          (builtins.attrValues infraServices);
        message = "Resource-only roles cannot receive service credentials without a systemd unit.";
      }
      {
        assertion = builtins.all (service: service.uncachedCacheDirectories == [ ]
          || (service.managedState && service.hasCacheDir)) (builtins.attrValues infraServices);
        message = "Uncached cache directories require managedState and hasCacheDir.";
      }
      {
        assertion = missingMountedServices == [ ];
        message = "Unknown service names in my.infra.vms: ${toString (lib.unique missingMountedServices)}";
      }
      {
        assertion = missingLogProfiles == [ ];
        message = "Unknown log profile names in my.infra.vms: ${toString (lib.unique missingLogProfiles)}";
      }
      {
        assertion = infraTopology.gatewayVM == "" || builtins.elem infraTopology.gatewayVM topologyVmNames;
        message = "my.infra.topology.gatewayVM must reference a VM in my.infra.topology.vms";
      }
      {
        assertion = infraTopology.dnsVM == "" || builtins.elem infraTopology.dnsVM topologyVmNames;
        message = "my.infra.topology.dnsVM must reference a VM in my.infra.topology.vms";
      }
      {
        assertion = missingFirewallRoutedFrom == [ ];
        message = "Unknown VM names referenced by firewall routedFrom: ${toString (lib.unique missingFirewallRoutedFrom)}";
      }
      {
        assertion = missingProvidedFirewallRules == [ ];
        message = "Unknown firewall rule names referenced by VM provides: ${toString (lib.unique missingProvidedFirewallRules)}";
      }
      {
        assertion = missingNatReferences == [ ];
        message = "Unknown NAT rule names referenced by VM portForward: ${toString (lib.unique missingNatReferences)}";
      }
      {
        assertion = missingAssignedVlanRefs == [ ];
        message = "Unknown VLAN names referenced by VM assignedVlans: ${toString (lib.unique missingAssignedVlanRefs)}";
      }
      {
        assertion = config.my.infra.observability.lokiVM == "" || builtins.elem config.my.infra.observability.lokiVM topologyVmNames;
        message = "my.infra.observability.lokiVM must reference a VM in my.infra.topology.vms";
      }
    ];
  };
}
