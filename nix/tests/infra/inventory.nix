{ lib, nixosConfigurations }:
let
  inventory = import ../../config/infra/inventory.nix;
  names = map (vm: vm.name) inventory;
  host = nixosConfigurations.MOTHER.config;
  overrides = { lib, ... }: {
    my.infra.vms.UCHI = {
      id = lib.mkForce 45;
      mem = lib.mkForce 4096;
      vcpu = lib.mkForce 6;
    };
  };
  changed = (nixosConfigurations.UCHI.extendModules { modules = [ overrides ]; }).config;
  changedHost = (nixosConfigurations.MOTHER.extendModules { modules = [ overrides ]; }).config;
  checks = {
    uniqueNames = builtins.length names == builtins.length (lib.unique names);
    uniqueIds = let ids = map (vm: vm.id) inventory;
      in builtins.length ids == builtins.length (lib.unique ids);
    sameFleet = builtins.attrNames host.my.infra.vms ==
      builtins.attrNames (builtins.removeAttrs nixosConfigurations [ "MOTHER" ]);
    autostartOrder = host.microvm.autostart ==
      # The pinned microvm host module appends its own list. Preserve the
      # existing result, including duplicates, during this structural change.
      [ "UCHI" "SOTO" "KAIZOKU" "DARE" "OKAMI" "MAMORU" "NIKKI"
        "DARE" "KAIZOKU" "MAMORU" "NIKKI" "OKAMI" "SOTO" "UCHI" ];
    resourcesUseInventory = changed.microvm.vcpu == 6 && changed.microvm.mem == 4096;
    identityUsesInventory = changed.microvm.vsock.cid == 45
      && changed.systemd.network.networks."20-srv".networkConfig.Address == "10.10.20.45/24"
      && changedHost.my.infra.topology.vms.UCHI.id == 45;
    rolesUseTopology = nixosConfigurations.MAMORU.config.my.infra.networkGateway.enable
      && nixosConfigurations.DARE.config.my.infra.networkDns.enable
      && !(nixosConfigurations.UCHI.config.my.infra.networkGateway.enable);
  };
in
assert lib.assertMsg (builtins.all (x: x) (builtins.attrValues checks))
  "Inventory contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: x: !x) checks))}";
checks
