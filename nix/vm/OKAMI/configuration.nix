{ config, pkgs, lib, microvm, bleeding, ... }:
let
  svc = import ../../lib/vm-service-state.nix { inherit lib; };
  addrs = import ../../lib/lan-address.nix;

  hostname = "OKAMI";

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
in
{
  imports = [
    (svc.mkOne { name = "wolf"; })
  ];

  ## ─────────────────────────────────────────────
  ## microvm basics
  ## ─────────────────────────────────────────────

  microvm.hypervisor = "cloud-hypervisor";
  microvm.vcpu = 8;
  microvm.mem  = 32000;

  # microvm.devices = [
  #   { bus = "pci"; path = "0000:09:00.0"; } # GPU
  #   { bus = "pci"; path = "0000:09:00.1"; } # HDMI audio
  # ];

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
  ];

  # Mount the block volume directly where Docker expects it
  microvm.volumes = [
    {
      mountPoint = "/var/lib/docker";
      image = "${hostname}-docker.img";
      size = 40 * 1024; # MiB
      fsType = "ext4";
      autoCreate = true;
    }
  ];

  microvm.interfaces = [
    {
      type = "tap";
      id   = "vm-${hostname}";
      mac  = addrs.${hostname}.mac;
    }
  ];

  ## ─────────────────────────────────────────────
  ## Networking
  ## ─────────────────────────────────────────────

  networking.hostName = hostname;
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.enableIPv6 = false;
  networking.nameservers = [ addrs.DARE.ip ];
  networking.firewall.enable = false;

  systemd.network.enable = true;
  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = addrs.${hostname}.mac;
    networkConfig = {
      Address = "${addrs.${hostname}.ip}/24";
      Gateway = addrs.gateway.ip;
      DNS = [ addrs.DARE.ip ];
    };
    linkConfig.RequiredForOnline = "yes";
  };

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

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false; # required to be explicit on >= 560
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
    nvidiaPersistenced = true;
  };
  hardware.graphics.enable = true;

  ## ─────────────────────────────────────────────
  ## Docker (no CDI, no toolkit integration required for Wolf method)
  ## ─────────────────────────────────────────────

  virtualisation.docker.enable = true;
  virtualisation.docker.daemon.settings = {
    data-root = "/var/lib/docker";
  };

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

  # Create/populate the NVIDIA driver volume as per Wolf docs
  systemd.services.gow-nvidia-driver-vol = {
    description = "Populate NVIDIA driver volume for Wolf from /run/opengl-driver";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" ];
    requires = [ "docker.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "gow-nvidia-driver-vol" ''
        set -euo pipefail

        # Sanity: ensure NVIDIA is loaded
        test -r /sys/module/nvidia/version
        echo "NV_VERSION=$(cat /sys/module/nvidia/version)"

        # Ensure the volume exists
        ${docker} volume inspect nvidia-driver-vol >/dev/null 2>&1 || ${docker} volume create nvidia-driver-vol >/dev/null

        # Populate the volume from the NixOS driver runtime paths
        # (Alpine includes busybox cp; good enough. You can switch to coreutils if you prefer.)
        ${docker} run --rm \
          -v /run/opengl-driver:/src64:ro \
          -v /run/opengl-driver-32:/src32:ro \
          -v nvidia-driver-vol:/usr/nvidia:rw \
          alpine:latest sh -euxc '
            rm -rf /usr/nvidia/*

            mkdir -p /usr/nvidia
            cp -a /src64/. /usr/nvidia/

            # Put 32-bit libs under a predictable subdir
            mkdir -p /usr/nvidia/lib32
            cp -a /src32/lib/. /usr/nvidia/lib32/ || true

            # Ensure EGL/Vulkan config dirs exist (Wolf expects these paths)
            mkdir -p /usr/nvidia/share/glvnd/egl_vendor.d
            mkdir -p /usr/nvidia/share/egl/egl_external_platform.d
          '

        # Verify modeset flag (Wolf doc requirement)
        if [ -r /sys/module/nvidia_drm/parameters/modeset ]; then
          echo "nvidia_drm.modeset=$(cat /sys/module/nvidia_drm/parameters/modeset)"
        else
          echo "WARNING: nvidia_drm modeset parameter not present"
        fi
      '';
    };
  };

  systemd.services.wolf = {
    description = "Games on Whales – Wolf";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "docker.service"
      "gow-nvidia-driver-vol.service"
      "docker-load-wolf-desktop.service"
    ];
    requires = [
      "docker.service"
      "gow-nvidia-driver-vol.service"
      "docker-load-wolf-desktop.service"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Restart = "always";
      RestartSec = 2;

      ExecStartPre = [
        "${docker} pull ${wolfImage}"
        "-${docker} rm -f wolf"
      ];

      ExecStart = lib.concatStringsSep " " [
        docker "run"
        "--name" "wolf"
        "--rm"
        "--network=host"

        # Wolf manual NVIDIA driver volume method
        "-e" "NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol"
        "-v" "nvidia-driver-vol:/usr/nvidia:rw"

        "-v" "/etc/wolf:/etc/wolf:rw"
        "-v" "/var/run/docker.sock:/var/run/docker.sock:rw"

        # Devices (per Wolf docs)
        "--device" "/dev/nvidia-uvm"
        "--device" "/dev/nvidia-uvm-tools"
        "--device" "/dev/nvidia-caps/nvidia-cap1"
        "--device" "/dev/nvidia-caps/nvidia-cap2"
        "--device" "/dev/nvidiactl"
        "--device" "/dev/nvidia0"
        "--device" "/dev/nvidia-modeset"
        "--device" "/dev/dri/"
        "--device" "/dev/uinput"
        "--device" "/dev/uhid"
        "--device-cgroup-rule" ''"c 13:* rmw"''

        # Broad mounts the docs recommend
        "-v" "/dev:/dev:rw"
        "-v" "/run/udev:/run/udev:rw"

        wolfImage
      ];

      ExecStop = "-${docker} rm -f wolf";
    };
  };

  ## ─────────────────────────────────────────────
  ## Admin & debugging
  ## ─────────────────────────────────────────────

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg"
  ];

  environment.systemPackages = with pkgs; [
    pciutils
    vulkan-tools
    curl
  ];
}
