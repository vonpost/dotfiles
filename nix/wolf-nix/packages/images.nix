{ lib, pkgs, ... }:

let
  imageTag = "edge";
  imageSource = "https://github.com/games-on-whales/gow";
  # Pin Noctalia to 4.5.0 until this repo's nixpkgs catches up from 4.3.0.
  noctaliaShell = pkgs.noctalia-shell.overrideAttrs (_: rec {
    version = "4.5.0";
    src = pkgs.fetchFromGitHub {
      owner = "noctalia-dev";
      repo = "noctalia-shell";
      tag = "v${version}";
      hash = "sha256-Y5P0RYO9NKxa4UZBoGmmxtz3mEwJrBOfvdLJRGjV2Os=";
    };
  });

  mkPath = packages:
    lib.concatStringsSep ":" (lib.filter (entry: entry != "") [
      (lib.makeBinPath packages)
      (lib.makeSearchPathOutput "out" "sbin" packages)
      (lib.makeSearchPathOutput "bin" "sbin" packages)
    ]);

  writeExecutable = name: text:
    pkgs.writeShellScript name text;

  gowUtilsScript = pkgs.writeText "gow-utils.sh" ''
    gow_log() {
      echo "$(date +"[%Y-%m-%d %H:%M:%S]") $*"
    }
  '';

  desktopCompatLibScript = pkgs.writeText "gow-desktop-compat.sh" ''
    gow_add_env_prefix() {
      local var_name="$1"
      local value="$2"
      [ -n "$value" ] || return 0
      local current_value="''${!var_name:-}"
      if [ -n "$current_value" ]; then
        printf -v "$var_name" '%s:%s' "$value" "$current_value"
      else
        printf -v "$var_name" '%s' "$value"
      fi
      export "$var_name"
    }

    gow_pick_wayland_socket() {
      local socket_dir="''${1:-/run/wolf}"
      local sock n best best_n
      best=""
      best_n=-1

      shopt -s nullglob
      for sock in "$socket_dir"/wayland-*; do
        [ -S "$sock" ] || continue
        n="''${sock##*/wayland-}"
        if [ -z "$n" ] || [ "''${n//[0-9]/}" != "" ]; then
          continue
        fi
        if [ "$n" -gt "$best_n" ]; then
          best_n="$n"
          best="$sock"
        fi
      done
      shopt -u nullglob

      [ -n "$best" ] && printf '%s\n' "$best"
    }

    gow_wait_wayland_socket() {
      local socket_dir="''${1:-/run/wolf}"
      local retries="''${2:-50}"
      local delay="''${3:-0.1}"
      local sock

      for _ in $(seq 1 "$retries"); do
        sock="$(gow_pick_wayland_socket "$socket_dir" || true)"
        if [ -n "$sock" ]; then
          printf '%s\n' "$sock"
          return 0
        fi
        sleep "$delay"
      done
      return 1
    }

    gow_pick_runtime_wayland_socket_name() {
      local runtime_dir
      local sock n best best_n
      runtime_dir="$1"
      if [ -z "$runtime_dir" ]; then
        runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
      fi
      best=""
      best_n=-1

      shopt -s nullglob
      for sock in "$runtime_dir"/wayland-*; do
        [ -S "$sock" ] || continue
        n="''${sock##*/wayland-}"
        if [ -z "$n" ] || [ "''${n//[0-9]/}" != "" ]; then
          continue
        fi
        if [ "$n" -gt "$best_n" ]; then
          best_n="$n"
          best="$sock"
        fi
      done
      shopt -u nullglob

      [ -n "$best" ] && printf '%s\n' "''${best##*/}"
    }

    gow_wait_runtime_wayland_socket_name() {
      local runtime_dir="$1"
      local retries="''${2:-120}"
      local delay="''${3:-0.25}"
      local sock

      for _ in $(seq 1 "$retries"); do
        sock="$(gow_pick_runtime_wayland_socket_name "$runtime_dir" || true)"
        if [ -n "$sock" ]; then
          printf '%s\n' "$sock"
          return 0
        fi
        sleep "$delay"
      done
      return 1
    }

    gow_apply_common_ui_scale_defaults() {
      export GDK_SCALE="''${GDK_SCALE:-1}"
      export GDK_DPI_SCALE="''${GDK_DPI_SCALE:-1}"
      export QT_AUTO_SCREEN_SCALE_FACTOR="''${QT_AUTO_SCREEN_SCALE_FACTOR:-0}"
      export QT_SCALE_FACTOR="''${QT_SCALE_FACTOR:-1}"
    }

    gow_apply_common_xdg_defaults() {
      local default_config_dirs
      local default_data_dirs

      default_config_dirs="/run/current-system/sw/etc/xdg:/etc/xdg"
      default_data_dirs="/run/current-system/sw/share:/nix/var/nix/profiles/default/share:/etc/profiles/per-user/retro/share:/usr/local/share:/usr/share"

      export XDG_CONFIG_DIRS="''${XDG_CONFIG_DIRS:-$default_config_dirs}"
      export XDG_DATA_DIRS="''${XDG_DATA_DIRS:-$default_data_dirs}"
    }

    gow_apply_graphics_runtime_env() {
      local graphics_runtime nvidia_prefix
      local lib_dir

      graphics_runtime="''${GOW_GRAPHICS_RUNTIME_DIR:-/tmp/gow-graphics}"
      nvidia_prefix="''${GOW_NVIDIA_PREFIX:-/usr/nvidia}"

      if [ -d "$graphics_runtime/vulkan/icd.d" ]; then
        shopt -s nullglob
        icd_files=("$graphics_runtime"/vulkan/icd.d/*.json)
        shopt -u nullglob
        if [ "''${#icd_files[@]}" -gt 0 ]; then
          VK_ICD_FILENAMES="$(IFS=:; echo "''${icd_files[*]}")"
          export VK_ICD_FILENAMES
        fi
      fi

      if [ -d "$graphics_runtime/glvnd/egl_vendor.d" ]; then
        gow_add_env_prefix __EGL_VENDOR_LIBRARY_DIRS "$graphics_runtime/glvnd/egl_vendor.d"
      fi
      if [ -d "$graphics_runtime/egl/egl_external_platform.d" ]; then
        gow_add_env_prefix __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS "$graphics_runtime/egl/egl_external_platform.d"
      fi
      if [ -d "$graphics_runtime/gbm" ]; then
        gow_add_env_prefix GBM_BACKENDS_PATH "$graphics_runtime/gbm"
        if [ -e "$graphics_runtime/gbm/nvidia-drm_gbm.so" ]; then
          export GBM_BACKEND=nvidia-drm
        fi
      fi

      for lib_dir in "$nvidia_prefix/lib64" "$nvidia_prefix/lib" "$graphics_runtime/gbm" "$nvidia_prefix/lib32"; do
        if [ -d "$lib_dir" ]; then
          gow_add_env_prefix LD_LIBRARY_PATH "$lib_dir"
        fi
      done

      if [ -f "$nvidia_prefix/lib/libGLX_nvidia.so.0" ] || [ -f "$nvidia_prefix/lib64/libGLX_nvidia.so.0" ]; then
        export __GLX_VENDOR_LIBRARY_NAME=nvidia
      fi
    }

    gow_export_pulse_server_from_wolf() {
      if [ -S /run/wolf/pulse-socket ]; then
        export PULSE_SERVER=/run/wolf/pulse-socket
      fi
    }

    gow_wait_for_session_bus() {
      local bus_path="''${1:-/run/user/1000/bus}"
      local retries="''${2:-50}"
      local delay="''${3:-0.1}"
      for _ in $(seq 1 "$retries"); do
        [ -S "$bus_path" ] && return 0
        sleep "$delay"
      done
      return 1
    }

    gow_require_session_bus() {
      local bus_path="''${1:-/run/user/1000/bus}"
      local retries="''${2:-200}"
      local delay="''${3:-0.1}"
      if gow_wait_for_session_bus "$bus_path" "$retries" "$delay"; then
        return 0
      fi
      echo "[compat] session bus not ready at $bus_path"
      return 1
    }

    gow_sync_dbus_activation_environment() {
      local var_name
      local -a exported_vars=()

      command -v dbus-update-activation-environment >/dev/null 2>&1 || return 0

      for var_name in "$@"; do
        if [ -n "''${!var_name+x}" ]; then
          exported_vars+=("$var_name=''${!var_name}")
        fi
      done

      [ "''${#exported_vars[@]}" -gt 0 ] || return 0
      dbus-update-activation-environment --systemd "''${exported_vars[@]}" >/dev/null 2>&1 || return 1
      return 0
    }

    gow_export_logind_session_id() {
      local target_uid="''${1:-1000}"
      local target_user="''${2:-retro}"
      local seat_name="''${3:-seat0}"
      local sid suid suser sseat sclass stype sactive _

      [ -z "''${XDG_SESSION_ID:-}" ] || return 0

      while read -r sid suid suser sseat _; do
        [ -n "$sid" ] || continue
        case "$suid:$suser" in
          "$target_uid":*|*:"$target_user") ;;
          *) continue ;;
        esac
        [ "$sseat" = "$seat_name" ] || continue
        sclass="$(loginctl show-session "$sid" -p Class --value 2>/dev/null || true)"
        stype="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
        sactive="$(loginctl show-session "$sid" -p Active --value 2>/dev/null || true)"
        if [ "$sclass" = "user" ] && [ "$stype" = "wayland" ] && [ "$sactive" = "yes" ]; then
          export XDG_SESSION_ID="$sid"
          return 0
        fi
      done < <(loginctl --no-legend list-sessions 2>/dev/null || true)
      return 0
    }

    gow_detect_wolf_output_mode() {
      local socket mode_line
      socket="$1"
      [ -n "$socket" ] || return 1
      command -v wlr-randr >/dev/null 2>&1 || return 1
      command -v gawk >/dev/null 2>&1 || return 1
      mode_line="$(XDG_RUNTIME_DIR=/run/wolf WAYLAND_DISPLAY="''${socket##*/}" wlr-randr 2>/dev/null \
        | gawk '/[0-9]+x[0-9]+[[:space:]]+px[[:space:]]+\\(current\\)/ { print $1; exit }' || true)"
      [ -n "$mode_line" ] || return 1
      printf '%s\n' "$mode_line"
      return 0
    }

    gow_export_wolf_wayland_env() {
      local socket_dir="''${1:-/run/wolf}"
      local retries="''${2:-80}"
      local delay="''${3:-0.1}"
      local wolf_wayland_socket wolf_current_mode

      wolf_wayland_socket="$(gow_wait_wayland_socket "$socket_dir" "$retries" "$delay" || true)"
      if [ -z "$wolf_wayland_socket" ]; then
        return 1
      fi

      export WAYLAND_DISPLAY="$wolf_wayland_socket"
      export GOW_WOLF_WAYLAND_SOCKET="$wolf_wayland_socket"
      export GOW_WOLF_WAYLAND_DISPLAY="''${wolf_wayland_socket##*/}"
      export GOW_WOLF_WAYLAND_RUNTIME_DIR="''${wolf_wayland_socket%/*}"
      wolf_current_mode="$(gow_detect_wolf_output_mode "$wolf_wayland_socket" || true)"
      if [ -n "$wolf_current_mode" ]; then
        export GAMESCOPE_WIDTH="''${wolf_current_mode%x*}"
        export GAMESCOPE_HEIGHT="''${wolf_current_mode#*x}"
      fi
      return 0
    }

    gow_apply_wlr_output_scale_once() {
      local socket_name="$1"
      local scale="''${2:-1}"
      local custom_mode="''${3:-}"
      local log_file="''${4:-/tmp/gow-wlr-randr.log}"
      local runtime_dir="''${5:-}"
      local randr_state output_list output
      local -a cmd=()

      [ -n "$socket_name" ] || return 1
      command -v wlr-randr >/dev/null 2>&1 || return 1
      command -v gawk >/dev/null 2>&1 || return 1

      if [ -n "$runtime_dir" ]; then
        randr_state="$(XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY="$socket_name" wlr-randr 2>&1 || true)"
      else
        randr_state="$(WAYLAND_DISPLAY="$socket_name" wlr-randr 2>&1 || true)"
      fi
      if [ -n "$log_file" ]; then
        {
          if [ -n "$runtime_dir" ]; then
            echo "[wlr-randr] query XDG_RUNTIME_DIR=$runtime_dir WAYLAND_DISPLAY=$socket_name"
          else
            echo "[wlr-randr] query WAYLAND_DISPLAY=$socket_name"
          fi
          printf '%s\n' "$randr_state"
        } >>"$log_file"
      fi

      output_list="$(printf '%s\n' "$randr_state" | gawk '/^[^[:space:]]/ { print $1 }')"
      [ -n "$output_list" ] || return 1

      while IFS= read -r output; do
        [ -n "$output" ] || continue
        cmd=(wlr-randr --output "$output")
        if [ -n "$custom_mode" ]; then
          cmd+=(--custom-mode "$custom_mode")
        fi
        cmd+=(--scale "$scale")
        if [ -n "$runtime_dir" ]; then
          XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY="$socket_name" "''${cmd[@]}" >>"$log_file" 2>&1 || true
        else
          WAYLAND_DISPLAY="$socket_name" "''${cmd[@]}" >>"$log_file" 2>&1 || true
        fi
      done <<<"$output_list"

      return 0
    }

    gow_reconcile_wlr_output_scale() {
      local runtime_dir="$1"
      local retries="''${2:-120}"
      local delay="''${3:-0.25}"
      local scale="''${4:-1}"
      local custom_mode="''${5:-}"
      local log_file="''${6:-/tmp/gow-wlr-randr.log}"
      local socket

      for _ in $(seq 1 "$retries"); do
        socket="$(gow_pick_runtime_wayland_socket_name "$runtime_dir" || true)"
        if [ -z "$socket" ]; then
          sleep "$delay"
          continue
        fi
        if gow_apply_wlr_output_scale_once "$socket" "$scale" "$custom_mode" "$log_file"; then
          return 0
        fi
        sleep "$delay"
      done
      return 1
    }

    gow_maintain_wlr_output_scale() {
      local runtime_dir="$1"
      local loops="''${2:-240}"
      local delay="''${3:-0.5}"
      local scale="''${4:-1}"
      local custom_mode="''${5:-}"
      local log_file="''${6:-/tmp/gow-wlr-randr.log}"
      local socket

      for _ in $(seq 1 "$loops"); do
        socket="$(gow_pick_runtime_wayland_socket_name "$runtime_dir" || true)"
        if [ -n "$socket" ]; then
          gow_apply_wlr_output_scale_once "$socket" "$scale" "$custom_mode" "$log_file" || true
        fi
        sleep "$delay"
      done
      return 0
    }

    gow_guess_mode_from_gamescope() {
      local width="''${GAMESCOPE_WIDTH:-}"
      local height="''${GAMESCOPE_HEIGHT:-}"
      if [ -n "$width" ] && [ -n "$height" ]; then
        printf '%s\n' "''${width}x''${height}"
        return 0
      fi
      return 1
    }

    gow_reconcile_wolf_output_scale() {
      local socket_path="''${1:-''${GOW_WOLF_WAYLAND_SOCKET:-''${WAYLAND_DISPLAY:-}}}"
      local retries="''${2:-80}"
      local delay="''${3:-0.1}"
      local scale="''${4:-1}"
      local custom_mode="''${5:-''${GOW_WOLF_OUTPUT_MODE:-}}"
      local log_file="''${6:-/tmp/gow-wolf-randr.log}"
      local socket_name runtime_dir

      if [ -z "$socket_path" ]; then
        socket_path="$(gow_wait_wayland_socket /run/wolf "$retries" "$delay" || true)"
      fi
      [ -n "$socket_path" ] || return 1

      socket_name="''${socket_path##*/}"
      runtime_dir="''${socket_path%/*}"
      if [ "$runtime_dir" = "$socket_path" ]; then
        runtime_dir="''${GOW_WOLF_WAYLAND_RUNTIME_DIR:-/run/wolf}"
      fi

      if [ -z "$custom_mode" ]; then
        custom_mode="$(gow_guess_mode_from_gamescope || true)"
      fi

      for _ in $(seq 1 "$retries"); do
        if gow_apply_wlr_output_scale_once "$socket_name" "$scale" "$custom_mode" "$log_file" "$runtime_dir"; then
          return 0
        fi
        sleep "$delay"
      done
      return 1
    }

    gow_maintain_wolf_output_scale() {
      local socket_path="''${1:-''${GOW_WOLF_WAYLAND_SOCKET:-''${WAYLAND_DISPLAY:-}}}"
      local loops="''${2:-240}"
      local delay="''${3:-0.5}"
      local scale="''${4:-1}"
      local custom_mode="''${5:-''${GOW_WOLF_OUTPUT_MODE:-}}"
      local log_file="''${6:-/tmp/gow-wolf-randr.log}"
      local socket_name runtime_dir

      if [ -z "$socket_path" ]; then
        socket_path="$(gow_wait_wayland_socket /run/wolf 80 0.1 || true)"
      fi
      [ -n "$socket_path" ] || return 1

      socket_name="''${socket_path##*/}"
      runtime_dir="''${socket_path%/*}"
      if [ "$runtime_dir" = "$socket_path" ]; then
        runtime_dir="''${GOW_WOLF_WAYLAND_RUNTIME_DIR:-/run/wolf}"
      fi

      if [ -z "$custom_mode" ]; then
        custom_mode="$(gow_guess_mode_from_gamescope || true)"
      fi

      for _ in $(seq 1 "$loops"); do
        gow_apply_wlr_output_scale_once "$socket_name" "$scale" "$custom_mode" "$log_file" "$runtime_dir" || true
        sleep "$delay"
      done
      return 0
    }
  '';

  sessionUserDirsPreStart = ''
    install -d -m 0700 -o retro -g retro /run/user/1000
    install -d -m 0755 -o retro -g retro /home/retro/.config
    install -d -m 0755 -o retro -g retro /home/retro/.cache
    install -d -m 0755 -o retro -g retro /home/retro/.local/state
  '';

  mkWolfSessionAnchorService = nextSessionService: {
    description = "Wolf User Session Anchor";
    wantedBy = [ "multi-user.target" ];
    before = [ nextSessionService ];
    serviceConfig = {
      Type = "simple";
      User = "retro";
      Group = "retro";
      PAMName = "wolf-session-anchor";
      Environment = [
        "XDG_SESSION_TYPE=wayland"
        "XDG_SESSION_CLASS=user"
        "XDG_SEAT=seat0"
      ];
      Restart = "always";
      RestartSec = "2s";
    };
    script = ''
      exec ${pkgs.coreutils}/bin/sleep infinity
    '';
  };

  mkWolfDesktopServiceConfig = pamName: {
    Type = "simple";
    User = "retro";
    Group = "retro";
    WorkingDirectory = "/home/retro";
    Restart = "always";
    RestartSec = "2s";
    PAMName = pamName;
  };

  commonImportedSessionEnvVars = [
    "HOME"
    "XDG_RUNTIME_DIR"
    "DBUS_SESSION_BUS_ADDRESS"
    "WAYLAND_DISPLAY"
    "XDG_SESSION_TYPE"
    "XDG_SESSION_CLASS"
    "XDG_SESSION_DESKTOP"
    "XDG_CURRENT_DESKTOP"
    "XDG_SEAT"
    "XDG_SESSION_ID"
    "XDG_CONFIG_DIRS"
    "XDG_DATA_DIRS"
    "GAMESCOPE_WIDTH"
    "GAMESCOPE_HEIGHT"
    "GAMESCOPE_REFRESH"
    "PULSE_SERVER"
    "LD_LIBRARY_PATH"
    "VK_ICD_FILENAMES"
    "__EGL_VENDOR_LIBRARY_DIRS"
    "__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS"
    "GBM_BACKENDS_PATH"
    "GBM_BACKEND"
    "__GLX_VENDOR_LIBRARY_NAME"
  ];

  mkImportEnvironmentCommand = extraVars:
    let
      vars = commonImportedSessionEnvVars ++ extraVars;
    in
    ''
      ${pkgs.systemd}/bin/systemctl --user import-environment \
        ${lib.concatStringsSep " " vars} || true
    '';

  mkSyncDbusActivationCommand = extraVars:
    let
      vars = commonImportedSessionEnvVars ++ extraVars;
    in
    ''
      gow_sync_dbus_activation_environment \
        ${lib.concatStringsSep " " vars} || true
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

    # Keep runtime metadata deterministic: only expose NVIDIA descriptors here.
    # Mixing Mesa + NVIDIA ICD/vendor files under one runtime tree can make
    # compositor startup pick an incompatible EGL/Vulkan provider.
    shopt -s nullglob
    for stale in "$vulkan_icd_dir"/*.json "$egl_external_dir"/*.json "$egl_vendor_dir"/*.json; do
      rm -f "$stale"
    done
    shopt -u nullglob

    for candidate in \
      "$nvidia_prefix/share/vulkan/icd.d/nvidia_icd.json" \
      "$nvidia_prefix/share/vulkan/icd.d/nvidia_icd.x86_64.json" \
      "$nvidia_prefix/share/vulkan/icd.d/nvidia_icd.i686.json"; do
      if [ -f "$candidate" ]; then
        cp -f "$candidate" "$vulkan_icd_dir/$(basename "$candidate")"
      fi
    done

    for candidate in \
      "$nvidia_prefix/share/egl/egl_external_platform.d/10_nvidia_wayland.json" \
      "$nvidia_prefix/share/egl/egl_external_platform.d/15_nvidia_gbm.json"; do
      if [ -f "$candidate" ]; then
        cp -f "$candidate" "$egl_external_dir/$(basename "$candidate")"
      fi
    done

    if [ -f "$nvidia_prefix/share/glvnd/egl_vendor.d/10_nvidia.json" ]; then
      cp -f "$nvidia_prefix/share/glvnd/egl_vendor.d/10_nvidia.json" "$egl_vendor_dir/10_nvidia.json"
    fi

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

    icd_files=()
    for candidate in \
      "$vulkan_icd_dir/nvidia_icd.x86_64.json" \
      "$vulkan_icd_dir/nvidia_icd.json" \
      "$vulkan_icd_dir/nvidia_icd.i686.json"; do
      if [ -f "$candidate" ]; then
        icd_files+=("$candidate")
      fi
    done
    if [ "''${#icd_files[@]}" -gt 0 ]; then
      icd_joined="$(IFS=:; echo "''${icd_files[*]}")"
      add_env_prefix VK_ICD_FILENAMES "$icd_joined"
    fi

    add_env_prefix __EGL_VENDOR_LIBRARY_DIRS "$egl_vendor_dir"
    add_env_prefix __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS "$egl_external_dir"
    add_env_prefix GBM_BACKENDS_PATH "$gbm_dir"

    lib_paths=()
    for lib_dir in "$nvidia_prefix/lib64" "$nvidia_prefix/lib" "$gbm_dir" "$nvidia_prefix/lib32"; do
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

  mkDesktopStartupAppScript = scriptName: desktopName:
    writeExecutable scriptName ''
      set -euo pipefail

      source /opt/gow/bash-lib/utils.sh

      export container=podman
      export SYSTEMD_IGNORE_CHROOT=1

      # Prefer Wolf's host PulseAudio socket when exposed.
      if [ -z "''${PULSE_SERVER:-}" ] && [ -S /run/wolf/pulse-socket ]; then
        export PULSE_SERVER=/run/wolf/pulse-socket
      fi

      mkdir -p /run /run/lock /tmp /var/log/journal
      chmod 1777 /tmp

      # Match container expectations used by NixOS container profiles.
      mkdir -p /run/systemd
      printf '%s\n' "podman" > /run/systemd/container || true

      init_path=""
      if [ -x /init ]; then
        init_path=/init
      elif [ -n "''${GOW_NIXOS_SYSTEM:-}" ] && [ -x "''${GOW_NIXOS_SYSTEM}/init" ]; then
        init_path="''${GOW_NIXOS_SYSTEM}/init"
      fi

      if [ -z "$init_path" ]; then
        gow_log "[${desktopName}] Missing init executable (expected /init or \$GOW_NIXOS_SYSTEM/init)"
        exit 1
      fi

      if [ ! -s /etc/machine-id ] && command -v systemd-machine-id-setup >/dev/null 2>&1; then
        systemd-machine-id-setup >/dev/null 2>&1 || true
      fi

      gow_log "[${desktopName}] Launching systemd from $init_path"
      exec "$init_path"
    '';

  gnomeStartupAppScript = mkDesktopStartupAppScript "gow-gnome-startup-app.sh" "GNOME";
  kdeStartupAppScript = mkDesktopStartupAppScript "gow-kde-startup-app.sh" "KDE";
  labwcStartupAppScript = mkDesktopStartupAppScript "gow-labwc-startup-app.sh" "Labwc";
  xfceStartupAppScript = mkDesktopStartupAppScript "gow-xfce-startup-app.sh" "XFCE";

  gnomeShellCompatLauncherScript = writeExecutable "gow-gnome-shell-launcher.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/desktop-compat.sh

    log_file="''${GOW_GNOME_SHELL_LOG_FILE:-/tmp/gow-gnome-shell.log}"
    : >"$log_file"
    exec > >(${pkgs.coreutils}/bin/tee -a "$log_file") 2>&1

    gow_apply_common_ui_scale_defaults
    gow_apply_common_xdg_defaults
    gow_apply_graphics_runtime_env

    if ! gow_export_wolf_wayland_env /run/wolf 80 0.1; then
      echo "[GNOME] Wolf Wayland socket is missing; cannot launch nested shell"
      exit 1
    fi

    width="''${GAMESCOPE_WIDTH:-1920}"
    height="''${GAMESCOPE_HEIGHT:-1080}"
    refresh="''${GAMESCOPE_REFRESH:-60}"
    virtual_monitor="''${width}x''${height}@''${refresh}"
    force_virtual_monitor="''${GOW_GNOME_FORCE_VIRTUAL_MONITOR:-0}"
    gnome_shell_args=(--wayland --no-x11)
    launch_mode="''${GOW_GNOME_SHELL_MODE:-}"
    if [ -z "$launch_mode" ]; then
      if [ "''${GOW_GNOME_USE_DEVKIT:-0}" = "1" ]; then
        launch_mode="headless"
      else
        launch_mode="headless"
      fi
    fi
    if [ "$force_virtual_monitor" = "1" ] || [ "$launch_mode" = "headless" ]; then
      gnome_shell_args+=(--virtual-monitor "$virtual_monitor")
    fi

    echo "[GNOME] WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    echo "[GNOME] virtual monitor requested: $virtual_monitor"
    echo "[GNOME] force virtual monitor: $force_virtual_monitor"
    echo "[GNOME] launch mode: $launch_mode"

    export MUTTER_DEBUG_NUM_DUMMY_MONITORS="''${MUTTER_DEBUG_NUM_DUMMY_MONITORS:-1}"
    export MUTTER_DEBUG_DUMMY_MONITOR_SCALES="''${MUTTER_DEBUG_DUMMY_MONITOR_SCALES:-1}"
    export MUTTER_DEBUG_DUMMY_MODE_SPECS="''${MUTTER_DEBUG_DUMMY_MODE_SPECS:-$virtual_monitor}"
    if [ -n "''${GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM:-}" ]; then
      export MUTTER_DEBUG_NESTED_OFFSCREEN_TRANSFORM="''${GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM}"
    fi
    if [ "''${GOW_GNOME_MUTTER_DEBUG:-0}" = "1" ]; then
      export G_MESSAGES_DEBUG="''${G_MESSAGES_DEBUG:-all}"
    fi

    echo "[GNOME] MUTTER_DEBUG_NUM_DUMMY_MONITORS=$MUTTER_DEBUG_NUM_DUMMY_MONITORS"
    echo "[GNOME] MUTTER_DEBUG_DUMMY_MONITOR_SCALES=$MUTTER_DEBUG_DUMMY_MONITOR_SCALES"
    echo "[GNOME] MUTTER_DEBUG_DUMMY_MODE_SPECS=$MUTTER_DEBUG_DUMMY_MODE_SPECS"
    echo "[GNOME] MUTTER_DEBUG_NESTED_OFFSCREEN_TRANSFORM=''${MUTTER_DEBUG_NESTED_OFFSCREEN_TRANSFORM:-unset}"
    echo "[GNOME] G_MESSAGES_DEBUG=''${G_MESSAGES_DEBUG:-unset}"

    {
      printf "[GNOME] gnome-shell argv:"
      printf ' %q' "''${gnome_shell_args[@]}"
      printf '\n'
    }

    case "$launch_mode" in
      headless)
        echo "[GNOME] Launching gnome-shell in headless mode"
        exec ${pkgs.gnome-shell}/bin/gnome-shell \
          --headless "''${gnome_shell_args[@]}"
        ;;
      devkit)
        echo "[GNOME] Launching gnome-shell in devkit mode"
        exec ${pkgs.gnome-shell}/bin/gnome-shell \
          --devkit "''${gnome_shell_args[@]}"
        ;;
      nested)
        echo "[GNOME] Launching gnome-shell in nested mode"
        exec ${pkgs.gnome-shell}/bin/gnome-shell \
          "''${gnome_shell_args[@]}"
        ;;
      upstream)
        echo "[GNOME] Launching gnome-shell with upstream defaults"
        exec ${pkgs.gnome-shell}/bin/gnome-shell
        ;;
      *)
        echo "[GNOME] Unknown launch mode '$launch_mode', falling back to headless"
        exec ${pkgs.gnome-shell}/bin/gnome-shell \
          --headless "''${gnome_shell_args[@]}"
        ;;
    esac
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

  labwcAutostart = writeExecutable "gow-labwc-autostart.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/desktop-compat.sh

    runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"

    # Nested sessions can inherit a HiDPI scale from the parent compositor.
    gow_reconcile_wlr_output_scale "$runtime_dir" 120 0.25 1 "" /tmp/gow-wlr-randr.log || true

    # Keep re-applying scale briefly while the desktop shell initializes.
    (
      gow_maintain_wlr_output_scale "$runtime_dir" 240 0.5 1 "" /tmp/gow-wlr-randr.log || true
    ) &

    # Optional shell layer on top of labwc.
    # - noctalia: launch Noctalia shell
    # - waybar: launch waybar (default)
    # - none: no shell component
    case "''${GOW_LABWC_SHELL:-noctalia}" in
      noctalia)
        socket="$(gow_pick_runtime_wayland_socket_name "$runtime_dir" || true)"
        if [ -n "$socket" ]; then
          systemctl --user set-environment WAYLAND_DISPLAY="$socket" QT_QPA_PLATFORM=wayland >>/tmp/gow-noctalia.log 2>&1 || true
        fi
        if ! systemctl --user restart --no-block wolf-noctalia-shell.service >>/tmp/gow-noctalia.log 2>&1; then
          shell_bin="/run/current-system/sw/bin/noctalia-shell"
          if [ ! -x "$shell_bin" ] && command -v noctalia-shell >/dev/null 2>&1; then
            shell_bin="$(command -v noctalia-shell)"
          fi
          if [ -x "$shell_bin" ]; then
            (
              if [ -n "$socket" ]; then
                export WAYLAND_DISPLAY="$socket"
              fi
              export QT_QPA_PLATFORM=wayland
              exec "$shell_bin"
            ) >>/tmp/gow-noctalia.log 2>&1 &
          else
            echo "[autostart] noctalia-shell not found" >>/tmp/gow-noctalia.log
          fi
        fi
        if [ "''${GOW_DISABLE_WAYBAR:-0}" != "1" ]; then
          waybar >/tmp/gow-waybar.log 2>&1 &
        fi
        ;;
      waybar)
        if [ "''${GOW_DISABLE_WAYBAR:-0}" != "1" ]; then
          waybar >/tmp/gow-waybar.log 2>&1 &
        fi
        ;;
      none)
        ;;
      *)
        if [ "''${GOW_DISABLE_WAYBAR:-0}" != "1" ]; then
          waybar >/tmp/gow-waybar.log 2>&1 &
        fi
        ;;
    esac

    if [ "''${GOW_LABWC_AUTOSTART_TERMINAL:-1}" = "1" ]; then
      kitty >/tmp/gow-kitty.log 2>&1 &
    fi
  '';

  labwcNoctaliaAutostart = writeExecutable "gow-labwc-noctalia-autostart.sh" ''
    set -euo pipefail

    source /opt/gow/bash-lib/desktop-compat.sh

    log_file=/tmp/gow-labwc-autostart.log
    randr_log=/tmp/gow-wlr-randr.log
    target_width="''${GAMESCOPE_WIDTH:-1920}"
    target_height="''${GAMESCOPE_HEIGHT:-1080}"
    runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
    custom_mode="''${target_width}x''${target_height}"
    : >"$log_file"
    : >"$randr_log"

    socket="$(gow_wait_runtime_wayland_socket_name "$runtime_dir" 120 0.25 || true)"
    if [ -z "$socket" ]; then
      echo "[autostart] no wayland socket under ''${XDG_RUNTIME_DIR:-/tmp}" >>"$log_file"
      exit 1
    fi

    echo "[autostart] WAYLAND_DISPLAY=$socket TARGET=''${target_width}x''${target_height}" >>"$log_file"
    (
      scale_applied=0
      for _ in $(seq 1 120); do
        if gow_apply_wlr_output_scale_once "$socket" 1 "$custom_mode" "$randr_log"; then
          scale_applied=1
        fi
        sleep 0.5
      done
      if [ "$scale_applied" -ne 1 ]; then
        echo "[autostart] failed to apply output scale via wlr-randr" >>"$log_file"
      fi
    ) &

    ${pkgs.systemd}/bin/systemctl --user set-environment WAYLAND_DISPLAY="$socket" QT_QPA_PLATFORM=wayland
    ${pkgs.systemd}/bin/systemctl --user restart wolf-noctalia-shell.service

    kitty >/tmp/gow-kitty.log 2>&1 &
    echo "[autostart] started wolf-noctalia-shell.service and kitty" >>"$log_file"
  '';

  baseAssets = pkgs.runCommand "gow-base-assets" { } ''
    mkdir -p "$out"

    install -Dm644 ${gowUtilsScript} "$out/opt/gow/bash-lib/utils.sh"
    install -Dm644 ${desktopCompatLibScript} "$out/opt/gow/bash-lib/desktop-compat.sh"
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

  gnomeAssets = pkgs.runCommand "gow-gnome-assets" { } ''
    mkdir -p "$out"
    install -Dm755 ${gnomeStartupAppScript} "$out/opt/gow/startup-app.sh"
  '';

  kdeAssets = pkgs.runCommand "gow-kde-assets" { } ''
    mkdir -p "$out"
    install -Dm755 ${kdeStartupAppScript} "$out/opt/gow/startup-app.sh"
  '';

  labwcAssets = pkgs.runCommand "gow-labwc-assets" { } ''
    mkdir -p "$out"
    install -Dm755 ${labwcStartupAppScript} "$out/opt/gow/startup-app.sh"
    install -Dm755 ${labwcAutostart} "$out/cfg/labwc/autostart"
  '';

  labwcNoctaliaAssets = pkgs.runCommand "gow-labwc-noctalia-assets" { } ''
    mkdir -p "$out"
    cp -r ${labwcAssets}/. "$out/"
    chmod -R u+w "$out"
    install -Dm755 ${labwcNoctaliaAutostart} "$out/cfg/labwc/autostart"
  '';

  xfceAssets = pkgs.runCommand "gow-xfce-assets" { } ''
    mkdir -p "$out"
    install -Dm755 ${xfceStartupAppScript} "$out/opt/gow/startup-app.sh"
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
  nixosGnomePath = "/run/current-system/sw/bin:/run/current-system/sw/sbin";
  nixosLabwcPath = "/run/current-system/sw/bin:/run/current-system/sw/sbin";
  nixosXfcePath = "/run/current-system/sw/bin:/run/current-system/sw/sbin";
  nixosKdePath = "/run/current-system/sw/bin:/run/current-system/sw/sbin";
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

  desktopSystems = import ./images/desktop-systems.nix {
    inherit
      lib
      pkgs
      gnomeShellCompatLauncherScript
      mkWolfSessionAnchorService
      sessionUserDirsPreStart
      mkImportEnvironmentCommand
      mkSyncDbusActivationCommand
      mkWolfDesktopServiceConfig
      noctaliaShell;
  };
  inherit (desktopSystems)
    nixosGnomeSystemMount
    nixosKdeSystemMount
    nixosLabwcSystemMount
    nixosXfceSystemMount;

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

  nixosPassThroughRootfs = pkgs.runCommand "wolf-nixos-passthrough-rootfs" { } ''
    mkdir -p "$out"
    mkdir -p "$out/etc"

    mkdir -p "$out/proc" "$out/sys" "$out/dev" "$out/run" "$out/home/retro" "$out/root" "$out/var/empty" "$out/tmp/.X11-unix"
    chmod 1777 "$out/tmp" "$out/tmp/.X11-unix"

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

    # nspawn container startup also guarantees these files exist.
    : > "$out/etc/os-release"
    : > "$out/etc/machine-id"

    # Keep classic FHS paths as symlinks like NixOS/nspawn roots do.
    # Creating real directories here makes stage-2 activation try to mutate
    # /bin at runtime, which fails in Wolf's read-only container layout.
    ln -s /run/current-system/sw/bin "$out/bin"
    ln -s /run/current-system/sw/sbin "$out/sbin"
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

  # App containers bind-mount host /nix/store. If rootfs files are symlinks to
  # image-local store paths, host GC can invalidate them at runtime.
  # Materialize runtime trees as regular files to keep entrypoints/config stable.
  materializeRuntimeTrees = ''
    materialize_tree() {
      local rel="$1"
      local tmp
      if [ ! -d "$rel" ]; then
        return 0
      fi
      tmp="$(mktemp -d)"
      cp -aL "$rel"/. "$tmp"/
      rm -rf "$rel"
      mkdir -p "$rel"
      cp -a "$tmp"/. "$rel"/
      rm -rf "$tmp"
    }

    materialize_tree opt/gow
    materialize_tree cfg
  '';

  desktopImages = import ./images/desktop-images.nix {
    inherit
      pkgs
      imageTag
      commonConfig
      commonBaseEnv
      basePath
      nixosGnomePath
      nixosLabwcPath
      nixosXfcePath
      nixosKdePath
      nixosPassThroughRootfs
      baseAssets
      baseAppAssets
      gnomeAssets
      labwcAssets
      labwcNoctaliaAssets
      xfceAssets
      kdeAssets
      materializeRuntimeTrees
      nixosGnomeSystemMount
      nixosLabwcSystemMount
      nixosXfceSystemMount
      nixosKdeSystemMount;
  };

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
    extraCommands = mkExtraDirs + materializeRuntimeTrees;
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
    extraCommands = mkExtraDirs + materializeRuntimeTrees;
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
    extraCommands = materializeRuntimeTrees + ''
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
            "DeviceCgroupRules": ["c 13:* rmw", "c 226:* rmw", "c 244:* rmw"]
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
        "DeviceCgroupRules": ["c 13:* rmw", "c 226:* rmw", "c 244:* rmw"]
      }
    }
    """
  '';

  inherit (desktopImages)
    wolfGnomeNixosImage
    wolfGnomeImage
    wolfGnomeSystem
    wolfGnomeApp
    wolfGnomeWolfConfig
    wolfLabwcImage
    wolfLabwcSystem
    wolfLabwcApp
    wolfLabwcWolfConfig
    wolfNoctaliaImage
    wolfNoctaliaSystem
    wolfNoctaliaApp
    wolfNoctaliaWolfConfig
    wolfXfceImage
    wolfXfceSystem
    wolfXfceApp
    wolfXfceWolfConfig
    wolfKdeNixosImage
    wolfKdeImage
    wolfKdeSystem
    wolfKdeApp
    wolfKdeWolfConfig;
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
    extraCommands = materializeRuntimeTrees + ''
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
            "Devices": [
              {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
              {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
            ],
            "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
            "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"]
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
        "Devices": [
          {"PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"},
          {"PathOnHost": "/dev/dri", "PathInContainer": "/dev/dri", "CgroupPermissions": "rwm"}
        ],
        "Ulimits": [{"Name": "nofile", "Soft": 10240, "Hard": 524288}],
        "DeviceCgroupRules": ["c 10:229 rmw", "c 13:* rmw", "c 226:* rmw", "c 244:* rmw"]
      }
    }
    """
  '';
}
