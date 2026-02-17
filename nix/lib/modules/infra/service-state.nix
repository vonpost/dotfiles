{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.my.infra.state = {
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
