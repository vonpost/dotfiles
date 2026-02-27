{ self, config, pkgs, lib, microvm, bleeding, wolf, ... }:
let
  hostname = "OKAMI";
  topology = config.my.infra.topology;
  sotoVm = topology.vms.SOTO;
  sotoPrimaryVlan = lib.head sotoVm.assignedVlans;
  sotoIp = "10.10.${toString topology.vlans.${sotoPrimaryVlan}.id}.${toString sotoVm.id}";
  wolfImagePackages = pkgs.callPackage ../../../wolf-nix/packages/images.nix { };

  limitedWrapper = pkgs.writeTextFile {
    name = "limited-wrapper.py";
    executable = true;
    destination = "/bin/limited-wrapper.py";
    text = ''
      #!${pkgs.python3}/bin/python3
      """Nix adaptation of rffmpeg hardening/limited-wrapper.py."""

      import logging
      import logging.handlers
      import os
      import shlex
      import shutil
      import sys
      from typing import List, Optional


      ALLOWED_BY_NAME = {
          "ffmpeg": "${pkgs.jellyfin-ffmpeg}/bin/ffmpeg",
          "ffprobe": "${pkgs.jellyfin-ffmpeg}/bin/ffprobe",
      }
      ALLOWED: List[str] = list(ALLOWED_BY_NAME.values())
      LOG_ALLOWED = os.environ.get("RFFMPEG_WRAPPER_LOG_ALLOWED", "0") == "1"
      LOG_DEBUG = os.environ.get("RFFMPEG_WRAPPER_DEBUG", "0") == "1"


      def setup_logger() -> logging.Logger:
          logger = logging.getLogger("limited-wrapper")
          logger.setLevel(logging.DEBUG)
          logger.handlers.clear()

          if sys.stdout.isatty():
              console = logging.StreamHandler(sys.stdout)
              console.setLevel(logging.WARNING)
              console.setFormatter(logging.Formatter("%(message)s"))
              logger.addHandler(console)
          else:
              try:
                  syslog = logging.handlers.SysLogHandler(address="/dev/log")
              except OSError:
                  syslog = logging.handlers.SysLogHandler(address=("localhost", 514))
              syslog.setLevel(logging.DEBUG)
              syslog.setFormatter(logging.Formatter("%(name)s: %(message)s"))
              logger.addHandler(syslog)
          return logger


      log = setup_logger()


      def log_msg(level: str, *msg: str) -> None:
          text = " ".join(msg)
          level = level.upper()
          full = f"{level} {text}"
          if level == "DEBUG":
              log.debug(full)
          elif level == "INFO":
              log.info(full)
          elif level in ("WARN", "WARNING"):
              log.warning(full)
          else:
              log.error(full)


      def resolve_binary(cmd: str) -> Optional[str]:
          # For plain command names, bypass PATH lookup and pin directly.
          if "/" not in cmd and cmd in ALLOWED_BY_NAME:
              return ALLOWED_BY_NAME[cmd]
          if "/" in cmd:
              path = cmd
          else:
              path = shutil.which(cmd)
          if not path:
              return None
          return os.path.realpath(path)


      def main() -> None:
          req_cmd = os.environ.get("SSH_ORIGINAL_COMMAND", "").strip()
          if not req_cmd:
              # SSH control sockets can open commandless sessions.
              sys.exit(0)

          try:
              args = shlex.split(req_cmd, posix=True)
          except ValueError as exc:
              log_msg("ERROR", f"Parse failed: {exc}")
              print("ERROR: could not parse command.")
              sys.exit(126)

          if not args:
              log_msg("ERROR", "Empty command after parsing.")
              print("ERROR: empty command.")
              sys.exit(126)

          bin_path = resolve_binary(args[0])
          if not bin_path:
              log_msg("WARN", f"Command not found: {args[0]}")
              print("ERROR: command not allowed.")
              sys.exit(126)

          if LOG_DEBUG:
              log_msg("DEBUG", f"Resolved command {args[0]} -> {bin_path}")

          if bin_path in ALLOWED:
              if LOG_ALLOWED:
                  log_msg("INFO", f"Allow {req_cmd}")
              args[0] = bin_path
              os.execv(bin_path, args)
              log_msg("ERROR", f"Exec failed: {req_cmd}")
              sys.exit(126)

          log_msg("WARN", f"Deny {req_cmd}")
          print("ERROR: command not allowed.")
          sys.exit(126)


      if __name__ == "__main__":
          main()
    '';
  };
  # wolf-native = import ../../../common/wolf.nix {inherit pkgs config lib;};

