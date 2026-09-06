# Selected evaluated settings for comparing structural refactors.
# Excludes VM installer services and wolf service settings: their definitions
# force package builds even when selecting only identity fields. Shares, users
# and mounts on OKAMI are still covered. Keep IFD disabled when running this.
systems:
builtins.mapAttrs (_: system:
  let
    c = system.config;
    serviceNames = builtins.filter (name: name != null) (map (service: service.unit) (builtins.attrValues c.my.infra.services))
      ++ [ "sshd" "boot-reachable" "infra-net-rescue" ];
    services = builtins.intersectAttrs
      (builtins.listToAttrs (map (name: { inherit name; value = null; }) serviceNames))
      (builtins.removeAttrs c.systemd.services [ "wolf" ]);
  in {
    inherit (c) fileSystems;
    users = builtins.mapAttrs (_: u: {
      inherit (u) uid group extraGroups isSystemUser isNormalUser;
    }) c.users.users;
    groups = builtins.mapAttrs (_: g: { inherit (g) gid members; }) c.users.groups;
    systemd = {
      mounts = map (m: {
        inherit (m) what where type options before after requires wants wantedBy partOf bindsTo;
      }) c.systemd.mounts;
      tmpfiles = c.systemd.tmpfiles.rules;
      services = builtins.mapAttrs (_: s: {
        inherit (s) unitConfig after before requires wants wantedBy partOf bindsTo;
        serviceConfig = builtins.intersectAttrs {
          User = null; Group = null; DynamicUser = null; UMask = null;
          LoadCredential = null; StateDirectory = null; CacheDirectory = null;
        } s.serviceConfig;
      }) services;
      network = builtins.mapAttrs (_: unit: unit.text) c.systemd.network.units;
    };
    networking = {
      inherit (c.networking) hostName nameservers useDHCP useNetworkd enableIPv6;
      firewall = {
        inherit (c.networking.firewall) enable allowedTCPPorts allowedUDPPorts trustedInterfaces checkReversePath;
      };
      nftables = {
        inherit (c.networking.nftables) enable ruleset;
      };
    };
    boot = {
      inherit (c.boot) kernelParams;
      sysctl = c.boot.kernel.sysctl;
    };
    microvm = {
      autostart = c.microvm.autostart or [ ];
      vcpu = c.microvm.vcpu or null;
      mem = c.microvm.mem or null;
      hotplugMem = c.microvm.hotplugMem or null;
      vsockCid = c.microvm.vsock.cid or null;
      shares = map (s: { inherit (s) source mountPoint tag proto; }) (c.microvm.shares or []);
      interfaces = map (i: { inherit (i) type id mac; }) (c.microvm.interfaces or []);
    };
  }
) systems
