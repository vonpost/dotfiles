{ lib, config, ... }:
let
  cfg = config.my.microvmShares;
in
{
  options.my.microvmShares = lib.mkOption {
    # Keyed by share-name, e.g. "state", "nix-store", ...
    type = lib.types.attrsOf lib.types.anything;
    default = {};
    description = "Share definitions collected as an attrset to avoid duplicates.";
  };

  config = {
    # Convert the attrset -> list exactly once.
    microvm.shares = lib.attrValues cfg;
  };
}