in
{
  # systemd.services.wolf-dev.serviceConfig.ExecStart = "${wolf-native}/bin/wolf";
  services.wolf = {
    enable = true;
    podmanLoadImages = true;
    podmanImages = [
      wolfImagePackages.wolfFirefoxImage
    ] ++ lib.optionals (wolfImagePackages ? wolfSteamImage) [
      wolfImagePackages.wolfSteamImage
    ];
    extraApps = [
      wolfImagePackages.wolfFirefoxApp
    ] ++ lib.optionals (wolfImagePackages ? wolfSteamApp) [
      wolfImagePackages.wolfSteamApp
    ];
    wolfDen.enable = true;
    hostPulseAudio.anonymousSocket.enable = true;
  };

  imports = [
    ../../../lib/daily-llm-journal.nix
    (import ../../../common/vm-common.nix { hostname = hostname; isJournalHost = true; })
  ];

  ## ─────────────────────────────────────────────
  ## microvm basics
  ## ─────────────────────────────────────────────

  microvm.vcpu = 12;
  microvm.mem  = 16000;

  microvm.devices = [
    { bus = "pci"; path = "0000:09:00.0"; } # GPU
    { bus = "pci"; path = "0000:09:00.1"; } # HDMI audio
  ];

  # Mount the block volume where Podman stores container state.
  microvm.volumes = [
    {
      mountPoint = "/var/lib/containers";
      image = "/images/microvm/${hostname}-containers.img";
      size = 40 * 1024; # MiB
      fsType = "ext4";
      autoCreate = true;
    }
  ];

  ## ─────────────────────────────────────────────
  ## NVIDIA (guest owns GPU via VFIO)
  ## ─────────────────────────────────────────────

  nixpkgs.config.allowUnfree = true;

  # Wolf docs requirement: ensure KMS is enabled and modeset=1
  boot.kernelParams = [ "nvidia_drm.modeset=1" ];
  boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" "fuse" ];

  hardware.nvidia = {
    open = false; # required to be explicit on >= 560
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
  };
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;

  ## ─────────────────────────────────────────────
  ## Podman
  ## ─────────────────────────────────────────────

  virtualisation.podman.enable = true;
  virtualisation.podman.dockerSocket.enable = true;

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };
  services.xserver.videoDrivers = ["nvidia"];

  ## ─────────────────────────────────────────────
  ## Admin & debugging
  ## ─────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    pciutils
    vulkan-tools
    curl
    config.hardware.nvidia.package.bin
    iptables
    tcpdump
    jellyfin-ffmpeg
    #wolf-native
  ];

  services.openssh.extraConfig = lib.mkAfter ''
    Match User jellyfin
      ForceCommand ${limitedWrapper}/bin/limited-wrapper.py
      PermitTTY yes
      X11Forwarding no
      AllowAgentForwarding no
      AllowTcpForwarding no
      AllowStreamLocalForwarding no
      PermitTunnel no
      PermitUserRC no
      GatewayPorts no
  '';

  users.users.jellyfin.openssh.authorizedKeys.keys = [ "from=\"${sotoIp}\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzH2Gt2Xs7mNeSpqNCJy2lwT19XC3OiSBNWBHK6zrzF dcol@TERRA" ];
  users.users.jellyfin.isSystemUser = lib.mkForce false;
  users.users.jellyfin.isNormalUser = lib.mkForce true;

  ## NON WOLF ###
  ##


  services.llama-cpp = {
    enable = true;
    package = bleeding.llama-cpp-vulkan;
    port = 8888;
    host = "0.0.0.0";
    model = null;
    modelsDir = "/var/lib/llama-cpp/models/";
    extraFlags = [
      "--jinja"
      "--sleep-idle-seconds" "30"
      "--models-max" "1"
    ];
  };

  services.dailyLlmJournal = {
    enable = true;
    url = "http://localhost";
    model = "gpt-oss-20b-MXFP4";
    port = 8888;
    logSlices = [
      {
        title = "PRIORITY: warning..emerg";
        filter = "-p warning..emerg";
      }
    ]
    ++ (map (service : { title = "UNIT: ${service} (info+)"; filter = "_SYSTEMD_UNIT=${service}.service"; })
      [
      "sshd"
      "nginx"
      "radarr"
      "sonarr"
      "jellyfin"
      ]
    );
  };
}
