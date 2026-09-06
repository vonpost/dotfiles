{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  imports = [
    (lib.mkAliasOptionModule
      [ "my" "infra" "hostServiceMounts" "stageRoot" ]
      [ "my" "infra" "state" "stageRoot" ])
  ];

  options.my.infra.state = {
    stageRoot = mkOption {
      type = types.str;
      default = "/run/microvm-staging";
      description = "Host staging root exported through each VM's single state share.";
    };
    paths = {
      base = mkOption {
        type = types.str;
        default = "/state/services";
      };
      lib = mkOption {
        type = types.str;
        default = "./lib";
      };
      cache = mkOption {
        type = types.str;
        default = "./cache";
      };
      downloads = mkOption {
        type = types.str;
        default = "./downloads";
      };
      media = mkOption {
        type = types.str;
        default = "./media";
      };
      downloadsRoot = mkOption {
        type = types.str;
        default = "/omega/downloads";
      };
      mediaRoot = mkOption {
        type = types.str;
        default = "/omega/media";
      };
    };

    gids = {
      downloads = mkOption {
        type = types.int;
        default = 3000;
      };
      media = mkOption {
        type = types.int;
        default = 3001;
      };
    };
  };
}
