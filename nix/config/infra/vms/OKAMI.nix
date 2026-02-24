{ self, config, pkgs, lib, microvm, bleeding, wolf, ... }:
let
  hostname = "OKAMI";
  topology = config.my.infra.topology;
  sotoVm = topology.vms.SOTO;
  sotoPrimaryVlan = lib.head sotoVm.assignedVlans;
  sotoIp = "10.10.${toString topology.vlans.${sotoPrimaryVlan}.id}.${toString sotoVm.id}";

  docker = "${pkgs.docker}/bin/docker";
  wolfImage = "ghcr.io/games-on-whales/wolf:stable";

  sessionUser = "steam";
  sessionUID  = 1000;
  sessionGID  = 1000;
  sessionHome = "/home/${sessionUser}";
  wolfStateRoot = "/var/lib/wolf";
  wolfHomesRoot = "${wolfStateRoot}/home";
  wolfGamesRoot = "${wolfStateRoot}/games";

  desktopEntrypoint = pkgs.writeShellScript "wolf-desktop-entrypoint" ''
    set -euo pipefail

    export HOME="${sessionHome}"
    export USER="${sessionUser}"
    export LOGNAME="${sessionUser}"
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    mkdir -p "$HOME/.local/share" "$HOME/.config"

    # Redirect Steam game storage to /games (persisted, excluded from backups)
    if [ -d /games ]; then
    mkdir -p "$HOME/.local/share/Steam"
    if [ ! -e "$HOME/.local/share/Steam/steamapps" ]; then
    ln -s /games "$HOME/.local/share/Steam/steamapps"
    fi
    fi

    exec ${pkgs.dbus}/bin/dbus-run-session -- ${pkgs.fvwm}/bin/fvwm
  '';

  wolfDesktopImage = pkgs.dockerTools.buildImage {
    name = "local/wolf-desktop";
    tag  = "nix";

    copyToRoot = pkgs.buildEnv {
      name = "wolf-desktop-root";
      paths = [
        pkgs.bashInteractive
        pkgs.coreutils
        pkgs.dbus
        pkgs.fvwm
        pkgs.emacs
        pkgs.xterm
        pkgs.git
        pkgs.which
        pkgs.fontconfig
        pkgs.dejavu_fonts
      ];
      pathsToLink = [ "/bin" "/etc" "/lib" "/lib64" "/share" ];
    };

    config = {
      Entrypoint = [ "${desktopEntrypoint}" ];
      Env = [ "LANG=C.UTF-8" "LC_ALL=C.UTF-8" ];
      WorkingDir = "/tmp";
    };
  };
  curlbin   = "${pkgs.curl}/bin/curl";
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

  nvidiaDriverVol = "nvidia-driver-vol";
  # wolf-native = import ../../../common/wolf.nix {inherit pkgs config lib;};

