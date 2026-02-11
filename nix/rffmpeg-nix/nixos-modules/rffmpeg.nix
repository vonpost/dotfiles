{ config, lib, pkgs, ... }:

let
  cfg = config.services.rffmpeg;

  yaml = pkgs.formats.yaml { };
  generatedConfig = yaml.generate "rffmpeg.yml" cfg.settings;

  configPath = "/etc/rffmpeg/rffmpeg.yml";

  initScript = pkgs.writeShellScript "rffmpeg-init" ''
    set -euo pipefail
    export RFFMPEG_CONFIG=${configPath}

    # If status works, we assume the state DB is already initialized.
    if ${cfg.package}/bin/rffmpeg status >/dev/null 2>&1; then
      exit 0
    fi

    ${cfg.package}/bin/rffmpeg init --no-root --yes

    ${lib.concatMapStringsSep "\n" (h: ''
      ${cfg.package}/bin/rffmpeg add ${lib.escapeShellArg h}
    '') cfg.hosts}
  '';
in
{
  options.services.rffmpeg = {
    enable = lib.mkEnableOption "rffmpeg remote transcoding wrapper";

    package = lib.mkPackageOption pkgs "rffmpeg" { };

    # Hosts you want rffmpeg to schedule onto (SSH targets)
    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "gpu-node-1" "gpu-node-2" ];
    };

    # Where Jellyfin should point TMPDIR (must be reachable from the GPU nodes)
    tmpdir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/jellyfin/transcodes";
    };

    # rffmpeg.yml (you can pass the upstream schema straight through)
    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {
        rffmpeg = {
          logging = {
            log_to_file = true;
            debug = true;
            logfile = "/var/lib/rffmpeg/rffmpeg.log";
          };
          directories = {
            state = "/var/lib/rffmpeg";
            persist = "/run/rffmpeg";
            owner = config.services.jellyfin.user;
            group = config.services.jellyfin.group;
          };
          remote = {
            user = "jellyfin";
            persist = 300;
            args = [
              "-o" "BatchMode=yes"
              "-o" "StrictHostKeyChecking=accept-new"
              "-o" "UserKnownHostsFile=/var/lib/rffmpeg/known_hosts"
              "-i" "/run/credentials/jellyfin.service/jellyfin_transcode_ssh_key"
            ];
          };
          commands = {
            ssh = "${pkgs.openssh}/bin/ssh";
            ffmpeg = "ffmpeg";
            ffprobe = "ffprobe";
            fallback_ffmpeg = "${pkgs.jellyfin-ffmpeg}/bin/ffmpeg";
            fallback_ffprobe = "${pkgs.jellyfin-ffmpeg}/bin/ffprobe";
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Config file location expected by most setups (/etc/rffmpeg/…)
    environment.etc."rffmpeg/rffmpeg.yml".source = generatedConfig;

    systemd.tmpfiles.rules = [
      "d /var/lib/rffmpeg 0750 ${config.services.jellyfin.user} ${config.services.jellyfin.group} - -"
      "d /run/rffmpeg 0755 ${config.services.jellyfin.user} ${config.services.jellyfin.group} - -"
      "d /var/log/jellyfin 0755 ${config.services.jellyfin.user} ${config.services.jellyfin.group} - -"
      "d ${cfg.tmpdir} 0755 ${config.services.jellyfin.user} ${config.services.jellyfin.group} - -"
    ];

    # One-shot: init state DB + add hosts (first boot / when state is empty)
    systemd.services.rffmpeg-init = {
      description = "Initialize rffmpeg state";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      restartTriggers = [ generatedConfig ];

      serviceConfig = {
        Type = "oneshot";
        User = config.services.jellyfin.user;
        Group = config.services.jellyfin.group;
        ExecStart = initScript;
      };
    };

    # Jellyfin-side env: TMPDIR (required for newer Jellyfin+rffmpeg setups) and RFFMPEG_CONFIG
    systemd.services.jellyfin.environment = {
      TMPDIR = toString cfg.tmpdir;
      RFFMPEG_CONFIG = configPath;
    };
  };
}
