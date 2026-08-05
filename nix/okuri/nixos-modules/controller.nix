# okuri controller: runs on the Jellyfin host. Stateless — the target host
# and fallback policy live in a generated config file, so there is no state
# database or imperative host registration (the rffmpeg failure mode this
# replaces).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.okuri;

  jsonFormat = pkgs.formats.json { };

  okuriConfig = {
    target = {
      ssh = "${cfg.sshPackage}/bin/ssh";
      host = cfg.targetHost;
      user = cfg.remoteUser;
      connect_timeout = cfg.connectTimeout;
      persist = cfg.persist;
      control_dir = "/run/okuri";
      ssh_args = [
        "-o" "StrictHostKeyChecking=accept-new"
        "-o" "UserKnownHostsFile=/var/lib/okuri/known_hosts"
        "-i" cfg.sshKeyPath
      ] ++ cfg.extraSshArgs;
    };
    local = {
      ffmpeg = "${cfg.localFfmpegPackage}/bin/ffmpeg";
      ffprobe = "${cfg.localFfmpegPackage}/bin/ffprobe";
    };
    fallback = {
      enable = cfg.fallback.enable;
      fast_fail_seconds = cfg.fallback.fastFailSeconds;
      preset_ceiling = cfg.fallback.presetCeiling;
    };
  };

  user = config.services.jellyfin.user;
  group = config.services.jellyfin.group;
in
{
  options.services.okuri = {
    enable = lib.mkEnableOption "okuri remote transcode dispatcher";

    package = lib.mkPackageOption pkgs "okuri" { };

    targetHost = lib.mkOption {
      type = lib.types.str;
      description = "SSH host that runs the GPU transcodes.";
      example = "okami.lan";
    };

    remoteUser = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
    };

    sshPackage = lib.mkPackageOption pkgs "openssh" { };

    sshKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/credentials/jellyfin.service/jellyfin_transcode_ssh_key";
      description = "Private key used to reach the target host.";
    };

    extraSshArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };

    connectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
    };

    persist = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 300;
      description = "ControlPersist lifetime in seconds (0 disables).";
    };

    # Must be reachable under the same path from the target host (shared
    # virtiofs staging in this fleet).
    tmpdir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/jellyfin/transcodes";
    };

    localFfmpegPackage = lib.mkPackageOption pkgs "jellyfin-ffmpeg" { };

    fallback = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Fall back to local software transcoding when the ssh transport fails fast.";
      };
      fastFailSeconds = lib.mkOption {
        type = lib.types.numbers.positive;
        default = 15;
      };
      presetCeiling = lib.mkOption {
        type = lib.types.enum [
          "ultrafast" "superfast" "veryfast" "faster" "fast"
          "medium" "slow" "slower" "veryslow" "placebo"
        ];
        default = "veryfast";
        description = "Slowest x264/x265 preset the software fallback may use.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Only the CLI goes on PATH: the package's ffmpeg/ffprobe shims must not
    # shadow (or be shadowed by) the real jellyfin-ffmpeg in a shell.
    environment.systemPackages = [
      (pkgs.runCommand "okuri-cli" { } ''
        mkdir -p $out/bin
        ln -s ${cfg.package}/bin/okuri $out/bin/okuri
      '')
    ];

    environment.etc."okuri/config.json".source =
      jsonFormat.generate "okuri-config.json" okuriConfig;

    systemd.tmpfiles.rules = [
      "d /run/okuri 0750 ${user} ${group} - -"
      "d /var/lib/okuri 0750 ${user} ${group} - -"
      "d ${cfg.tmpdir} 0755 ${user} ${group} - -"
    ];

    systemd.services.jellyfin.environment = {
      TMPDIR = toString cfg.tmpdir;
    };
  };
}
