{ config, lib, pkgs, ... }:

let
  cfg = config.services.wolf;
  tomlFormat = pkgs.formats.toml { };
  appOptionType = lib.types.submodule {
    freeformType = tomlFormat.type;
    options = { };
  };
  defaultPackage = pkgs.callPackage ../packages/wolf.nix { pkgs = pkgs; };
  packageWithDefaultConfigSource =
    if lib.hasAttrByPath [ "src" ] cfg.package then cfg.package else defaultPackage;
  defaultConfigIncludePath =
    "${packageWithDefaultConfigSource.src}/src/moonlight-server/state/default/config.include.toml";
  defaultConfigInclude = builtins.readFile defaultConfigIncludePath;
  defaultConfigToml = lib.removeSuffix ")for_c++_include\""
    (lib.removePrefix "R\"for_c++_include(\n" defaultConfigInclude);
  defaultSettings = builtins.fromTOML defaultConfigToml;
  appendExtraAppsToUserProfile = profiles:
    let
      userProfileId = "user";
      existingProfiles = if builtins.isList profiles then profiles else [ ];
      userProfileExists = lib.any (profile: (profile ? id) && profile.id == userProfileId) existingProfiles;
      patchedProfiles = builtins.map
        (profile:
          if (profile ? id) && profile.id == userProfileId then
            profile // {
              apps = (if profile ? apps && builtins.isList profile.apps then profile.apps else [ ]) ++ cfg.extraApps;
            }
          else
            profile)
        existingProfiles;
    in
    if userProfileExists then
      patchedProfiles
    else
      patchedProfiles ++ [ {
        id = userProfileId;
        name = "User";
        apps = cfg.extraApps;
      } ];
  generatedSettings =
    let
      mergedSettings = lib.recursiveUpdate defaultSettings cfg.settings;
    in
    if cfg.extraApps == [ ] then
      mergedSettings
    else
      mergedSettings // {
        profiles = appendExtraAppsToUserProfile (mergedSettings.profiles or [ ]);
      };
  generatedConfig = tomlFormat.generate "wolf-config.toml" generatedSettings;
  managedConfigSource = if cfg.configFile != null then cfg.configFile else generatedConfig;
  managedConfigPath = "${cfg.stateDir}/config.toml";
  pythonWithToml = pkgs.python3.withPackages (ps: [ ps.toml ]);
  managedConfigSeedOnceScript = pkgs.writeShellScript "wolf-config-seed-once" ''
    set -euo pipefail

    target_cfg=${lib.escapeShellArg managedConfigPath}
    source_cfg=${lib.escapeShellArg managedConfigSource}

    if [ -f "$target_cfg" ]; then
      ${pkgs.coreutils}/bin/chown ${cfg.user}:${cfg.group} "$target_cfg"
      ${pkgs.coreutils}/bin/chmod 0640 "$target_cfg"
      echo "Preserving existing Wolf config at $target_cfg (configWriteMode=seed-once)"
      exit 0
    fi

    ${pkgs.coreutils}/bin/install -D -m 0640 -o ${cfg.user} -g ${cfg.group} "$source_cfg" "$target_cfg"
  '';
  managedConfigMergePairingsScript = pkgs.writeShellScript "wolf-config-merge-pairings" ''
    set -euo pipefail

    target_cfg=${lib.escapeShellArg managedConfigPath}
    source_cfg=${lib.escapeShellArg managedConfigSource}
    tmp_cfg="$(${pkgs.coreutils}/bin/mktemp /tmp/wolf-config.XXXXXX.toml)"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp_cfg"' EXIT

    ${pythonWithToml}/bin/python - "$source_cfg" "$target_cfg" "$tmp_cfg" <<'PY'
import pathlib
import sys
import tomllib
import toml

source_path = pathlib.Path(sys.argv[1])
target_path = pathlib.Path(sys.argv[2])
output_path = pathlib.Path(sys.argv[3])

with source_path.open("rb") as source_file:
  merged_cfg = tomllib.load(source_file)

if target_path.exists():
  try:
    with target_path.open("rb") as target_file:
      current_cfg = tomllib.load(target_file)
  except Exception:
    current_cfg = {}

  if isinstance(current_cfg, dict):
    if "paired_clients" in current_cfg:
      merged_cfg["paired_clients"] = current_cfg["paired_clients"]
    if not merged_cfg.get("uuid") and current_cfg.get("uuid"):
      merged_cfg["uuid"] = current_cfg["uuid"]

