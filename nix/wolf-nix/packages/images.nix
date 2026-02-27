{ lib, pkgs, ... }:

let
  imageTag = "edge";
  imageSource = "https://github.com/games-on-whales/gow";

  mkPath = packages:
    lib.concatStringsSep ":" (lib.filter (entry: entry != "") [
      (lib.makeBinPath packages)
      (lib.makeSearchPathOutput "out" "sbin" packages)
      (lib.makeSearchPathOutput "bin" "sbin" packages)
    ]);

  writeExecutable = name: text:
    pkgs.writeTextFile {
      inherit name text;
      executable = true;
    };

  gowUtilsScript = pkgs.writeText "gow-utils.sh" ''
    gow_log() {
      echo "$(date +"[%Y-%m-%d %H:%M:%S]") $*"
    }
  '';

  entrypointScript = writeExecutable "gow-entrypoint.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    startup_script="''${GOW_STARTUP_SCRIPT:-/opt/gow/startup.sh}"
    init_dir="''${GOW_INIT_DIR:-/opt/gow/cont-init.d}"

    if [ "$(id -u)" = "0" ] && [ -d "$init_dir" ]; then
      for init_script in "$init_dir"/*.sh; do
        [ -e "$init_script" ] || continue
        gow_log "[ ''${init_script}: executing ]"
        source "$init_script"
      done
    fi

    if [ "$#" -gt 0 ]; then
      exec "$@"
    fi

    gow_log "Launching startup script '$startup_script' as user ''${UNAME:-root}"
    if [ "$(id -u)" = "0" ] && [ "''${UNAME:-root}" != "root" ]; then
      if ! id -u "''${UNAME}" >/dev/null 2>&1; then
        gow_log "User ''${UNAME} not available in container NSS; falling back to root"
      else
        target_uid="$(id -u "''${UNAME}")"
        target_gid="$(id -g "''${UNAME}")"
        target_home="''${HOME:-/home/''${UNAME}}"

        if [ -d "$target_home" ]; then
          chown -R "$target_uid:$target_gid" "$target_home" || gow_log "Unable to chown $target_home"
        fi

        # Prefer setpriv in immutable images: it does not require PAM/runuser setup.
        if command -v setpriv >/dev/null 2>&1; then
          exec setpriv --reuid "$target_uid" --regid "$target_gid" --init-groups bash "$startup_script"
        fi

        if command -v runuser >/dev/null 2>&1; then
          exec runuser -u "''${UNAME}" -- bash "$startup_script"
        fi

        gow_log "No user switching tool available; falling back to root"
      fi
    fi

    exec bash "$startup_script"
  '';

  startupScript = writeExecutable "gow-startup.sh" ''
    set -euo pipefail

    echo "ERROR: This script '$0' must be replaced with app startup commands. Exit!"
    exit 1
  '';

  ensureGroupsScript = writeExecutable "gow-ensure-groups.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    gow_log "Immutable NSS mode: skipping dynamic group/user edits"

    for dev in "$@"; do
      if [ -e "$dev" ]; then
        if [ "$(stat -c "%a" "$dev" | cut -c2)" -lt 6 ]; then
          chmod g+rw "$dev"
        fi
      else
        gow_log "Path '$dev' is not present."
      fi
    done
  '';

  setupUserScript = writeExecutable "gow-10-setup_user.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    gow_log "**** Configure default user ****"

    if [ "''${UNAME:-root}" != "root" ]; then
      user_name="''${UNAME:-root}"
      puid="''${PUID:-1000}"
      pgid="''${PGID:-1000}"
      umask_value="''${UMASK:-000}"
      home_dir="''${HOME:-/home/retro}"
      runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"

      gow_log "Setting default user uid=$puid($user_name) gid=$pgid($user_name)"
      gow_log "Immutable NSS mode: no runtime user/group mutation"
      if ! id -u "$user_name" >/dev/null 2>&1; then
        gow_log "User '$user_name' unavailable; forcing UNAME=root"
        export UNAME=root
      else
        gow_log "Using pre-baked user '$user_name'"
        gow_log "Setting umask to $umask_value"
        umask "$umask_value"
        mkdir -p "$home_dir"
        mkdir -p "$runtime_dir"
        chown -R "$puid:$pgid" "$home_dir"
        if [ "$runtime_dir" != "/tmp" ] && [ "$runtime_dir" != "/" ]; then
          chown -R "$puid:$pgid" "$runtime_dir"
        fi
      fi
    else
      gow_log "Container running as root. Nothing to do."
    fi

    gow_log "DONE"
  '';

  setupDevicesScript = writeExecutable "gow-15-setup_devices.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    gow_log "**** Configure devices ****"
    gow_log "Exec device groups"

    # shellcheck disable=SC2086
    bash /opt/gow/ensure-groups ''${GOW_REQUIRED_DEVICES:-/dev/uinput /dev/input/event*}

    gow_log "DONE"
  '';

  nvidiaInitScript = writeExecutable "gow-30-nvidia.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    add_env_prefix() {
      local var_name="$1"
      local value="$2"
      local current_value="''${!var_name:-}"
      if [ -n "$current_value" ]; then
        printf -v "$var_name" '%s:%s' "$value" "$current_value"
      else
        printf -v "$var_name" '%s' "$value"
      fi
      export "$var_name"
    }

    copy_tree() {
      local src="$1"
      local dst="$2"
      if [ -d "$src" ]; then
        cp -a "$src"/. "$dst"/
      fi
    }

    nvidia_prefix="''${GOW_NVIDIA_PREFIX:-}"
    if [ -z "$nvidia_prefix" ]; then
      for candidate in ''${GOW_NVIDIA_PREFIX_CANDIDATES:-/usr/nvidia /run/opengl-driver /run/nvidia}; do
        if [ -d "$candidate" ]; then
          nvidia_prefix="$candidate"
          break
        fi
      done
    fi

    if [ -z "$nvidia_prefix" ] || [ ! -d "$nvidia_prefix" ]; then
      gow_log "No NVIDIA runtime directory detected"
      exit 0
    fi

    gow_log "NVIDIA runtime detected at $nvidia_prefix"

    # Steam's FHS wrapper expects host-style runtime paths.
    mkdir -p /run
    if [ -L /run/opengl-driver ] && [ ! -e /run/opengl-driver ]; then
      rm -f /run/opengl-driver
    fi
    if [ ! -e /run/opengl-driver ]; then
      ln -s "$nvidia_prefix" /run/opengl-driver || true
    fi
    if [ -d "$nvidia_prefix/lib32" ] || [ -d "$nvidia_prefix/lib" ]; then
      if [ -L /run/opengl-driver-32 ] && [ ! -e /run/opengl-driver-32 ]; then
        rm -f /run/opengl-driver-32
      fi
      if [ ! -e /run/opengl-driver-32 ]; then
        ln -s "$nvidia_prefix" /run/opengl-driver-32 || true
      fi
    fi

    runtime_root="''${GOW_GRAPHICS_RUNTIME_DIR:-/tmp/gow-graphics}"
    vulkan_icd_dir="$runtime_root/vulkan/icd.d"
    egl_external_dir="$runtime_root/egl/egl_external_platform.d"
    egl_vendor_dir="$runtime_root/glvnd/egl_vendor.d"
    gbm_dir="$runtime_root/gbm"

    mkdir -p "$vulkan_icd_dir" "$egl_external_dir" "$egl_vendor_dir" "$gbm_dir"

    copy_tree "$nvidia_prefix/share/vulkan/icd.d" "$vulkan_icd_dir"
    copy_tree "$nvidia_prefix/share/egl/egl_external_platform.d" "$egl_external_dir"
    copy_tree "$nvidia_prefix/share/glvnd/egl_vendor.d" "$egl_vendor_dir"
    copy_tree "$nvidia_prefix/lib/gbm" "$gbm_dir"

    if [ ! -f "$vulkan_icd_dir/nvidia_icd.json" ]; then
      cat > "$vulkan_icd_dir/nvidia_icd.json" <<'JSON'
    {
      "file_format_version": "1.0.0",
      "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version": "1.3.242"
      }
    }
    JSON
    fi

    if [ ! -f "$egl_vendor_dir/10_nvidia.json" ]; then
      cat > "$egl_vendor_dir/10_nvidia.json" <<'JSON'
    {
      "file_format_version": "1.0.0",
      "ICD": {
        "library_path": "libEGL_nvidia.so.0"
      }
    }
    JSON
    fi

    if [ ! -f "$egl_external_dir/10_nvidia_wayland.json" ]; then
      cat > "$egl_external_dir/10_nvidia_wayland.json" <<'JSON'
    {
      "file_format_version": "1.0.0",
      "ICD": {
        "library_path": "libnvidia-egl-wayland.so.1"
      }
    }
    JSON
    fi

    if [ ! -f "$egl_external_dir/15_nvidia_gbm.json" ]; then
      cat > "$egl_external_dir/15_nvidia_gbm.json" <<'JSON'
    {
      "file_format_version": "1.0.0",
      "ICD": {
        "library_path": "libnvidia-egl-gbm.so.1"
      }
    }
    JSON
    fi

    if [ ! -e "$gbm_dir/nvidia-drm_gbm.so" ] && [ -f "$nvidia_prefix/lib/libnvidia-allocator.so.1" ]; then
      ln -sf "$nvidia_prefix/lib/libnvidia-allocator.so.1" "$gbm_dir/nvidia-drm_gbm.so"
    fi

    shopt -s nullglob
    icd_files=("$vulkan_icd_dir"/*.json)
    shopt -u nullglob
    if [ "''${#icd_files[@]}" -gt 0 ]; then
      icd_joined="$(IFS=:; echo "''${icd_files[*]}")"
      add_env_prefix VK_ICD_FILENAMES "$icd_joined"
    fi

    add_env_prefix __EGL_VENDOR_LIBRARY_DIRS "$egl_vendor_dir"
    add_env_prefix __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS "$egl_external_dir"
    add_env_prefix GBM_BACKENDS_PATH "$gbm_dir"

    lib_paths=()
    for lib_dir in "$nvidia_prefix/lib" "$nvidia_prefix/lib64" "$nvidia_prefix/lib32" "$gbm_dir"; do
      if [ -d "$lib_dir" ]; then
        lib_paths+=("$lib_dir")
      fi
    done

    if [ "''${#lib_paths[@]}" -gt 0 ]; then
      lib_joined="$(IFS=:; echo "''${lib_paths[*]}")"
      add_env_prefix LD_LIBRARY_PATH "$lib_joined"
    fi

    gow_log "NVIDIA runtime environment prepared in $runtime_root"
  '';

  baseAppStartupScript = writeExecutable "gow-base-app-startup.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    if [ -n "''${DISPLAY:-}" ]; then
      gow_log "Waiting for X server $DISPLAY"
      bash /opt/gow/wait-x11
    fi

    exec bash /opt/gow/startup-app.sh
  '';

  launchCompScript = writeExecutable "gow-launch-comp.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    launcher() {
      local cmd=("$@")

      export GAMESCOPE_WIDTH="''${GAMESCOPE_WIDTH:-1920}"
      export GAMESCOPE_HEIGHT="''${GAMESCOPE_HEIGHT:-1080}"
      export GAMESCOPE_REFRESH="''${GAMESCOPE_REFRESH:-60}"

      if [ -n "''${RUN_GAMESCOPE:-}" ]; then
        gow_log "[Gamescope] Starting: ''${cmd[*]}"
        gamescope_mode="''${GAMESCOPE_MODE:--b}"
        exec gamescope "$gamescope_mode" -W "$GAMESCOPE_WIDTH" -H "$GAMESCOPE_HEIGHT" -r "$GAMESCOPE_REFRESH" -- "''${cmd[@]}"
      fi

      if [ -n "''${RUN_SWAY:-}" ]; then
        gow_log "[Sway] Starting: ''${cmd[*]}"

        runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
        if [ ! -w "$runtime_dir" ]; then
          runtime_dir="/tmp"
        fi
        mkdir -p "$runtime_dir"
        chmod 700 "$runtime_dir" || true
        export XDG_RUNTIME_DIR="$runtime_dir"

        export SWAYSOCK="$XDG_RUNTIME_DIR/sway.socket"
        export SWAY_STOP_ON_APP_EXIT="''${SWAY_STOP_ON_APP_EXIT:-yes}"
        export XDG_CURRENT_DESKTOP=sway
        export XDG_SESSION_DESKTOP=sway
        export XDG_SESSION_TYPE=wayland

        # Use a per-launch writable config tree under /tmp.
        # XDG_RUNTIME_DIR may be inherited as /run/wolf, which is not writable in app containers.
        config_base="$(mktemp -d /tmp/gow-config.XXXXXX)"
        mkdir -p "$config_base/waybar" "$config_base/sway"
        export XDG_CONFIG_HOME="$config_base"

        if [ "''${GOW_DISABLE_WAYBAR:-0}" != "1" ]; then
          cp -u /cfg/waybar/* "$config_base/waybar/"
        fi

        install -m 0644 /cfg/sway/config "$config_base/sway/config"
        if [ "''${GOW_DISABLE_WAYBAR:-0}" = "1" ]; then
          ${pkgs.gnused}/bin/sed -i '/swaybar_command waybar/d' "$config_base/sway/config"
        fi
        echo "output * resolution ''${GAMESCOPE_WIDTH}x''${GAMESCOPE_HEIGHT} position 0,0" >> "$config_base/sway/config"

        app_cmd="$(printf '%q ' "''${cmd[@]}")"
        printf 'workspace main; exec %s' "$app_cmd" >> "$config_base/sway/config"
        if [ "$SWAY_STOP_ON_APP_EXIT" = "yes" ]; then
          printf ' && killall sway' >> "$config_base/sway/config"
        fi
        printf '\n' >> "$config_base/sway/config"

        if command -v dbus-run-session >/dev/null 2>&1 && dbus-run-session -- true >/dev/null 2>&1; then
          exec dbus-run-session -- sway --unsupported-gpu
        fi

        gow_log "[Sway] dbus-run-session unavailable or misconfigured; starting without a session bus"
        exec sway --unsupported-gpu
      fi

      gow_log "[exec] Starting: ''${cmd[*]}"
      exec "''${cmd[@]}"
    }
  '';

  waitX11Script = writeExecutable "gow-wait-x11.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/utils.sh

    if [ -z "''${DISPLAY:-}" ]; then
      gow_log "FATAL: No DISPLAY environment variable set"
      exit 13
    fi

    max_wait=120
    counter=0
    while ! xdpyinfo >/dev/null 2>&1; do
      sleep 1
      counter=$((counter + 1))
      if [ "$counter" -ge "$max_wait" ]; then
        gow_log "FATAL: gave up waiting for X server $DISPLAY"
        exit 11
      fi
    done
  '';

  firefoxStartupAppScript = writeExecutable "gow-firefox-startup-app.sh" ''
    set -euo pipefail

    source /opt/gow/launch-comp.sh

    home_dir="''${HOME:-/home/retro}"
    if [ ! -w "$home_dir" ] || { [ -e "$home_dir/.mozilla" ] && [ ! -w "$home_dir/.mozilla" ]; }; then
      home_dir="$(mktemp -d /tmp/gow-firefox-home.XXXXXX)"
      export HOME="$home_dir"
    fi
    mkdir -p "$home_dir/.mozilla"

    # Use a fresh profile to avoid corrupted or root-owned profile databases
    # from previous runs causing TLS/certificate failures.
    profile_dir="$(mktemp -d /tmp/gow-firefox-profile.XXXXXX)"
    cat > "$profile_dir/user.js" <<'EOF'
user_pref("security.enterprise_roots.enabled", true);
EOF
    launcher firefox --profile "$profile_dir"
  '';

  steamStartupAppScript = writeExecutable "gow-steam-startup-app.sh" ''
    set -euo pipefail

    source /opt/gow/launch-comp.sh

    home_dir="''${HOME:-/home/retro}"
    if [ ! -w "$home_dir" ] || { [ -e "$home_dir/.steam" ] && [ ! -w "$home_dir/.steam" ]; }; then
      home_dir="$(mktemp -d /tmp/gow-steam-home.XXXXXX)"
      export HOME="$home_dir"
    fi

    mkdir -p "$home_dir/.steam" "$home_dir/.local/share/Steam"
    export SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0

    startup_flags="''${STEAM_STARTUP_FLAGS:--bigpicture}"
    if [ -n "''${STEAM_STARTUP_URI:-}" ]; then
      startup_flags="$startup_flags ''${STEAM_STARTUP_URI}"
    fi

    if [ -n "$startup_flags" ]; then
      # shellcheck disable=SC2206
      steam_args=($startup_flags)
      steam_cmd=(steam "''${steam_args[@]}")
    else
      steam_cmd=(steam)
    fi

    launcher "''${steam_cmd[@]}"
  '';

  swayConfig = pkgs.writeText "gow-sway-config" ''
    set $mod Mod1

    default_border pixel 2
    gaps inner 4

    bindsym $mod+Return exec kitty
    bindsym Alt+F4 kill
    bindsym $mod+Shift+q kill
    bindsym $mod+Shift+c reload

    bar swaybar_command waybar

    # App command is appended by /opt/gow/launch-comp.sh
  '';

  waybarConfig = pkgs.writeText "gow-waybar-config.jsonc" ''
    {
      "layer": "top",
      "position": "top",
      "height": 28,
      "modules-left": ["sway/workspaces", "sway/window"],
      "modules-right": ["clock"],
      "clock": {
        "format": "{:%Y-%m-%d %H:%M}"
      }
    }
  '';

  waybarStyle = pkgs.writeText "gow-waybar-style.css" ''
    * {
      border: none;
      border-radius: 0;
      font-family: sans-serif;
      font-size: 12px;
    }

    window#waybar {
      background: #1e1e2e;
      color: #f5f5f5;
    }

    #workspaces button.focused {
      background: #3a3a5a;
    }
  '';

  baseAssets = pkgs.runCommand "gow-base-assets" { } ''
    mkdir -p "$out"

    install -Dm644 ${gowUtilsScript} "$out/opt/gow/bash-lib/utils.sh"
    install -Dm755 ${entrypointScript} "$out/opt/gow/entrypoint.sh"
    install -Dm755 ${startupScript} "$out/opt/gow/startup.sh"
    install -Dm755 ${ensureGroupsScript} "$out/opt/gow/ensure-groups"

    install -Dm755 ${setupUserScript} "$out/opt/gow/cont-init.d/10-setup_user.sh"
    install -Dm755 ${setupDevicesScript} "$out/opt/gow/cont-init.d/15-setup_devices.sh"
    install -Dm755 ${nvidiaInitScript} "$out/opt/gow/cont-init.d/30-nvidia.sh"
  '';

  baseAppAssets = pkgs.runCommand "gow-base-app-assets" { } ''
    mkdir -p "$out"

    install -Dm755 ${baseAppStartupScript} "$out/opt/gow/base-app-startup.sh"
    install -Dm755 ${launchCompScript} "$out/opt/gow/launch-comp.sh"
    install -Dm755 ${waitX11Script} "$out/opt/gow/wait-x11"

    install -Dm644 ${swayConfig} "$out/cfg/sway/config"
    install -Dm644 ${waybarConfig} "$out/cfg/waybar/config.jsonc"
    install -Dm644 ${waybarStyle} "$out/cfg/waybar/style.css"
  '';

  firefoxAssets = pkgs.runCommand "gow-firefox-assets" { } ''
    mkdir -p "$out"
    install -Dm755 ${firefoxStartupAppScript} "$out/opt/gow/startup-app.sh"
  '';

  steamAssets = pkgs.runCommand "gow-steam-assets" { } ''
    mkdir -p "$out"
    install -Dm755 ${steamStartupAppScript} "$out/opt/gow/startup-app.sh"
  '';

  basePackages = with pkgs; [
    bash
    coreutils
    findutils
    gnugrep
    gawk
    gnused
    util-linux
    shadow
    procps
    curl
    wget
    jq
    cacert
    p11-kit
    glibc.bin
    glibcLocales
  ];

  baseAppPackages = with pkgs; [
    dbus
    gamescope
    sway
    waybar
    xwayland
    xdpyinfo
    psmisc
    kitty
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    noto-fonts
    noto-fonts-cjk-sans
    font-awesome
    mesa
    libglvnd
    pulseaudio
    alsa-utils
  ];

  basePath = mkPath basePackages;
  baseAppPath = mkPath (basePackages ++ baseAppPackages);
  nixosFirefoxPath = "/run/current-system/sw/bin:/run/current-system/sw/sbin";
  steamSupported = pkgs.stdenv.hostPlatform.isx86_64 && (pkgs.config.allowUnfree or false);
  steamPackage =
    if steamSupported then
      pkgs.steam.override {
        # Needed by steamui.so (32-bit path) in this containerized setup.
        extraLibraries = p: with p; [ libxtst ];
      }
    else
      null;
  steamPath = if steamSupported then "${steamPackage}/bin:${nixosFirefoxPath}" else nixosFirefoxPath;

  nixosFirefoxSystem = import "${pkgs.path}/nixos" {
    system = pkgs.system;
    configuration = { pkgs, ... }: {
      boot.isContainer = true;
      networking.hostName = "wolf-firefox";
      system.stateVersion = "25.05";

      documentation.enable = false;
      documentation.man.enable = false;

      users.allowNoPasswordLogin = true;
      users.mutableUsers = false;
      users.groups.retro.gid = 1000;
      users.users.root.initialHashedPassword = "!";
      users.users.retro = {
        isNormalUser = true;
        uid = 1000;
        group = "retro";
        home = "/home/retro";
        createHome = true;
        initialHashedPassword = "!";
      };

      environment.systemPackages =
        (with pkgs; [
          bash
          coreutils
          findutils
          gnugrep
          gawk
          gnused
          util-linux
          shadow
          procps
          curl
          wget
          jq
          cacert
          p11-kit
          glibc.bin
          glibcLocales
          dbus
          gamescope
          sway
          waybar
          xwayland
          xdpyinfo
          psmisc
          kitty
          xdg-desktop-portal
          xdg-desktop-portal-gtk
          noto-fonts
          noto-fonts-cjk-sans
          font-awesome
          mesa
          libglvnd
          pulseaudio
          alsa-utils
          firefox
        ]);
    };
  };

  nixosFirefoxRootfs = pkgs.runCommand "wolf-firefox-nixos-rootfs" { } ''
    mkdir -p "$out"

    cp -a ${nixosFirefoxSystem.config.system.build.toplevel}/. "$out/"
    chmod u+w "$out"

    if [ -L "$out/etc" ] || [ -e "$out/etc" ]; then
      rm -rf "$out/etc"
    fi
    cp -a ${nixosFirefoxSystem.config.system.build.etc}/etc "$out/etc"
    chmod u+w "$out/etc"
    rm -f "$out/etc/passwd" "$out/etc/group" "$out/etc/nsswitch.conf"

    cat > "$out/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/var/empty:/bin/sh
retro:x:1000:1000:retro:/home/retro:/bin/sh
EOF

    cat > "$out/etc/group" <<'EOF'
root:x:0:
nobody:x:65534:
retro:x:1000:
EOF

    cat > "$out/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
services: files
protocols: files
ethers: files
rpc: files
EOF

    mkdir -p "$out/proc" "$out/sys" "$out/dev" "$out/run" "$out/home/retro" "$out/tmp/.X11-unix"
    chmod 1777 "$out/tmp" "$out/tmp/.X11-unix"
    ln -sfn ${nixosFirefoxSystem.config.system.build.toplevel} "$out/run/current-system"

    if [ ! -e "$out/bin" ]; then
      ln -s /run/current-system/sw/bin "$out/bin"
    fi
    if [ ! -e "$out/sbin" ]; then
      ln -s /run/current-system/sw/sbin "$out/sbin"
    fi
  '';

  commonBaseEnv = [
    "PUID=1000"
    "PGID=1000"
    "UMASK=000"
    "UNAME=root"
    "HOME=/home/retro"
    "TZ=UTC"
    "XDG_RUNTIME_DIR=/tmp"
    "GOW_INIT_DIR=/opt/gow/cont-init.d"
    "GOW_GRAPHICS_RUNTIME_DIR=/tmp/gow-graphics"
    "LOCALE_ARCHIVE=${pkgs.glibcLocales}/lib/locale/locale-archive"
    "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    "LANG=en_US.UTF-8"
  ];

  commonConfig = {
    Entrypoint = [ "${pkgs.bash}/bin/bash" "/opt/gow/entrypoint.sh" ];
    WorkingDir = "/home/retro";
    Labels = {
      "org.opencontainers.image.source" = imageSource;
    };
  };

  mkExtraDirs = ''
    mkdir -p tmp/.X11-unix home/retro root etc var/empty
    chmod 1777 tmp tmp/.X11-unix

    # NSS/p11-kit trust module reads CA anchors from distro-style /etc paths.
    # Provide those paths explicitly for Firefox (`SEC_ERROR_UNKNOWN_ISSUER` otherwise).
    mkdir -p etc/ssl/certs etc/pki/tls/certs var/lib/ca-certificates
    ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
    ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/pki/tls/certs/ca-bundle.crt
    ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt var/lib/ca-certificates/ca-bundle.pem
    ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/cert.pem

    mkdir -p etc/dbus-1/session.d etc/dbus-1/system.d
    rm -f etc/dbus-1/session.conf etc/dbus-1/system.conf
    ${pkgs.gnused}/bin/sed '/\/etc\/dbus-1\/session\.conf/d' \
      ${pkgs.dbus}/share/dbus-1/session.conf > etc/dbus-1/session.conf
    ${pkgs.gnused}/bin/sed '/\/etc\/dbus-1\/system\.conf/d' \
      ${pkgs.dbus}/share/dbus-1/system.conf > etc/dbus-1/system.conf

    cat > etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/var/empty:/bin/sh
retro:x:1000:1000:retro:/home/retro:/bin/sh
EOF

    cat > etc/group <<'EOF'
root:x:0:
nobody:x:65534:
retro:x:1000:
EOF

    cat > etc/nsswitch.conf <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
services: files
protocols: files
ethers: files
rpc: files
EOF
  '';

in
(rec {
  wolfBaseImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/base-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = basePackages ++ [ baseAssets ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${basePath}"
      ];
    };
    extraCommands = mkExtraDirs;
  };

  wolfBaseAppImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/base-app-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = basePackages ++ baseAppPackages ++ [ baseAssets baseAppAssets ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${baseAppPath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "GAMESCOPE_WIDTH=1920"
        "GAMESCOPE_HEIGHT=1080"
        "GAMESCOPE_REFRESH=60"
      ];
    };
    extraCommands = mkExtraDirs;
  };

  wolfFirefoxNixosImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/firefox-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = [
      nixosFirefoxRootfs
      baseAssets
      baseAppAssets
      firefoxAssets
    ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${nixosFirefoxPath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "UNAME=retro"
        "RUN_SWAY=1"
        "MOZ_ENABLE_WAYLAND=1"
      ];
    };
    extraCommands = ''
      mkdir -p tmp/.X11-unix
      chmod 1777 tmp tmp/.X11-unix
    '';
  };

  wolfFirefoxImage = wolfFirefoxNixosImage;

  wolfFirefoxApp = {
    title = "Firefox (Nix)";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png";
    runner = {
      type = "docker";
      name = "WolfFirefoxNix";
      image = "localhost/gow/firefox-nix:${imageTag}";
      mounts = [ ];
      env = [
        "UNAME=retro"
        "RUN_SWAY=1"
        "MOZ_ENABLE_WAYLAND=1"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = ''
        {
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN"],
            "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw"]
          }
        }
      '';
    };
  };

  wolfFirefoxWolfConfig = pkgs.writeText "wolf-firefox.config.toml" ''
    [[apps]]
    title = "Firefox (Nix)"
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png"

    [apps.runner]
    type = "docker"
    name = "WolfFirefoxNix"
    image = "localhost/gow/firefox-nix:${imageTag}"
    mounts = []
    env = ["UNAME=retro", "RUN_SWAY=1", "MOZ_ENABLE_WAYLAND=1", "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"]
    devices = []
    ports = []
    base_create_json = """
    {
      "HostConfig": {
        "IpcMode": "host",
        "Privileged": false,
        "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN"],
        "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw"]
      }
    }
    """
  '';
})
// lib.optionalAttrs steamSupported {
  wolfSteamImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/gow/steam-nix";
    tag = imageTag;
    maxLayers = 128;
    contents = [
      nixosFirefoxRootfs
      steamPackage
      baseAssets
      baseAppAssets
      steamAssets
    ];
    config = commonConfig // {
      Env = commonBaseEnv ++ [
        "PATH=${steamPath}"
        "GOW_STARTUP_SCRIPT=/opt/gow/base-app-startup.sh"
        "UNAME=retro"
        "RUN_SWAY=1"
        "STEAM_STARTUP_FLAGS=-bigpicture"
      ];
    };
    extraCommands = ''
      mkdir -p tmp/.X11-unix
      chmod 1777 tmp tmp/.X11-unix
    '';
  };

  wolfSteamApp = {
    title = "Steam (Nix)";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/steam/assets/icon.png";
    runner = {
      type = "docker";
      name = "WolfSteamNix";
      image = "localhost/gow/steam-nix:${imageTag}";
      mounts = [ ];
      env = [
        "UNAME=retro"
        "RUN_SWAY=1"
        "STEAM_STARTUP_FLAGS=-bigpicture"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "GOW_NVIDIA_PREFIX=/usr/nvidia"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = ''
        {
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
            "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
            "Devices": [{"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"}],
            "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
            "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 244:* rmw"]
          }
        }
      '';
    };
  };

  wolfSteamWolfConfig = pkgs.writeText "wolf-steam.config.toml" ''
    [[apps]]
    title = "Steam (Nix)"
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/steam/assets/icon.png"

    [apps.runner]
    type = "docker"
    name = "WolfSteamNix"
    image = "localhost/gow/steam-nix:${imageTag}"
    mounts = []
    env = ["UNAME=retro", "RUN_SWAY=1", "STEAM_STARTUP_FLAGS=-bigpicture", "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*", "GOW_NVIDIA_PREFIX=/usr/nvidia"]
    devices = []
    ports = []
    base_create_json = """
    {
      "HostConfig": {
        "IpcMode": "host",
        "Privileged": false,
        "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN", "SYS_ADMIN", "SYS_NICE", "SYS_PTRACE"],
        "SecurityOpt": ["label=disable", "apparmor=unconfined", "seccomp=unconfined"],
        "Devices": [{"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"}],
        "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
        "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 244:* rmw"]
      }
    }
    """
  '';
}
