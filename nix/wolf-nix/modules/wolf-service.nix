{ config, lib, pkgs, ... }:

let
  cfg = config.services.wolf;
  tomlFormat = pkgs.formats.toml { };
  generatedConfig = tomlFormat.generate "wolf-config.toml" cfg.settings;
  defaultPackage = pkgs.callPackage ../packages/wolf.nix { pkgs = pkgs; };
  configPath = "/etc/wolf/config.toml";
  usingManagedConfig = cfg.configFile != null || cfg.settings != { };
in
{
  options.services.wolf = {
    enable = lib.mkEnableOption "Games on Whales Wolf server";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/wolf.nix { pkgs = pkgs; }";
      description = "Wolf package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "wolf";
      description = "System user used for the wolf service.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "wolf";
      description = "System group used for the wolf service.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wolf";
      description = "Persistent state directory for wolf.";
    };

    settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      description = "Wolf config rendered to /etc/wolf/config.toml when non-empty.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to an existing config.toml. If set, settings is ignored.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line arguments passed to wolf.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the wolf service.";
    };

    enableDocker = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Docker and start wolf with access to docker.sock.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open Wolf/Moonlight ports.";
    };

    tcpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 47984 47989 48010 ];
      description = "TCP ports opened when openFirewall is enabled.";
    };

    udpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 47998 47999 48000 48002 48010 ];
      description = "UDP ports opened when openFirewall is enabled.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.configFile == null || cfg.settings == { };
          message = "Set either services.wolf.configFile or services.wolf.settings, not both.";
        }
      ];

      users.groups = lib.mkIf (cfg.group == "wolf") {
        wolf = { };
      };

      users.users = lib.mkIf (cfg.user == "wolf") {
        wolf = {
          isSystemUser = true;
          group = cfg.group;
          home = cfg.stateDir;
          createHome = true;
        };
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      ];

      environment.etc."wolf/config.toml" = lib.mkIf usingManagedConfig {
        source = if cfg.configFile != null then cfg.configFile else generatedConfig;
      };

      environment.systemPackages = [ cfg.package ];

      networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall cfg.tcpPorts;
      networking.firewall.allowedUDPPorts = lib.optionals cfg.openFirewall cfg.udpPorts;

      systemd.services.wolf = {
        description = "Games on Whales Wolf";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ] ++ lib.optional cfg.enableDocker "docker.service";
        wants = [ "network-online.target" ] ++ lib.optional cfg.enableDocker "docker.service";
        restartTriggers = lib.optional usingManagedConfig
          (if cfg.configFile != null then cfg.configFile else generatedConfig);

        path = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.util-linux
        ] ++ lib.optional cfg.enableDocker pkgs.docker;

        environment = {
          HOME = cfg.stateDir;
          XDG_RUNTIME_DIR = "/run/wolf";
        }
        // lib.optionalAttrs usingManagedConfig {
          WOLF_CFG_FILE = configPath;
        }
        // cfg.extraEnvironment;

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.stateDir;
          RuntimeDirectory = "wolf";
          RuntimeDirectoryMode = "0750";
          SupplementaryGroups = lib.optional cfg.enableDocker "docker";
          ExecStart =
            lib.concatStringsSep " "
              ([ "${cfg.package}/bin/wolf" ] ++ map lib.escapeShellArg cfg.extraArgs);
          Restart = "always";
          RestartSec = 5;
        };
      };
    }

    (lib.mkIf cfg.enableDocker {
      virtualisation.docker.enable = lib.mkDefault true;
    })
  ]);
}