output_path.write_text(toml.dumps(merged_cfg), encoding="utf-8")
PY

    ${pkgs.coreutils}/bin/install -D -m 0640 -o ${cfg.user} -g ${cfg.group} "$tmp_cfg" "$target_cfg"
    echo "Merged paired_clients from existing config into declarative config at $target_cfg"
  '';
  managedConfigInstallCommand =
    if cfg.configWriteMode == "replace" then
      "${pkgs.coreutils}/bin/install -D -m 0640 -o ${cfg.user} -g ${cfg.group} ${managedConfigSource} ${managedConfigPath}"
    else if cfg.configWriteMode == "seed-once" then
      "${managedConfigSeedOnceScript}"
    else
      "${managedConfigMergePairingsScript}";
  xdgRuntimeDir = "/run/wolf";
  gstPluginSystemPath = lib.concatStringsSep ":" [
    "${cfg.package}/lib/gstreamer-1.0"
    "${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0"
    "${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0"
    "${pkgs.gst_all_1.gst-plugins-bad}/lib/gstreamer-1.0"
    "${pkgs.gst_all_1.gst-plugins-ugly}/lib/gstreamer-1.0"
  ];
  nvidiaCudaLibraryPath = lib.makeLibraryPath [
    pkgs.cudaPackages.cuda_nvrtc
    pkgs.cudaPackages.libnpp
    pkgs.cudaPackages.cuda_cudart
  ];
  defaultEnvironment = {
    HOME = cfg.stateDir;
    XDG_RUNTIME_DIR = xdgRuntimeDir;
    GST_PLUGIN_SYSTEM_PATH_1_0 = gstPluginSystemPath;
    HOST_APPS_STATE_FOLDER = cfg.stateDir;
    WOLF_CFG_FOLDER = cfg.stateDir;
    WOLF_PRIVATE_KEY_FILE = "${cfg.stateDir}/key.pem";
    WOLF_PRIVATE_CERT_FILE = "${cfg.stateDir}/cert.pem";
    WOLF_RENDER_NODE = "/dev/dri/renderD128";
    WOLF_ENCODER_NODE = "/dev/dri/renderD128";
    WOLF_STOP_CONTAINER_ON_EXIT = "TRUE";
    WOLF_LOG_LEVEL = "INFO";
  } // lib.optionalAttrs cfg.nvidiaBundle.enable {
    LD_LIBRARY_PATH = nvidiaCudaLibraryPath;
  };

  nvidiaBundleEnabled = cfg.nvidiaBundle.enable;
  podmanImageArchives = lib.optionals cfg.podmanLoadImages cfg.podmanImages;
  podmanImageLoadingEnabled = podmanImageArchives != [ ];
  hostPulseAudioManaged =
    cfg.hostPulseAudio.enable && cfg.hostPulseAudio.manageService;
  hostPulseAudioSystemServiceEnabled =
    cfg.hostPulseAudio.enable && config.services.pulseaudio.enable && config.services.pulseaudio.systemWide;
  hostPulseAudioCookieAuthEnabled =
    hostPulseAudioSystemServiceEnabled && (!cfg.hostPulseAudio.anonymousSocket.enable);
  hostPulseAudioCookiePath = "/run/pulse/.config/pulse/cookie";
  wolfPulseCookiePath = "${cfg.stateDir}/pulse-cookie";
  uinputEnabled = config.hardware.uinput.enable;
  nvidiaCompatVulkanIcdFiles = [
    "asahi_icd.x86_64.json"
    "broadcom_icd.x86_64.json"
    "dzn_icd.x86_64.json"
    "freedreno_icd.x86_64.json"
    "gfxstream_vk_icd.x86_64.json"
    "intel_hasvk_icd.x86_64.json"
    "intel_icd.x86_64.json"
    "lvp_icd.x86_64.json"
    "nouveau_icd.x86_64.json"
    "panfrost_icd.x86_64.json"
    "powervr_mesa_icd.x86_64.json"
    "radeon_icd.x86_64.json"
    "virtio_icd.x86_64.json"
  ];
  nvidiaCompatVulkanIcdFilesShell = lib.concatStringsSep " " nvidiaCompatVulkanIcdFiles;

  podmanImageLoaderScript = ''
    set -euo pipefail
    stamp_dir=${lib.escapeShellArg "${cfg.stateDir}/.podman-image-stamps"}
    ${pkgs.coreutils}/bin/mkdir -p "$stamp_dir"
  '' + lib.concatMapStringsSep "\n" (image: ''
    archive=${lib.escapeShellArg (toString image)}
    stamp="$stamp_dir/${baseNameOf (toString image)}.loaded"
    if [ -f "$stamp" ]; then
      echo "Podman image archive already loaded, skipping: $archive"
    else
      echo "Loading Podman image archive: $archive"
      ${pkgs.podman}/bin/podman load -i "$archive"
      ${pkgs.coreutils}/bin/touch "$stamp"
    fi
  '') podmanImageArchives;

  nvidiaBundleHostSyncServiceName = "wolf-nvidia-driver-sync.service";
  nvidiaBundleRequiredServices = lib.optionals nvidiaBundleEnabled [ nvidiaBundleHostSyncServiceName ];
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
      description = ''
        TOML settings recursively merged onto Wolf upstream defaults when generating
        `${cfg.stateDir}/config.toml`.
      '';
    };

    extraApps = lib.mkOption {
      type = lib.types.listOf appOptionType;
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            title = "Firefox (Nix)";
            icon_png_path = "https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png";
            runner = {
              type = "docker";
              name = "WolfFirefoxNix";
              image = "gow/firefox-nix:edge";
              mounts = [ ];
              env = [ "RUN_SWAY=1" "MOZ_ENABLE_WAYLAND=1" ];
              devices = [ ];
              ports = [ ];
            };
          }
        ]
      '';
      description = ''
        Additional apps appended to profile `user` in the generated config.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an existing config.toml. If set, generated defaults/settings/extraApps
        are bypassed.
      '';
    };

    configWriteMode = lib.mkOption {
      type = lib.types.enum [ "merge-pairings" "seed-once" "replace" ];
      default = "merge-pairings";
      description = ''
        Controls how `${cfg.stateDir}/config.toml` is managed before Wolf starts.
        - `merge-pairings`: always apply declarative config, but carry over runtime `paired_clients`
          from the existing config file so Moonlight pairings survive restarts.
        - `seed-once`: create config from declarative source only when missing, then preserve runtime edits
          (for example `paired_clients` written by Wolf during pairing).
        - `replace`: always overwrite config from declarative source on service start.
      '';
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

    podmanSocketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/docker.sock";
      description = "Docker-compatible Podman socket path passed to Wolf as WOLF_DOCKER_SOCKET.";
    };

    podmanLoadImages = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Load image archives from services.wolf.podmanImages before starting Wolf.";
    };

    podmanImages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ inputs.wolf-nix.packages.${pkgs.system}.wolfFirefoxImage ]";
      description = "OCI archive derivations loaded into Podman with `podman load -i`.";
    };

    firefoxQuadlet = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create a Podman Quadlet service named `wolf-firefox` for the Firefox image.";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "localhost/gow/firefox-nix:edge";
        description = "Image reference used by the generated `wolf-firefox` Quadlet.";
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Auto-start the generated `wolf-firefox` Quadlet at boot.";
      };
    };

    nvidiaBundle = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Prepare `/usr/nvidia` host-bind mounts for Wolf app containers.";
      };

      hostPath = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.stateDir}/nvidia-driver";
        description = "Host directory bind-mounted as `/usr/nvidia` in app containers.";
      };

      sourcePath = lib.mkOption {
        type = lib.types.str;
        default = "/run/opengl-driver";
        description = "Host path copied into the prepared NVIDIA runtime tree.";
      };

      sourcePath32 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "/run/opengl-driver-32";
        description = ''
          Optional host path providing 32-bit GL/NVIDIA userspace libraries.
          When present, libraries are copied into `/usr/nvidia/lib32` for 32-bit apps
          such as Steam.
        '';
      };
    };

    wolfDen = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create a Podman Quadlet service named `wolf-den`.";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/games-on-whales/wolf-den:stable";
        description = "Image reference used by the generated `wolf-den` Quadlet.";
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Auto-start the generated `wolf-den` Quadlet at boot.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Host TCP port mapped to Wolf Den port 8080.";
      };

      stateSubDir = lib.mkOption {
        type = lib.types.str;
        default = "wolf-den";
        description = "Subdirectory under services.wolf.stateDir mounted as /app/wolf-den.";
      };

      socketPath = lib.mkOption {
        type = lib.types.str;
        default = "/var/run/wolf/wolf.sock";
        description = "Wolf socket path passed to Wolf Den via WOLF_SOCKET_PATH.";
      };
    };

    hostPulseAudio = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Use a host PulseAudio socket instead of Wolf's fallback PulseAudio container.
          When enabled, Wolf is pointed at a socket under XDG_RUNTIME_DIR and that socket
          is linked to hostPulseAudio.socketPath before startup.
        '';
      };

      manageService = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable and configure NixOS system-wide PulseAudio defaults for Wolf.
          Disable if another host-managed PulseAudio-compatible service is already provided.
        '';
      };

      socketPath = lib.mkOption {
        type = lib.types.str;
        default = "/run/pulse/native";
        description = "Host PulseAudio socket path that Wolf should connect to.";
      };

      wolfSocketPath = lib.mkOption {
        type = lib.types.str;
        default = "${xdgRuntimeDir}/pulse-socket";
        description = "Socket path exposed to Wolf and mounted into app containers as PULSE_SERVER.";
      };

      anonymousSocket = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Expose an additional host PulseAudio UNIX socket with anonymous auth for
            app containers. This avoids cookie mismatches for containerized clients.
          '';
        };

        path = lib.mkOption {
          type = lib.types.str;
          default = "/run/pulse/wolf-native";
          description = "Path of the additional anonymous PulseAudio socket on the host.";
        };
      };
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
          assertion = cfg.configFile == null || (cfg.settings == { } && cfg.extraApps == [ ]);
          message = "Set either services.wolf.configFile or generated-config options (services.wolf.settings/services.wolf.extraApps), not both.";
        }
        {
          assertion = cfg.configFile != null || builtins.pathExists defaultConfigIncludePath;
          message = "Could not find Wolf default config template in ${defaultConfigIncludePath}. Set services.wolf.configFile explicitly for this package.";
        }
        {
          assertion = (!cfg.hostPulseAudio.anonymousSocket.enable) || cfg.hostPulseAudio.enable;
          message = "services.wolf.hostPulseAudio.anonymousSocket.enable requires services.wolf.hostPulseAudio.enable = true.";
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

      environment.systemPackages = [ cfg.package pkgs.podman ];

      networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall cfg.tcpPorts;
      networking.firewall.allowedUDPPorts = lib.optionals cfg.openFirewall cfg.udpPorts;

      systemd.services.wolf = {
        description = "Games on Whales Wolf";
        wantedBy = [ "multi-user.target" ];
        after =
          [ "network-online.target" "podman.socket" ]
          ++ lib.optional hostPulseAudioSystemServiceEnabled "pulseaudio.service"
          ++ nvidiaBundleRequiredServices
          ++ lib.optional podmanImageLoadingEnabled "wolf-podman-images.service";
        wants =
          [ "network-online.target" "podman.socket" ]
          ++ lib.optional hostPulseAudioSystemServiceEnabled "pulseaudio.service"
          ++ nvidiaBundleRequiredServices
          ++ lib.optional podmanImageLoadingEnabled "wolf-podman-images.service";
        requires =
          lib.optional hostPulseAudioSystemServiceEnabled "pulseaudio.service"
          ++ nvidiaBundleRequiredServices;
        restartTriggers = [ managedConfigSource ];

        path = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.util-linux
          pkgs.podman
        ];

        environment = defaultEnvironment
        // {
          WOLF_DOCKER_SOCKET = cfg.podmanSocketPath;
          WOLF_DOCKER_FAKE_UDEV_PATH = "${cfg.package}/bin/fake-udev";
          WOLF_CFG_FILE = managedConfigPath;
        }
        // lib.optionalAttrs nvidiaBundleEnabled {
          NVIDIA_DRIVER_VOLUME_NAME = cfg.nvidiaBundle.hostPath;
        }
        // lib.optionalAttrs cfg.hostPulseAudio.enable {
          PULSE_SERVER = cfg.hostPulseAudio.wolfSocketPath;
        }
        // lib.optionalAttrs hostPulseAudioCookieAuthEnabled {
          PULSE_COOKIE = wolfPulseCookiePath;
        }
        // cfg.extraEnvironment;

        serviceConfig = {
          Type = "simple";
          PermissionsStartOnly = true;
          ExecStartPre = [
            "${pkgs.coreutils}/bin/mkdir -p ${xdgRuntimeDir}"
            "${pkgs.coreutils}/bin/chown ${cfg.user}:${cfg.group} ${xdgRuntimeDir}"
            "${pkgs.coreutils}/bin/chmod 0700 ${xdgRuntimeDir}"
          ] ++ lib.optionals nvidiaBundleEnabled [
            # Some NVIDIA setups expose /dev/nvidia-caps lazily; prime it deterministically.
            "${pkgs.bash}/bin/bash -lc 'if [ ! -e /dev/nvidia-caps/nvidia-cap1 ]; then ${config.hardware.nvidia.package.bin}/bin/nvidia-smi >/dev/null 2>&1 || true; fi'"
          ] ++ [
            "-${pkgs.coreutils}/bin/rm -f ${xdgRuntimeDir}/wayland-* ${xdgRuntimeDir}/.wayland-*"
            # Wolf can crash before tearing down this helper container; stale name blocks next boot.
            "-${pkgs.podman}/bin/podman rm -f WolfPulseAudio"
            # App container names are deterministic per session/app and can remain after crashes.
            "-${pkgs.bash}/bin/bash -lc '${pkgs.podman}/bin/podman ps -aq --filter name=^Wolf-UI_ | ${pkgs.findutils}/bin/xargs -r ${pkgs.podman}/bin/podman rm -f'"
            managedConfigInstallCommand
          ] ++ lib.optionals cfg.hostPulseAudio.enable [
            "${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg cfg.hostPulseAudio.socketPath} ${lib.escapeShellArg cfg.hostPulseAudio.wolfSocketPath}"
          ] ++ lib.optionals hostPulseAudioCookieAuthEnabled [
            "${pkgs.coreutils}/bin/install -D -m 0600 -o ${cfg.user} -g ${cfg.group} ${hostPulseAudioCookiePath} ${wolfPulseCookiePath}"
          ];
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.stateDir;
          RuntimeDirectory = "wolf";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          SupplementaryGroups =
            [ "podman" "input" "video" "render" ]
            ++ lib.optional uinputEnabled "uinput"
            ++ lib.optional hostPulseAudioCookieAuthEnabled "pulse-access";
          ExecStart =
            lib.concatStringsSep " "
              ([ "${cfg.package}/bin/wolf" ] ++ map lib.escapeShellArg cfg.extraArgs);
          Restart = "always";
          RestartSec = 5;
        };
      };

      systemd.services.wolf-podman-images = lib.mkIf podmanImageLoadingEnabled {
        description = "Load Nix-built Podman images for Wolf";
        after = [ "podman.socket" ];
        requires = [ "podman.socket" ];
        before = [ "wolf.service" ];
        restartTriggers = podmanImageArchives;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = podmanImageLoaderScript;
      };

      systemd.services.wolf-nvidia-driver-sync = lib.mkIf nvidiaBundleEnabled {
        description = "Prepare host NVIDIA runtime tree for Wolf app mounts";
        before = [ "wolf.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
        };
        script = ''
          set -euo pipefail

          source_dir=${lib.escapeShellArg cfg.nvidiaBundle.sourcePath}
          source_dir_32=${lib.escapeShellArg (if cfg.nvidiaBundle.sourcePath32 == null then "" else cfg.nvidiaBundle.sourcePath32)}
          target_dir=${lib.escapeShellArg cfg.nvidiaBundle.hostPath}

          if [ ! -r /sys/module/nvidia/version ]; then
            echo "ERROR: /sys/module/nvidia/version not readable; nvidia module not loaded?"
            exit 1
          fi

          if [ ! -d "$source_dir" ]; then
            echo "ERROR: NVIDIA source path is missing: $source_dir"
            exit 1
          fi
          if [ -n "$source_dir_32" ] && [ ! -d "$source_dir_32" ]; then
            echo "WARN: NVIDIA 32-bit source path is missing: $source_dir_32 (32-bit apps like Steam may fail)"
          fi

          has_lib_glob() {
            local pattern="$1"
            for lib_dir in "$target_dir/lib" "$target_dir/lib64"; do
              if ls "$lib_dir"/$pattern >/dev/null 2>&1; then
                return 0
              fi
            done
            return 1
          }

          has_lib32_glob() {
            local pattern="$1"
            if [ -d "$target_dir/lib32" ] && ls "$target_dir/lib32"/$pattern >/dev/null 2>&1; then
              return 0
            fi
            return 1
          }

          nv_version="$(cat /sys/module/nvidia/version)"
          current_version="$(cat "$target_dir/.nv_version" 2>/dev/null || true)"
          need_sync=1
          if [ "$current_version" = "$nv_version" ]; then
            need_sync=0
            echo "NVIDIA host tree already up to date ($nv_version), checking compatibility overlays"
          fi

          # Force a refresh when the prepared tree is incomplete even if NV version matches.
          if ! has_lib_glob "libEGL_nvidia.so*"; then
            need_sync=1
            echo "NVIDIA host tree missing libEGL_nvidia.so*, forcing refresh"
          fi
          if ! has_lib_glob "libGLX_nvidia.so*"; then
            need_sync=1
            echo "NVIDIA host tree missing libGLX_nvidia.so*, forcing refresh"
          fi
          if ! has_lib_glob "libnvidia-egl-wayland.so*"; then
            need_sync=1
            echo "NVIDIA host tree missing libnvidia-egl-wayland.so*, forcing refresh"
          fi
          if ! has_lib_glob "libnvidia-egl-gbm.so*" && ! has_lib_glob "libnvidia-allocator.so*"; then
            need_sync=1
            echo "NVIDIA host tree missing GBM bridge libraries, forcing refresh"
          fi
          if [ -n "$source_dir_32" ] && [ -d "$source_dir_32" ] && ! has_lib32_glob "libGLX_nvidia.so*"; then
            need_sync=1
            echo "NVIDIA host tree missing lib32/libGLX_nvidia.so*, forcing refresh"
          fi

          if [ "$need_sync" -eq 1 ]; then
            tmp_dir="/tmp/wolf-nvidia-driver-sync"
            rm -rf "$tmp_dir"
            mkdir -p "$tmp_dir" "$target_dir"

            # Nix driver trees can contain symlinks into /nix/store. Dereference so mount users
            # get a self-contained tree.
            cp -aL "$source_dir"/. "$tmp_dir"/
            if [ -n "$source_dir_32" ] && [ -d "$source_dir_32" ]; then
              mkdir -p "$tmp_dir/lib32"
              if [ -d "$source_dir_32/lib" ]; then
                cp -aL "$source_dir_32"/lib/. "$tmp_dir/lib32"/
              elif [ -d "$source_dir_32/lib32" ]; then
                cp -aL "$source_dir_32"/lib32/. "$tmp_dir/lib32"/
              else
                cp -aL "$source_dir_32"/. "$tmp_dir/lib32"/
              fi
            fi
            find "$target_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
            cp -a "$tmp_dir"/. "$target_dir"/
          fi

          # Compatibility shim for GoW app init scripts that copy a fixed list of ICD files.
          if [ -L "$target_dir/share/vulkan" ] && [ ! -e "$target_dir/share/vulkan" ]; then
            rm -f "$target_dir/share/vulkan"
          fi
          if [ -L "$target_dir/share/vulkan/icd.d" ] && [ ! -e "$target_dir/share/vulkan/icd.d" ]; then
            rm -f "$target_dir/share/vulkan/icd.d"
          fi

          nvidia_mount_lib_dir="/usr/nvidia/lib"
          if [ ! -f "$target_dir/lib/libEGL_nvidia.so.0" ] && [ -f "$target_dir/lib64/libEGL_nvidia.so.0" ]; then
            nvidia_mount_lib_dir="/usr/nvidia/lib64"
          fi
          nvidia_mount_lib32_dir="/usr/nvidia/lib32"
          if [ ! -f "$target_dir/lib32/libGLX_nvidia.so.0" ]; then
            nvidia_mount_lib32_dir="$nvidia_mount_lib_dir"
          fi

          icd_dir="$target_dir/share/vulkan/icd.d"
          mkdir -p "$icd_dir"
          cat > "$icd_dir/nvidia_icd.x86_64.json" <<JSON
          {
            "file_format_version": "1.0.1",
            "ICD": {
              "library_arch": "64",
              "library_path": "''${nvidia_mount_lib_dir}/libGLX_nvidia.so.0",
              "api_version": "1.4.312"
            }
          }
          JSON
          cat > "$icd_dir/nvidia_icd.i686.json" <<JSON
          {
            "file_format_version": "1.0.1",
            "ICD": {
              "library_arch": "32",
              "library_path": "''${nvidia_mount_lib32_dir}/libGLX_nvidia.so.0",
              "api_version": "1.4.312"
            }
          }
          JSON
          cp -f "$icd_dir/nvidia_icd.x86_64.json" "$icd_dir/nvidia_icd.json"

          for icd in ${nvidiaCompatVulkanIcdFilesShell}; do
            cp -f "$icd_dir/nvidia_icd.x86_64.json" "$icd_dir/$icd"
          done

          # Compatibility shims for GoW startup scripts and EGL loader discovery.
          if [ -L "$target_dir/share/egl" ] && [ ! -e "$target_dir/share/egl" ]; then
            rm -f "$target_dir/share/egl"
          fi
          if [ -L "$target_dir/share/egl/egl_external_platform.d" ] && [ ! -e "$target_dir/share/egl/egl_external_platform.d" ]; then
            rm -f "$target_dir/share/egl/egl_external_platform.d"
          fi
          if [ -L "$target_dir/share/glvnd" ] && [ ! -e "$target_dir/share/glvnd" ]; then
            rm -f "$target_dir/share/glvnd"
          fi
          if [ -L "$target_dir/share/glvnd/egl_vendor.d" ] && [ ! -e "$target_dir/share/glvnd/egl_vendor.d" ]; then
            rm -f "$target_dir/share/glvnd/egl_vendor.d"
          fi

          egl_external_dir="$target_dir/share/egl/egl_external_platform.d"
          egl_vendor_dir="$target_dir/share/glvnd/egl_vendor.d"
          mkdir -p "$egl_external_dir" "$egl_vendor_dir"

          cat > "$egl_vendor_dir/10_nvidia.json" <<JSON
          {
            "file_format_version": "1.0.0",
            "ICD": {
              "library_path": "''${nvidia_mount_lib_dir}/libEGL_nvidia.so.0"
            }
          }
          JSON

          cat > "$egl_external_dir/10_nvidia_wayland.json" <<JSON
          {
            "file_format_version": "1.0.0",
            "ICD": {
              "library_path": "''${nvidia_mount_lib_dir}/libnvidia-egl-wayland.so.1"
            }
          }
          JSON

          cat > "$egl_external_dir/15_nvidia_gbm.json" <<JSON
          {
            "file_format_version": "1.0.0",
            "ICD": {
              "library_path": "''${nvidia_mount_lib_dir}/libnvidia-egl-gbm.so.1"
            }
          }
          JSON

          for lib_dir in "$target_dir/lib" "$target_dir/lib64"; do
            if [ -d "$lib_dir" ]; then
              mkdir -p "$lib_dir/gbm"
              if [ ! -e "$lib_dir/gbm/nvidia-drm_gbm.so" ] && [ -f "$lib_dir/libnvidia-allocator.so.1" ]; then
                ln -sf ../libnvidia-allocator.so.1 "$lib_dir/gbm/nvidia-drm_gbm.so"
              fi
            fi
          done

          # Sanity checks: if these are missing, UI containers will usually crash while creating EGL/GLX displays.
          if ! has_lib_glob "libEGL_nvidia.so*"; then
            echo "ERROR: no libEGL_nvidia.so* found in $target_dir/lib or $target_dir/lib64 (source: $source_dir)"
            exit 1
          fi

          if ! has_lib_glob "libGLX_nvidia.so*"; then
            echo "ERROR: no libGLX_nvidia.so* found in $target_dir/lib or $target_dir/lib64 (source: $source_dir)"
            exit 1
          fi

          if [ -n "$source_dir_32" ] && [ -d "$source_dir_32" ] && ! has_lib32_glob "libGLX_nvidia.so*"; then
            echo "ERROR: no 32-bit libGLX_nvidia.so* found in $target_dir/lib32 (source: $source_dir_32)"
            exit 1
          fi

          if ! has_lib_glob "libnvidia-egl-wayland.so*"; then
            echo "ERROR: no libnvidia-egl-wayland.so* found in $target_dir/lib or $target_dir/lib64 (source: $source_dir)"
            exit 1
          fi

          has_gbm_lib=0
          if has_lib_glob "libnvidia-egl-gbm.so*" || has_lib_glob "libnvidia-allocator.so*" || \
             [ -e "$target_dir/lib/gbm/nvidia-drm_gbm.so" ] || [ -e "$target_dir/lib64/gbm/nvidia-drm_gbm.so" ]; then
            has_gbm_lib=1
          fi
          if [ "$has_gbm_lib" -eq 0 ]; then
            echo "ERROR: no usable NVIDIA GBM backend found in $target_dir (source: $source_dir)"
            exit 1
          fi

          has_egl_vendor_json=0
          if ls "$target_dir"/share/glvnd/egl_vendor.d/*.json >/dev/null 2>&1; then
            has_egl_vendor_json=1
          fi
          if [ "$has_egl_vendor_json" -eq 0 ]; then
            echo "ERROR: no EGL vendor JSON found in $target_dir/share/glvnd/egl_vendor.d (source: $source_dir)"
            exit 1
          fi

          has_egl_external_json=0
          if ls "$target_dir"/share/egl/egl_external_platform.d/*.json >/dev/null 2>&1; then
            has_egl_external_json=1
          fi
          if [ "$has_egl_external_json" -eq 0 ]; then
            echo "ERROR: no EGL external platform JSON found in $target_dir/share/egl/egl_external_platform.d (source: $source_dir)"
            exit 1
          fi

          echo "$nv_version" > "$target_dir/.nv_version"
          if [ "$need_sync" -eq 1 ]; then
            echo "Synced host NVIDIA tree to $target_dir ($nv_version)"
          else
            echo "NVIDIA host compatibility overlays refreshed in $target_dir"
          fi
        '';
      };

      virtualisation.quadlet = lib.mkIf (cfg.firefoxQuadlet.enable || cfg.wolfDen.enable) {
        enable = true;

        containers =
          lib.optionalAttrs cfg.firefoxQuadlet.enable {
            wolf-firefox = {
              autoStart = cfg.firefoxQuadlet.autoStart;
              serviceConfig = {
                Restart = "on-failure";
              };
              containerConfig = {
                image = cfg.firefoxQuadlet.image;
                environments = {
                  RUN_SWAY = "1";
                  MOZ_ENABLE_WAYLAND = "1";
                  GOW_REQUIRED_DEVICES = "/dev/input/* /dev/dri/* /dev/nvidia*";
                };
                addCapabilities = [ "NET_RAW" "MKNOD" "NET_ADMIN" ];
                podmanArgs = [
                  "--ipc=host"
                  "--device-cgroup-rule=c 13:* rmw"
                  "--device-cgroup-rule=c 244:* rmw"
                ];
              };
            };
          }
          // lib.optionalAttrs cfg.wolfDen.enable {
            "wolf-den" = {
              autoStart = cfg.wolfDen.autoStart;
              unitConfig = {
                After = [ "wolf.service" ];
                Requires = [ "wolf.service" ];
              };
              serviceConfig = {
                Restart = "always";
                RestartSec = "5s";
              };
              containerConfig = {
                image = cfg.wolfDen.image;
                publishPorts = [ "${toString cfg.wolfDen.port}:8080" ];
                volumes = [
                  "${cfg.stateDir}/${cfg.wolfDen.stateSubDir}:/app/wolf-den:rw"
                  "/var/run/wolf:/var/run/wolf:rw"
                ];
                environments = {
                  WOLF_SOCKET_PATH = cfg.wolfDen.socketPath;
                };
              };
            };
          };
      };
    }

    {
      hardware.uinput.enable = lib.mkDefault true;
      virtualisation.podman.enable = lib.mkDefault true;
      virtualisation.podman.dockerSocket.enable = lib.mkDefault true;
    }
    (lib.mkIf hostPulseAudioManaged {
      services.pulseaudio.enable = lib.mkDefault true;
      services.pulseaudio.systemWide = lib.mkDefault true;
      services.wolf.hostPulseAudio.socketPath = lib.mkIf cfg.hostPulseAudio.anonymousSocket.enable
        (lib.mkDefault cfg.hostPulseAudio.anonymousSocket.path);
      services.pulseaudio.extraConfig = lib.mkIf cfg.hostPulseAudio.anonymousSocket.enable (lib.mkAfter ''
        load-module module-native-protocol-unix socket=${cfg.hostPulseAudio.anonymousSocket.path} auth-anonymous=1
      '');
    })
  ]);
}
