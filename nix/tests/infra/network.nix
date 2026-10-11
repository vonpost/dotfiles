# These are configuration contracts, not packet-level tests. The rollout gate
# still requires network integration testing and real inbound health checks.
{ lib, nixosConfigurations }:
let
  gateway = nixosConfigurations.MAMORU.config;
  rules = gateway.networking.nftables.ruleset;
  reordered = (nixosConfigurations.MAMORU.extendModules {
    modules = [{ my.infra.vms.MAMORU.assignedVlans = lib.mkForce [ "dmz" "srv" "mgmt" ]; }];
  }).config;
  topo = import ../../lib/infra-topology.nix { topology = reordered.my.infra.topology; };
  standaloneTopo = import ../../lib/infra-topology.nix {
    topology = import ../../config/infra/topology.nix;
  };
  changedDns = (nixosConfigurations.DARE.extendModules {
    modules = [{ my.infra.vms.DARE.id = lib.mkForce 54; }];
  }).config;
  changedDnsTopo = import ../../lib/infra-topology.nix { topology = changedDns.my.infra.topology; };
  changedPorts = { lib, ... }: {
    my.infra.topology = {
      firewallRules.sabnzbd.port = lib.mkForce 1447;
      firewallRules.llama_server.port = lib.mkForce 8889;
      natRules.wireguard.externalPort = lib.mkForce 51823;
    };
  };
  downloads = (nixosConfigurations.KAIZOKU.extendModules { modules = [ changedPorts ]; }).config;
  digest = (nixosConfigurations.NIKKI.extendModules { modules = [ changedPorts ]; }).config;
  changedGateway = (nixosConfigurations.MAMORU.extendModules { modules = [ changedPorts ]; }).config;
  checks = {
    standaloneTopologyUsesInventory = standaloneTopo.getDns == "10.10.20.53"
      && standaloneTopo.getGateway "mgmt" == "10.10.10.10"
      && builtins.all (vm: standaloneTopo.getPrimaryIp vm == topo.getPrimaryIp vm
        && standaloneTopo.getMac vm "srv" == topo.getMac vm "srv")
        (builtins.attrNames gateway.my.infra.vms);
    evaluatedTopologyKeepsVmOverrides = changedDnsTopo.getDns == "10.10.20.54";
    primaryIndependentOfOrder = topo.getPrimaryIp "MAMORU" == "10.10.10.10";
    routedSonarrAllowed = lib.hasInfix
      "iifname dmz oifname srv ip saddr 10.10.30.25 ip daddr 10.10.20.20 tcp dport 8989 ct state new accept" rules;
    routedJellyfinAllowed = lib.hasInfix
      "iifname srv oifname dmz ip saddr 10.10.20.20 ip daddr 10.10.30.25 tcp dport 8096 ct state new accept" rules;
    unlistedRoutedJellyfinAbsent = !(lib.hasInfix
      "ip saddr 10.10.20.15 ip daddr 10.10.30.25 tcp dport 8096" rules);
    managementTrustPreserved = lib.hasInfix "iifname mgmt oifname srv ct state new accept" rules;
    sameSegmentUsesGuestPorts = builtins.elem 8989
      nixosConfigurations.UCHI.config.networking.firewall.allowedTCPPorts
      && !(lib.hasInfix "iifname srv oifname srv" rules);
    ipv6PolicyPreserved = lib.hasInfix "meta nfproto ipv6 drop" rules
      && lib.hasInfix ''iifname "dmz" oifname "wan" meta nfproto ipv6 tcp dport { 80, 443 }'' rules;
    serviceAndFirewallPortAgree = downloads.services.sabnzbd.settings.misc.port == 1447
      && builtins.elem 1447 downloads.networking.firewall.allowedTCPPorts;
    digestUsesEndpoint = digest.services.logDigest.port == 8889;
    hostWireguardNatUsesEndpoint = lib.hasInfix
      "iifname wan udp dport 51823 dnat to 10.10.10.99:51820"
      changedGateway.networking.nftables.ruleset;
  };
in
assert lib.assertMsg (builtins.all (x: x) (builtins.attrValues checks))
  "Network contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: x: !x) checks))}";
checks
