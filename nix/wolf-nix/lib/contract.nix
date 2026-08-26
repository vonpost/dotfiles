# Single source of truth for the Wolf <-> app-container contract.
#
# Two kinds of facts live here:
#   [wolf]  hardcoded in the wolf binary; source refs are against upstream rev
#           7f416ec (the audited rev below) -- re-audit this file on pin bumps
#   [ours]  conventions this repo chooses, threaded through both the host
#           module and the app images/closures
#
# Consumers: modules/wolf-service.nix, and the wolfApp app modules (M3+).
rec {
  auditedWolfRev = "7f416ec0f26bb4d95218af806cd1181fe5434598";

  # [wolf] state/data-structures.hpp STANDARD_PORTS_MAPPING; each has a
  # WOLF_<NAME>_PORT env override.
  ports = rec {
    https = 47984; # tcp
    http = 47989; # tcp
    rtspSetup = 48010; # tcp
    control = 47999; # udp (ENet)
    videoPing = 48100; # udp (RTP video)
    audioPing = 48200; # udp (RTP audio)
    tcp = [ https http rtspSetup ];
    udp = [ control videoPing audioPing ];
  };

  host = rec {
    # [ours] HOST_APPS_STATE_FOLDER + WOLF_CFG_FOLDER (wolf default is /etc/wolf)
    stateDir = "/var/lib/wolf";
    # [ours] wolf's XDG_RUNTIME_DIR (systemd RuntimeDirectory=wolf)
    xdgRuntimeDir = "/run/wolf";
    # [wolf] api/api.cpp: REST + events unix socket at $XDG_RUNTIME_DIR/wolf.sock
    wolfSocket = "${xdgRuntimeDir}/wolf.sock";
    # [wolf] sessions/common.cpp:26-33: wolf takes the *basename* of the pulse
    # server path and bind-mounts $XDG_RUNTIME_DIR/<basename> into containers.
    # The GoW-established basename is `pulse-socket`; keep it.
    pulseSocket = "${xdgRuntimeDir}/pulse-socket";
    # [wolf] sessions/common.cpp:70-71: the mount SOURCE for the container's
    # fake-udev binary is $HOST_APPS_STATE_FOLDER/fake-udev. Wolf does NOT put
    # the binary there (WOLF_DOCKER_FAKE_UDEV_PATH is only an existence check,
    # runners/docker.cpp:66-67; upstream's Docker entrypoint does the copy).
    # The deployment must install the binary at this path itself.
    fakeUdevBinary = "${stateDir}/fake-udev";
  };

  container = {
    # [wolf] sessions/common.cpp:49: per-app state mount target (the full $HOME)
    home = "/home/retro";
    # [wolf] sessions/common.cpp:20 + wolf.cpp:183: the container's
    # XDG_RUNTIME_DIR is wolf's own runtime-dir *string*, so session sockets
    # appear at identical paths inside and outside the container.
    xdgRuntimeDir = host.xdgRuntimeDir;
    # [wolf] sessions/common.cpp:70-72
    fakeUdev = "/usr/bin/fake-udev";
    udevDir = "/run/udev";
    # [wolf] sessions/common.cpp:58-61: $NVIDIA_DRIVER_VOLUME_NAME mount target
    nvidiaDir = "/usr/nvidia";
  };

  # [wolf] sessions/common.cpp + runners/docker.cpp: env injected into every
  # session (values are per-session; names are the contract).
  injectedEnv = [
    "XDG_RUNTIME_DIR"
    "WOLF_SESSION_ID"
    "PULSE_SERVER"
    "PULSE_SINK"
    "PULSE_SOURCE"
    "GAMESCOPE_WIDTH"
    "GAMESCOPE_HEIGHT"
    "GAMESCOPE_REFRESH"
    "WOLF_VIDEO_BUFFER_CAPS"
    "WAYLAND_DISPLAY"
    "PUID"
    "PGID"
  ];

  # [wolf] runners/docker.cpp:247,275: hotplug is delivered by
  # `docker exec <ctr> /bin/bash -c "mknod ... && fake-udev -m ..."` as root.
  # Every app image MUST therefore provide /bin/bash at runtime.
  hotplugRequiresBash = true;

  # [wolf] core docker.cpp create(): base_create_json is used as the TOP-LEVEL
  # docker-create request body. Wolf overwrites Image/ExposedPorts, merges
  # Env/Binds/Devices, sets HostConfig.PortBindings, and rewrites
  # HostConfig.DeviceCgroupRules for input/hidraw from /proc/devices.
  # Everything else -- Entrypoint, Cmd, StopSignal, User, tmpfs, caps --
  # passes through untouched, so app definitions fully control them.
}