in
{
  # systemd.services.wolf-dev.serviceConfig.ExecStart = "${wolf-native}/bin/wolf";
  services.wolf.enable = true;
  systemd.services.docker-build-nvidia-driver-image = {
    description = "Build Gow Nvidia driver bundle image (Wolf manual method)";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/tmp";
      # Allows reading /sys/module/nvidia/version
      ExecStart = pkgs.writeShellScript "build-nvidia-driver-image" ''
        set -euo pipefail

        if [ ! -r /sys/module/nvidia/version ]; then
        echo "ERROR: /sys/module/nvidia/version not readable; nvidia module not loaded?"
        exit 1
        fi

        NV_VERSION="$(cat /sys/module/nvidia/version)"
        echo "Detected NV_VERSION=$NV_VERSION"

        # Build versioned tag; also tag :latest for convenience
        ${curlbin} -fsSL https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile \
        | ${docker} build \
        -t gow/nvidia-driver:"$NV_VERSION" \
        -t gow/nvidia-driver:latest \
        -f - \
        --build-arg NV_VERSION="$NV_VERSION" \
        .

        # Record the version in the local image label (optional)
        echo "Built gow/nvidia-driver:$NV_VERSION"
      '';
    };
  };

  systemd.services.docker-populate-nvidia-driver-volume = {
    description = "Populate Docker volume with Nvidia driver bundle (Wolf manual method)";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" "docker-build-nvidia-driver-image.service" ];
    requires = [ "docker.service" "docker-build-nvidia-driver-image.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = pkgs.writeShellScript "populate-nvidia-driver-vol" ''
        set -euo pipefail

        NV_VERSION="$(cat /sys/module/nvidia/version)"
        echo "Target NV_VERSION=$NV_VERSION"
        VOL="${nvidiaDriverVol}"

        # Ensure volume exists
        if ! ${docker} volume inspect "$VOL" >/dev/null 2>&1; then
        echo "Creating volume $VOL"
        ${docker} volume create "$VOL" >/dev/null
        fi

        # Read existing version marker (if any)
        existing="$(${docker} run --rm -v "$VOL":/usr/nvidia:rw alpine:3.20 sh -lc 'cat /usr/nvidia/.nv_version 2>/dev/null || true' || true)"
        if [ "$existing" = "$NV_VERSION" ]; then
        echo "Volume already matches NV_VERSION=$NV_VERSION; nothing to do."
        exit 0
        fi

        echo "Volume version mismatch (existing='$existing', want='$NV_VERSION'); repopulating"

        # Nuke and recreate the volume to avoid stale files across driver upgrades
        ${docker} volume rm -f "$VOL" >/dev/null || true
        ${docker} volume create "$VOL" >/dev/null

        # Populate volume using the driver bundle image:
        # Equivalent to Wolf's: docker create --rm --mount source=VOL,destination=/usr/nvidia gow/nvidia-driver sh
        ${docker} create --rm --mount source="$VOL",destination=/usr/nvidia gow/nvidia-driver:"$NV_VERSION" sh >/dev/null

        # Write version marker inside the volume
        ${docker} run --rm -v "$VOL":/usr/nvidia:rw alpine:3.20 sh -lc 'echo "$0" > /usr/nvidia/.nv_version' "$NV_VERSION"

        echo "Populated $VOL with NV_VERSION=$NV_VERSION"
      '';
    };
  };

  imports = [
    ../../../lib/daily-llm-journal.nix
    (import ../../../common/vm-common.nix { hostname = hostname; isJournalHost = true; })
  ];

  ## ─────────────────────────────────────────────
  ## microvm basics
  ## ─────────────────────────────────────────────

  microvm.vcpu = 8;
  microvm.mem  = 16000;

  microvm.devices = [
    { bus = "pci"; path = "0000:09:00.0"; } # GPU
    { bus = "pci"; path = "0000:09:00.1"; } # HDMI audio
  ];

  # Mount the block volume directly where Docker expects it
  microvm.volumes = [
    {
      mountPoint = "/var/lib/docker";
      image = "/images/microvm/${hostname}-docker.img";
      size = 40 * 1024; # MiB
      fsType = "ext4";
      autoCreate = true;
    }
  ];

  ## ─────────────────────────────────────────────
  ## Users & persistent layout
  ## ─────────────────────────────────────────────

  users.users.${sessionUser} = {
    uid = sessionUID;
    isNormalUser = true;
    home = sessionHome;
    createHome = false;
    group = sessionUser;
  };
  users.groups.${sessionUser}.gid = sessionGID;

  systemd.tmpfiles.rules = [
    "d ${wolfStateRoot} 0755 wolf wolf -"
    "d ${wolfHomesRoot} 0755 root root -"
    "d ${wolfGamesRoot} 0755 root root -"
    "d ${wolfHomesRoot}/${sessionUser} 0700 ${sessionUser} ${sessionUser} -"
    "d ${wolfGamesRoot}/${sessionUser} 0750 ${sessionUser} ${sessionUser} -"
  ];

  fileSystems."${sessionHome}" = {
    device = "${wolfHomesRoot}/${sessionUser}";
    fsType = "none";
    options = [ "bind" ];
  };

  fileSystems."/games" = {
    device = "${wolfGamesRoot}/${sessionUser}";
    fsType = "none";
    options = [ "bind" ];
  };

  ## ─────────────────────────────────────────────
  ## NVIDIA (guest owns GPU via VFIO)
  ## ─────────────────────────────────────────────

  nixpkgs.config.allowUnfree = true;

  # Wolf docs requirement: ensure KMS is enabled and modeset=1
  boot.kernelParams = [ "nvidia_drm.modeset=1" ];
  boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];

  hardware.nvidia = {
    open = false; # required to be explicit on >= 560
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
  };
  hardware.graphics.enable = true;

  ## ─────────────────────────────────────────────
  ## Docker (no CDI, no toolkit integration required for Wolf method)
  ## ─────────────────────────────────────────────

  virtualisation.docker.enable = true;

  virtualisation.docker.daemon.settings = {
    data-root = "/var/lib/docker";
    iptables = true;
    ip-forward = true;
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };
  services.xserver.videoDrivers = ["nvidia"];

  # svc.mkOne forces wolf.service to run as user 'wolf', so grant docker socket access
  users.users.wolf.extraGroups = [ "docker" ];
  systemd.services.wolf.serviceConfig.SupplementaryGroups = [ "docker" ];

  # Optional: useful for debugging only (gives you nvidia-container-cli), not required by Wolf method
  # environment.systemPackages = [ pkgs.nvidia-container-toolkit ];

  ## ─────────────────────────────────────────────
  ## Wolf config
  ## ─────────────────────────────────────────────

  environment.etc."wolf/config.toml".text = ''
    # Add your [[apps]] here.
    # Image tag for your desktop:
    #   local/wolf-desktop:nix
  '';

  systemd.services.docker-load-wolf-desktop = {
    description = "Load Nix-built Wolf desktop image";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${docker} load -i ${wolfDesktopImage}";
    };
  };

  # Added to run nvidia-smi before running wolf to populate the required caps etc.
  systemd.services.nvidia-smi = {
    description = "Run nvidia-smi on boot to populate /dev/nvidia-caps. (BAND AID)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "root";
      Type = "oneshot";
      ExecStart = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
    };
  };

  # systemd.services.wolf = {
  #   description = "Games on Whales – Wolf";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [
  #     "network-online.target"
  #     "docker.service"
  #     "docker-populate-nvidia-driver-volume.service"
  #     "docker-load-wolf-desktop.service"
  #     "nvidia-smi.service"
  #   ];
  #   requires = [
  #     "docker.service"
  #     "docker-populate-nvidia-driver-volume.service"
  #     "docker-load-wolf-desktop.service"
  #   ];
  #   wants = [ "network-online.target" "nvidia-smi.service" ];

  #   serviceConfig = {
  #     Restart = "always";
  #     RestartSec = 5;

  #     ExecStartPre = [
  #       "${docker} pull ${wolfImage}"
  #       "-${docker} rm -f wolf"
  #       # This is needed to ensure nvidia-caps is loaded when mounting
  #     ];

  #     ExecStart = lib.concatStringsSep " " [
  #       docker "run"
  #       "--name" "wolf"
  #       "--rm"
  #       "--network=host"
  #       # Wolf manual method: driver bundle volume
  #       "-e" "NVIDIA_DRIVER_VOLUME_NAME=${nvidiaDriverVol}"
  #       "-e" "WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock"
  #       "-v" "/var/run/wolf:/var/run/wolf"


  #       "-v" "${nvidiaDriverVol}:/usr/nvidia:rw"

  #       "-v" "/var/lib/wolf:/etc/wolf:rw"

  #       "-v" "/var/run/docker.sock:/var/run/docker.sock:rw"


  #       # Devices (per Wolf docs)
  #       "--device" "/dev/nvidia-uvm"
  #       "--device" "/dev/nvidia-uvm-tools"
  #       "--device" "/dev/nvidia-caps/nvidia-cap1"
  #       "--device" "/dev/nvidia-caps/nvidia-cap2"
  #       "--device" "/dev/nvidiactl"
  #       "--device" "/dev/nvidia0"
  #       "--device" "/dev/nvidia-modeset"
  #       "--device" "/dev/dri/"
  #       "--device" "/dev/uinput"
  #       "--device" "/dev/uhid"
  #       "--device-cgroup-rule" ''"c 13:* rmw"''
  #       "-v" "/dev:/dev:rw"
  #       "-v" "/run/udev:/run/udev:rw"

  #       wolfImage
  #     ];

  #     ExecStop = "-${docker} rm -f wolf";
  #   };
  # };

  systemd.services.wolf-den = {
    description = "Games on Whales – Wolf Den";
    wantedBy = [ "multi-user.target" ];
    after = [
      "wolf.service"
    ];
    requires = [
      "wolf.service"
    ];

    serviceConfig = {
      Restart = "no";

      ExecStartPre = [
        "${docker} pull ghcr.io/games-on-whales/wolf-den:stable"
        "-${docker} rm -f wolf-den"
      ];

      ExecStart = lib.concatStringsSep " " [
        docker "run"
        "--name" "wolf-den"
        "--rm"
        "-p" "8080:8080"
        "-v" "/var/lib/wolf/wolf-den:/app/wolf-den:rw"
        "-v" "/var/run/wolf:/var/run/wolf"
        "-e" "WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock"
        "ghcr.io/games-on-whales/wolf-den:stable"
      ];

      ExecStop = "-${docker} rm -f wolf-den";
    };
  };

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
