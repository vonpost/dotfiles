{ config, lib, ... }:
with lib;
let
  vmStorageOpts = { name, ... }: {
    options = {
      mounts = mkOption {
        type = types.attrsOf types.path;
        description = "Map staging relative path -> host source path (bind mounted).";
      };
      stagingRoot = mkOption {
        type = types.path;
        default = "/run/microvms-staging/${name}";
        readOnly = true;
      };
    };
  };
in
{
  options.my.microvm-storage = mkOption {
    type = types.attrsOf (types.submodule vmStorageOpts);
    default = {};
  };

  config = {
    systemd.tmpfiles.rules =
      flatten (mapAttrsToList (_vm: vmCfg:
        mapAttrsToList (rel: _src: [
          "d ${vmCfg.stagingRoot} 0755 root root -"
          "d ${vmCfg.stagingRoot}/${rel} 0755 root root -"
        ]) vmCfg.mounts
      ) config.my.microvm-storage);

    systemd.mounts =
      flatten (mapAttrsToList (vmName: vmCfg:
        mapAttrsToList (rel: src: {
          what = src;
          where = "${vmCfg.stagingRoot}/${rel}";
          type = "none";
          options = "rbind";
          before = [ "microvm@${vmName}.service" ];
          wantedBy = [ "microvm@${vmName}.service" ];
        }) vmCfg.mounts
      ) config.my.microvm-storage);
  };
}
