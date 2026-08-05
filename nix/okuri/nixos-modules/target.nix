# okuri target: runs on the GPU node. Locks the transcode user's SSH access
# down to the okuri wrapper (ForceCommand), which allowlists ffmpeg/ffprobe
# and handles GPU-unhealthy fallback on this host's own CPU.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.okuri-target;

  jsonFormat = pkgs.formats.json { };

  targetConfig = {
    ffmpeg = "${cfg.ffmpegPackage}/bin/ffmpeg";
    ffprobe = "${cfg.ffmpegPackage}/bin/ffprobe";
    preflight_command =
      lib.optionals cfg.gpuPreflight.enable cfg.gpuPreflight.command;
    preflight_timeout = cfg.gpuPreflight.timeout;
    fast_fail_seconds = cfg.fastFailSeconds;
    force_software_file = "/run/okuri/force-software";
  };
in
{
  options.services.okuri-target = {
    enable = lib.mkEnableOption "okuri transcode target (GPU node side)";

    package = lib.mkPackageOption pkgs "okuri" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
      description = "User the controller connects as.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys allowed to dispatch transcodes.";
    };

    ffmpegPackage = lib.mkPackageOption pkgs "jellyfin-ffmpeg" { };

    gpuPreflight = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nvidia-smi" "-L" ];
        description = ''
          Command that exits 0 when the GPU is usable. A timeout or non-zero
          exit routes CUDA jobs to software on this host; a missing binary is
          treated as healthy (nothing to verify).
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.numbers.positive;
        default = 4;
      };
    };

    fastFailSeconds = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 20;
      description = ''
        A GPU attempt failing within this window (with a GPU error signature)
        is retried in software; later failures propagate to the caller.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."okuri/target.json".source =
      jsonFormat.generate "okuri-target.json" targetConfig;

    # force-software flag file lives here; root-owned on purpose.
    systemd.tmpfiles.rules = [ "d /run/okuri 0755 root root - -" ];

    users.users.${cfg.user} = {
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
      # sshd only grants logins to users with a real shell; the ForceCommand
      # still confines what the session can run.
      isSystemUser = lib.mkForce false;
      isNormalUser = lib.mkForce true;
    };

    services.openssh.extraConfig = lib.mkAfter ''
      Match User ${cfg.user}
        ForceCommand ${cfg.package}/bin/okuri-target
        PermitTTY no
        X11Forwarding no
        AllowAgentForwarding no
        AllowTcpForwarding no
        AllowStreamLocalForwarding no
        PermitTunnel no
        PermitUserRC no
        GatewayPorts no
        ClientAliveInterval 15
        ClientAliveCountMax 4
    '';
  };
}
