{ lib, nixosConfigurations }:
let
  nikki = nixosConfigurations.NIKKI.config.services.vector.settings;
  mamoru = nixosConfigurations.MAMORU.config.services.vector.settings;
  okami = nixosConfigurations.OKAMI.config.services.vector.settings;
  configs = builtins.attrValues (builtins.removeAttrs nixosConfigurations [ "MOTHER" ]);
  checks = {
    bothDigestUnits = nikki.sources.log_logDigest_journal.include_units ==
      [ "logDigest.service" "logDigest-collect.service" ];
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
  };
in
assert lib.assertMsg (builtins.all (x: x) (builtins.attrValues checks))
  "Observability contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: x: !x) checks))}";
checks
