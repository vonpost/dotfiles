{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  infraServices = config.my.infra.services;
  infraVmServiceMounts = config.my.infra.vmServiceMounts;
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

  serviceType = types.submodule ({ name, config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
      };
      unit = mkOption {
        type = types.str;
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
      disableDynamicUser = mkOption {
        type = types.bool;
        default = true;
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
    };
  });

  vmServiceMountsType = types.submodule ({ ... }: {
    options = {
      machineId = mkOption {
        type = types.str;
        description = "Machine ID for the VM.";
      };
      serviceMounts = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  });

  firewallRuleType = types.submodule ({ ... }: {
    options = {
      port = mkOption { type = types.int; };
      proto = mkOption { type = types.enum [ "tcp" "udp" ]; };
      allowFrom = mkOption {
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

  vmTopologyType = types.submodule ({ ... }: {
    options = {
      id = mkOption { type = types.int; };
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
  });

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
        type = types.attrsOf vmTopologyType;
      };
      vlans = mkOption {
        type = types.attrsOf vlanType;
      };
    };
  });

  serviceNames = builtins.attrNames infraServices;
  vmConfigNames = builtins.attrNames infraVmServiceMounts;
  topologyVmNames = builtins.attrNames infraTopology.vms;
  firewallRuleNames = builtins.attrNames infraTopology.firewallRules;
  natRuleNames = builtins.attrNames infraTopology.natRules;

  missingVmConfigInTopology =
    builtins.filter (vm: !(builtins.elem vm topologyVmNames)) vmConfigNames;

  missingTopologyInVmConfig =
    builtins.filter (vm: !(builtins.elem vm vmConfigNames)) topologyVmNames;

  missingMountedServices =
    builtins.concatLists (
      lib.mapAttrsToList (_vm: vmCfg:
        builtins.filter (serviceName: !(builtins.elem serviceName serviceNames)) vmCfg.serviceMounts
      ) infraVmServiceMounts
    );

  missingFirewallAllowFrom =
    builtins.concatLists (
      lib.mapAttrsToList (_rule: ruleCfg:
        builtins.filter (vm: !(builtins.elem vm topologyVmNames)) ruleCfg.allowFrom
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

    vmServiceMounts = mkOption {
      type = types.attrsOf vmServiceMountsType;
      default = { };
      description = "Per-VM service assignments.";
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
  };

  config = {
    assertions = [
      {
        assertion = missingMountedServices == [ ];
        message = "Unknown service names in my.infra.vmServiceMounts: ${toString (lib.unique missingMountedServices)}";
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
        assertion = missingVmConfigInTopology == [ ];
        message = "VMs present in my.infra.vmServiceMounts but missing from my.infra.topology.vms: ${toString (lib.unique missingVmConfigInTopology)}";
      }
      {
        assertion = missingTopologyInVmConfig == [ ];
        message = "VMs present in my.infra.topology.vms but missing from my.infra.vmServiceMounts: ${toString (lib.unique missingTopologyInVmConfig)}";
      }
      {
        assertion = missingFirewallAllowFrom == [ ];
        message = "Unknown VM names referenced by firewall allowFrom: ${toString (lib.unique missingFirewallAllowFrom)}";
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
    ];
  };
}
