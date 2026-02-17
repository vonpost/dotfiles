{ hostname }:
{ lib, ... }:
let
  specs = import ./specs.nix;
  spec =
    if builtins.hasAttr hostname specs
    then specs.${hostname}
    else throw "Unknown VM '${hostname}' in config/infra/vms/specs.nix";
in
{
  imports = [
    (import ../../../common/vm-common.nix {
      inherit hostname;
      isJournalHost = spec.isJournalHost or false;
    })
  ];

  config = lib.mkMerge [
    (lib.optionalAttrs (spec ? vcpu) {
      microvm.vcpu = spec.vcpu;
    })
    (lib.optionalAttrs (spec ? mem) {
      microvm.mem = spec.mem;
    })
    (lib.optionalAttrs (spec ? hotplugMem) {
      microvm.hotplugMem = spec.hotplugMem;
    })
    (lib.optionalAttrs (spec ? networkDns) {
      my.infra.networkDns.enable = spec.networkDns;
    })
    (lib.optionalAttrs (spec ? networkGateway) {
      my.infra.networkGateway.enable = spec.networkGateway;
    })
  ];
}
