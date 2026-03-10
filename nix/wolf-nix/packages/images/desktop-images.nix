{ pkgs
, imageTag
, commonConfig
, commonBaseEnv
, basePath
, nixosGnomePath
, nixosLabwcPath
, nixosXfcePath
, nixosKdePath
, nixosPassThroughRootfs
, baseAssets
, baseAppAssets
, gnomeAssets
, labwcAssets
, labwcNoctaliaAssets
, xfceAssets
, kdeAssets
, materializeRuntimeTrees
, nixosGnomeSystemMount
, nixosLabwcSystemMount
, nixosXfceSystemMount
, nixosKdeSystemMount
}:

rec {
  wolfGnomeNixosImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/gnome-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = [
      nixosPassThroughRootfs
      baseAssets
      baseAppAssets
      gnomeAssets
    ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${basePath}:${nixosGnomePath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "UNAME=root"
      ];
    };
    extraCommands = materializeRuntimeTrees + ''
      mkdir -p tmp/.X11-unix
      chmod 1777 tmp tmp/.X11-unix
    '';
  };

  wolfGnomeImage = wolfGnomeNixosImage;
  wolfGnomeSystem = nixosGnomeSystemMount;

  wolfGnomeApp = {
    title = "GNOME Desktop (Nix)";
    icon_png_path = "https://upload.wikimedia.org/wikipedia/commons/2/2c/Adwaita-scalable-apps-preferences-desktop-remote-desktop-symbolic.svg";
    runner = {
      type = "docker";
      name = "WolfGnomeNix";
      image = "localhost/gow/gnome-nix:${imageTag}";
      mounts = [
        "/nix/store:/nix/store:ro"
        "/nix/var/nix/db:/nix/var/nix/db:ro"
        "/sys/fs/cgroup:/sys/fs/cgroup:rw"
      ];
      env = [
        "UNAME=root"
        "GOW_NIXOS_SYSTEM=${nixosGnomeSystemMount}"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = ''
        {
          "StopSignal": "RTMIN+3",
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CgroupnsMode": "host",
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
            "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
            "Devices": [
              {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
              {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
            ],
            "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
            "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
            "Tmpfs": {
              "/run": "rw,nosuid,nodev,size=64m,mode=755",
              "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
              "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
            }
          }
        }
      '';
    };
  };

  wolfGnomeWolfConfig = pkgs.writeText "wolf-gnome.config.toml" ''
    [[apps]]
    title = "GNOME Desktop (Nix)"
    icon_png_path = "https://upload.wikimedia.org/wikipedia/commons/2/2c/Adwaita-scalable-apps-preferences-desktop-remote-desktop-symbolic.svg"

    [apps.runner]
    type = "docker"
    name = "WolfGnomeNix"
    image = "localhost/gow/gnome-nix:${imageTag}"
    mounts = ["/nix/store:/nix/store:ro", "/nix/var/nix/db:/nix/var/nix/db:ro", "/sys/fs/cgroup:/sys/fs/cgroup:rw"]
    env = ["UNAME=root", "GOW_NIXOS_SYSTEM=${nixosGnomeSystemMount}", "GAMESCOPE_WIDTH=1920", "GAMESCOPE_HEIGHT=1080", "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*", "GOW_NVIDIA_PREFIX=/usr/nvidia"]
    devices = []
    ports = []
    base_create_json = """
    {
      "StopSignal": "RTMIN+3",
      "HostConfig": {
        "IpcMode": "host",
        "Privileged": false,
        "CgroupnsMode": "host",
        "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
        "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
        "Devices": [
          {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
          {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
        ],
        "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
        "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
        "Tmpfs": {
          "/run": "rw,nosuid,nodev,size=64m,mode=755",
          "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
          "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
        }
      }
    }
    """
  '';

  wolfLabwcImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/labwc-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = [
      nixosPassThroughRootfs
      baseAssets
      baseAppAssets
      labwcAssets
    ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${basePath}:${nixosLabwcPath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "UNAME=root"
      ];
    };
    extraCommands = materializeRuntimeTrees + ''
      mkdir -p tmp/.X11-unix
      chmod 1777 tmp tmp/.X11-unix
    '';
  };
  wolfLabwcSystem = nixosLabwcSystemMount;

  wolfLabwcApp = {
    title = "Labwc Desktop (Nix)";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png";
    runner = {
      type = "docker";
      name = "WolfLabwcNix";
      image = "localhost/gow/labwc-nix:${imageTag}";
      mounts = [
        "/nix/store:/nix/store:ro"
        "/nix/var/nix/db:/nix/var/nix/db:ro"
        "/sys/fs/cgroup:/sys/fs/cgroup:rw"
      ];
      env = [
        "UNAME=root"
        "GOW_NIXOS_SYSTEM=${nixosLabwcSystemMount}"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
        "GOW_LABWC_AUTOSTART_TERMINAL=1"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = ''
        {
          "StopSignal": "RTMIN+3",
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CgroupnsMode": "host",
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
            "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
            "Devices": [
              {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
              {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
            ],
            "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
            "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
            "Tmpfs": {
              "/run": "rw,nosuid,nodev,size=64m,mode=755",
              "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
              "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
            }
          }
        }
      '';
    };
  };

  wolfLabwcWolfConfig = pkgs.writeText "wolf-labwc.config.toml" ''
    [[apps]]
    title = "Labwc Desktop (Nix)"
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png"

    [apps.runner]
    type = "docker"
    name = "WolfLabwcNix"
    image = "localhost/gow/labwc-nix:${imageTag}"
    mounts = ["/nix/store:/nix/store:ro", "/nix/var/nix/db:/nix/var/nix/db:ro", "/sys/fs/cgroup:/sys/fs/cgroup:rw"]
    env = ["UNAME=root", "GOW_NIXOS_SYSTEM=${nixosLabwcSystemMount}", "GAMESCOPE_WIDTH=1920", "GAMESCOPE_HEIGHT=1080", "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*", "GOW_NVIDIA_PREFIX=/usr/nvidia", "GOW_LABWC_AUTOSTART_TERMINAL=1"]
    devices = []
    ports = []
    base_create_json = """
    {
      "StopSignal": "RTMIN+3",
      "HostConfig": {
        "IpcMode": "host",
        "Privileged": false,
        "CgroupnsMode": "host",
        "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
        "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
        "Devices": [
          {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
          {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
        ],
        "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
        "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
        "Tmpfs": {
          "/run": "rw,nosuid,nodev,size=64m,mode=755",
          "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
          "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
        }
      }
    }
    """
  '';

  wolfNoctaliaImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/noctalia-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = [
      nixosPassThroughRootfs
      baseAssets
      baseAppAssets
      labwcNoctaliaAssets
    ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${basePath}:${nixosLabwcPath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "UNAME=root"
      ];
    };
    extraCommands = materializeRuntimeTrees + ''
      mkdir -p tmp/.X11-unix
      chmod 1777 tmp tmp/.X11-unix
    '';
  };
  wolfNoctaliaSystem = wolfLabwcSystem;

  wolfNoctaliaApp = {
    title = "Noctalia Desktop (Nix)";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png";
    runner = {
      type = "docker";
      name = "WolfNoctaliaNix";
      image = "localhost/gow/noctalia-nix:${imageTag}";
      mounts = [
        "/nix/store:/nix/store:ro"
        "/nix/var/nix/db:/nix/var/nix/db:ro"
        "/sys/fs/cgroup:/sys/fs/cgroup:rw"
      ];
      env = [
        "UNAME=root"
        "GOW_NIXOS_SYSTEM=${nixosLabwcSystemMount}"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = ''
        {
          "StopSignal": "RTMIN+3",
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CgroupnsMode": "host",
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
            "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
            "Devices": [
              {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
              {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
            ],
            "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
            "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
            "Tmpfs": {
              "/run": "rw,nosuid,nodev,size=64m,mode=755",
              "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
              "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
            }
          }
        }
      '';
    };
  };

  wolfNoctaliaWolfConfig = pkgs.writeText "wolf-noctalia.config.toml" ''
    [[apps]]
    title = "Noctalia Desktop (Nix)"
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png"

    [apps.runner]
    type = "docker"
    name = "WolfNoctaliaNix"
    image = "localhost/gow/noctalia-nix:${imageTag}"
    mounts = ["/nix/store:/nix/store:ro", "/nix/var/nix/db:/nix/var/nix/db:ro", "/sys/fs/cgroup:/sys/fs/cgroup:rw"]
    env = ["UNAME=root", "GOW_NIXOS_SYSTEM=${nixosLabwcSystemMount}", "GAMESCOPE_WIDTH=1920", "GAMESCOPE_HEIGHT=1080", "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*", "GOW_NVIDIA_PREFIX=/usr/nvidia"]
    devices = []
    ports = []
    base_create_json = """
    {
      "StopSignal": "RTMIN+3",
      "HostConfig": {
        "IpcMode": "host",
        "Privileged": false,
        "CgroupnsMode": "host",
        "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
        "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
        "Devices": [
          {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
          {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
        ],
        "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
        "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
        "Tmpfs": {
          "/run": "rw,nosuid,nodev,size=64m,mode=755",
          "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
          "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
        }
      }
    }
    """
  '';

  wolfXfceImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/xfce-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = [
      nixosPassThroughRootfs
      baseAssets
      baseAppAssets
      xfceAssets
    ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${basePath}:${nixosXfcePath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "UNAME=root"
      ];
    };
    extraCommands = materializeRuntimeTrees + ''
      mkdir -p tmp/.X11-unix
      chmod 1777 tmp tmp/.X11-unix
    '';
  };
  wolfXfceSystem = nixosXfceSystemMount;

  wolfXfceApp = {
    title = "XFCE Desktop (Nix)";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png";
    runner = {
      type = "docker";
      name = "WolfXfceNix";
      image = "localhost/gow/xfce-nix:${imageTag}";
      mounts = [
        "/nix/store:/nix/store:ro"
        "/nix/var/nix/db:/nix/var/nix/db:ro"
        "/sys/fs/cgroup:/sys/fs/cgroup:rw"
      ];
      env = [
        "UNAME=root"
        "GOW_NIXOS_SYSTEM=${nixosXfceSystemMount}"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = ''
        {
          "StopSignal": "RTMIN+3",
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CgroupnsMode": "host",
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
            "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
            "Devices": [
              {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
              {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
            ],
            "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
            "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
            "Tmpfs": {
              "/run": "rw,nosuid,nodev,size=64m,mode=755",
              "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
              "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
            }
          }
        }
      '';
    };
  };

  wolfXfceWolfConfig = pkgs.writeText "wolf-xfce.config.toml" ''
    [[apps]]
    title = "XFCE Desktop (Nix)"
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png"

    [apps.runner]
    type = "docker"
    name = "WolfXfceNix"
    image = "localhost/gow/xfce-nix:${imageTag}"
    mounts = ["/nix/store:/nix/store:ro", "/nix/var/nix/db:/nix/var/nix/db:ro", "/sys/fs/cgroup:/sys/fs/cgroup:rw"]
    env = ["UNAME=root", "GOW_NIXOS_SYSTEM=${nixosXfceSystemMount}", "GAMESCOPE_WIDTH=1920", "GAMESCOPE_HEIGHT=1080", "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*", "GOW_NVIDIA_PREFIX=/usr/nvidia"]
    devices = []
    ports = []
    base_create_json = """
    {
      "StopSignal": "RTMIN+3",
      "HostConfig": {
        "IpcMode": "host",
        "Privileged": false,
        "CgroupnsMode": "host",
        "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
        "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
        "Devices": [
          {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
          {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
        ],
        "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
        "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
        "Tmpfs": {
          "/run": "rw,nosuid,nodev,size=64m,mode=755",
          "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
          "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
        }
      }
    }
    """
  '';

  wolfKdeNixosImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/kde-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = [
      nixosPassThroughRootfs
      baseAssets
      baseAppAssets
      kdeAssets
    ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${basePath}:${nixosKdePath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "UNAME=root"
      ];
    };
    extraCommands = materializeRuntimeTrees + ''
      mkdir -p tmp/.X11-unix
      chmod 1777 tmp tmp/.X11-unix
    '';
  };

  wolfKdeImage = wolfKdeNixosImage;
  wolfKdeSystem = nixosKdeSystemMount;

  wolfKdeApp = {
    title = "KDE Plasma Desktop (Nix)";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png";
    runner = {
      type = "docker";
      name = "WolfKdeNix";
      image = "localhost/gow/kde-nix:${imageTag}";
      mounts = [
        "/nix/store:/nix/store:ro"
        "/nix/var/nix/db:/nix/var/nix/db:ro"
        "/sys/fs/cgroup:/sys/fs/cgroup:rw"
      ];
      env = [
        "UNAME=root"
        "GOW_NIXOS_SYSTEM=${nixosKdeSystemMount}"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = ''
        {
          "StopSignal": "RTMIN+3",
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CgroupnsMode": "host",
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
            "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
            "Devices": [
              {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
              {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
            ],
            "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
            "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
            "Tmpfs": {
              "/run": "rw,nosuid,nodev,size=64m,mode=755",
              "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
              "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
            }
          }
        }
      '';
    };
  };

  wolfKdeWolfConfig = pkgs.writeText "wolf-kde.config.toml" ''
    [[apps]]
    title = "KDE Plasma Desktop (Nix)"
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png"

    [apps.runner]
    type = "docker"
    name = "WolfKdeNix"
    image = "localhost/gow/kde-nix:${imageTag}"
    mounts = ["/nix/store:/nix/store:ro", "/nix/var/nix/db:/nix/var/nix/db:ro", "/sys/fs/cgroup:/sys/fs/cgroup:rw"]
    env = ["UNAME=root", "GOW_NIXOS_SYSTEM=${nixosKdeSystemMount}", "GAMESCOPE_WIDTH=1920", "GAMESCOPE_HEIGHT=1080", "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*", "GOW_NVIDIA_PREFIX=/usr/nvidia"]
    devices = []
    ports = []
    base_create_json = """
    {
      "StopSignal": "RTMIN+3",
      "HostConfig": {
        "IpcMode": "host",
        "Privileged": false,
        "CgroupnsMode": "host",
        "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
        "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
        "Devices": [
          {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
          {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
        ],
        "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
        "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"],
        "Tmpfs": {
          "/run": "rw,nosuid,nodev,size=64m,mode=755",
          "/run/lock": "rw,nosuid,nodev,size=16m,mode=755",
          "/tmp": "rw,nosuid,nodev,size=1024m,mode=1777"
        }
      }
    }
    """
  '';
}
