{ lib
, pkgs
, gnomeShellCompatLauncherScript
, mkWolfSessionAnchorService
, sessionUserDirsPreStart
, mkImportEnvironmentCommand
, mkSyncDbusActivationCommand
, mkWolfDesktopServiceConfig
, noctaliaShell
}:

let
  nixosGnomeSystem = import "${pkgs.path}/nixos" {
    system = pkgs.system;
    configuration = { pkgs, lib, ... }: {
      boot.isContainer = true;
      networking.hostName = "wolf-gnome";
      system.stateVersion = "25.05";

      documentation.enable = false;
      documentation.man.enable = false;

      users.allowNoPasswordLogin = true;
      users.mutableUsers = false;
      users.groups.retro.gid = 1000;
      users.groups.video = { };
      users.groups.render = { };
      users.groups.input = { };
      users.groups.audio = { };
      users.users.root.initialHashedPassword = "!";
      users.users.retro = {
        isNormalUser = true;
        uid = 1000;
        group = "retro";
        extraGroups = [ "video" "render" "input" "audio" ];
        home = "/home/retro";
        createHome = true;
        linger = true;
        initialHashedPassword = "!";
      };

      # Keep GNOME definition upstream-driven; Wolf-specific behavior lives in
      # the compatibility shim service below.
      services.desktopManager.gnome.enable = true;
      services.gnome.core-apps.enable = lib.mkForce true;
      services.displayManager.gdm.enable = false;
      services.gnome.gnome-initial-setup.enable = false;
      services.gnome.gnome-browser-connector.enable = false;
      services.gnome.gnome-remote-desktop.enable = false;
      services.gnome.localsearch.enable = false;
      services.gnome.tinysparql.enable = false;

      programs.dconf.enable = true;
      services.dbus.enable = true;
      security.rtkit.enable = true;
      services.upower.enable = lib.mkForce true;
      services.pipewire.enable = true;

      # Stage-2 activation in this container rootfs cannot rewrite /bin.
      system.activationScripts.binsh = lib.mkForce "";

      # GNOME runs in Wolf on Mutter's headless backend with an explicit virtual monitor.
      systemd.user.services."org.gnome.Shell@wayland" = {
        serviceConfig.ExecStart = lib.mkForce [
          ""
          "${gnomeShellCompatLauncherScript}"
        ];
        serviceConfig.Environment = lib.mkForce [
          "GOW_GNOME_SHELL_MODE=headless"
          "GOW_GNOME_FORCE_VIRTUAL_MONITOR=0"
          "GOW_GNOME_MUTTER_DEBUG=1"
          "MUTTER_DEBUG_NUM_DUMMY_MONITORS=1"
          "MUTTER_DEBUG_DUMMY_MONITOR_SCALES=1"
          "MUTTER_DEBUG_DUMMY_MODE_SPECS=1920x1080@60"
        ];
      };

      systemd.user.targets.wolf-gnome-diagnostics = {
        description = "Wolf GNOME Diagnostics";
      };

      systemd.user.services.wolf-gnome-diagnostics = {
        description = "Collect Wolf GNOME shell diagnostics";
        after = [ "gnome-session.target" "org.gnome.Shell@wayland.service" ];
        wants = [ "org.gnome.Shell@wayland.service" ];
        wantedBy = [ "gnome-session.target" "wolf-gnome-diagnostics.target" ];
        path = with pkgs; [
          coreutils
          glib
          gnugrep
          procps
          systemd
          wlr-randr
        ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          set -euo pipefail

          log_dir="''${GOW_GNOME_DIAG_DIR:-/tmp}"
          ts="$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)"
          log_file="$log_dir/gow-gnome-diagnostics-''${ts}-$$.log"
          shell_log="''${GOW_GNOME_SHELL_LOG_FILE:-/tmp/gow-gnome-shell.log}"
          journal_lines="''${GOW_GNOME_DIAG_JOURNAL_LINES:-300}"

          mkdir -p "$log_dir"

          for _ in $(seq 1 120); do
            active_state="$(${pkgs.systemd}/bin/systemctl --user show org.gnome.Shell@wayland.service -p ActiveState --value 2>/dev/null || true)"
            case "$active_state" in
              active|failed|inactive)
                break
                ;;
            esac
            sleep 0.25
          done

          {
            echo "[diag] timestamp=$(${pkgs.coreutils}/bin/date --iso-8601=seconds)"
            echo "[diag] log_file=$log_file"
            echo
            echo "== user environment (filtered) =="
            ${pkgs.systemd}/bin/systemctl --user show-environment \
              | ${pkgs.gnugrep}/bin/grep -E '^(DBUS_SESSION_BUS_ADDRESS|WAYLAND_DISPLAY|XDG_|GAMESCOPE_|MUTTER_|QT_|GDK_|PULSE_SERVER)=' \
              || true
            echo
            echo "== shell unit show =="
            ${pkgs.systemd}/bin/systemctl --user show org.gnome.Shell@wayland.service \
              -p Id -p LoadState -p ActiveState -p SubState -p Result \
              -p ExecMainCode -p ExecMainStatus -p InvocationID -p FragmentPath \
              || true
            echo
            echo "== shell process details =="
            shell_pid="$(${pkgs.systemd}/bin/systemctl --user show org.gnome.Shell@wayland.service -p MainPID --value 2>/dev/null || true)"
            echo "MainPID=$shell_pid"
            if [ -n "$shell_pid" ] && [ "$shell_pid" != "0" ]; then
              tr '\0' ' ' <"/proc/$shell_pid/cmdline" 2>/dev/null || true
              echo
            fi
            mutter_pid="$(${pkgs.procps}/bin/pgrep -P "$shell_pid" -f '/mutter-devkit|mutter-devkit' | head -n1 || true)"
            echo "MutterDevkitPID=''${mutter_pid:-unset}"
            if [ -n "$mutter_pid" ]; then
              tr '\0' ' ' <"/proc/$mutter_pid/cmdline" 2>/dev/null || true
              echo
            fi
            echo
            echo "== shell/mutter env snapshot =="
            for pid in "$shell_pid" "$mutter_pid"; do
              if [ -z "$pid" ] || [ "$pid" = "0" ] || [ ! -r "/proc/$pid/environ" ]; then
                continue
              fi
              echo "[pid=$pid]"
              tr '\0' '\n' <"/proc/$pid/environ" \
                | ${pkgs.gnugrep}/bin/grep -E '^(WAYLAND_DISPLAY|DBUS_SESSION_BUS_ADDRESS|XDG_|GOW_GNOME_|GAMESCOPE_|MUTTER_DEBUG_|G_MESSAGES_DEBUG|QT_|GDK_|PULSE_SERVER)=' \
                || true
            done
            echo
            echo "== shell unit status =="
            ${pkgs.systemd}/bin/systemctl --user status org.gnome.Shell@wayland.service --no-pager --full || true
            echo
            echo "== gnome session status =="
            ${pkgs.systemd}/bin/systemctl --user status gnome-session.target --no-pager --full || true
            ${pkgs.systemd}/bin/systemctl --user status gnome-session-manager@gnome.service --no-pager --full || true
            echo
            echo "== shell dbus names =="
            ${pkgs.systemd}/bin/busctl --user list \
              | ${pkgs.gnugrep}/bin/grep -E 'org\\.gnome\\.Shell|org\\.gnome\\.ScreenSaver' || true
            echo
            echo "== gsettings scaling =="
            ${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface scaling-factor || true
            ${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface text-scaling-factor || true
            echo
            echo "== monitors.xml =="
            if [ -f /home/retro/.config/monitors.xml ]; then
              ${pkgs.coreutils}/bin/head -n 200 /home/retro/.config/monitors.xml || true
            else
              echo "missing: /home/retro/.config/monitors.xml"
            fi
            echo
            echo "== wolf output state =="
            wolf_socket=""
            for candidate in /run/wolf/wayland-*; do
              [ -S "$candidate" ] || continue
              wolf_socket="$candidate"
              break
            done
            if [ -n "$wolf_socket" ]; then
              XDG_RUNTIME_DIR=/run/wolf WAYLAND_DISPLAY="''${wolf_socket##*/}" ${pkgs.wlr-randr}/bin/wlr-randr || true
            else
              echo "no /run/wolf/wayland-* socket found"
            fi
            echo
            echo "== related user units =="
            ${pkgs.systemd}/bin/systemctl --user list-units --all 'org.gnome.Shell*' 'gnome-session*' || true
            echo
            echo "== recent journal =="
            ${pkgs.systemd}/bin/journalctl --user --no-pager \
              -u org.gnome.Shell@wayland.service \
              -u gnome-session-manager@gnome.service \
              -n "$journal_lines" || true
            echo
            echo "== shell launcher log tail =="
            if [ -f "$shell_log" ]; then
              ${pkgs.coreutils}/bin/tail -n 200 "$shell_log" || true
            else
              echo "missing: $shell_log"
            fi
            echo
            echo "== wolf randr log tail =="
            if [ -f /tmp/gow-wolf-randr.log ]; then
              ${pkgs.coreutils}/bin/tail -n 200 /tmp/gow-wolf-randr.log || true
            else
              echo "missing: /tmp/gow-wolf-randr.log"
            fi
          } >"$log_file" 2>&1

          ln -sfn "$log_file" "$log_dir/gow-gnome-diagnostics.latest.log"
        '';
      };

      security.pam.services.wolf-session-anchor.startSession = true;
      security.pam.services.wolf-gnome-session.startSession = true;

      # Compatibility layer primitive:
      # keep a real logind/PAM user session alive for compositor/session matching.
      systemd.services.wolf-session-anchor = mkWolfSessionAnchorService "wolf-gnome-session.service";

      systemd.services.wolf-gnome-session = {
        description = "Wolf GNOME Session";
        wantedBy = [ "multi-user.target" ];
        after = [ "dbus.service" "systemd-user-sessions.service" "user@1000.service" "wolf-session-anchor.service" ];
        wants = [ "dbus.service" "user@1000.service" "wolf-session-anchor.service" ];
        path = with pkgs; [
          coreutils
          dbus
          gawk
          glib
          gnome-session
          gnugrep
          systemd
          wlr-randr
        ];
        preStart = sessionUserDirsPreStart;
        script = ''
          set -euo pipefail

          source /opt/gow/bash-lib/desktop-compat.sh

          export HOME=/home/retro
          export XDG_RUNTIME_DIR=/run/user/1000
          export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
          export XDG_SESSION_TYPE=wayland
          export XDG_SESSION_CLASS=user
          export XDG_SESSION_DESKTOP=gnome
          export XDG_CURRENT_DESKTOP=GNOME
          export XDG_SEAT=seat0
          export XDG_CONFIG_DIRS="/run/current-system/sw/etc/xdg:/etc/xdg"
          export XDG_DATA_DIRS="/run/current-system/sw/share:/nix/var/nix/profiles/default/share:/etc/profiles/per-user/retro/share:/usr/local/share:/usr/share"
          export GAMESCOPE_WIDTH="''${GAMESCOPE_WIDTH:-1920}"
          export GAMESCOPE_HEIGHT="''${GAMESCOPE_HEIGHT:-1080}"
          export GAMESCOPE_REFRESH="''${GAMESCOPE_REFRESH:-60}"
          export QT_QPA_PLATFORM=wayland
          export QSG_RHI_BACKEND=opengl
          export GOW_GNOME_SHELL_MODE="''${GOW_GNOME_SHELL_MODE:-headless}"
          export GOW_GNOME_FORCE_VIRTUAL_MONITOR="''${GOW_GNOME_FORCE_VIRTUAL_MONITOR:-0}"
          export GOW_GNOME_RESET_MONITOR_CONFIG="''${GOW_GNOME_RESET_MONITOR_CONFIG:-1}"
          export GOW_GNOME_MUTTER_DEBUG="''${GOW_GNOME_MUTTER_DEBUG:-1}"
          export GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM="''${GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM:-}"
          export MUTTER_DEBUG_NUM_DUMMY_MONITORS="''${MUTTER_DEBUG_NUM_DUMMY_MONITORS:-1}"
          export MUTTER_DEBUG_DUMMY_MONITOR_SCALES="''${MUTTER_DEBUG_DUMMY_MONITOR_SCALES:-1}"
          # Avoid repeated Qt Wayland decoration EGL context failures in nested sessions.
          export QT_WAYLAND_DISABLE_WINDOWDECORATION=1

          gow_apply_common_ui_scale_defaults
          gow_apply_common_xdg_defaults
          gow_apply_graphics_runtime_env

          if [ "$GOW_GNOME_RESET_MONITOR_CONFIG" = "1" ]; then
            rm -f "$HOME/.config/monitors.xml"
          fi

          if ! gow_export_wolf_wayland_env /run/wolf 80 0.1; then
            echo "[GNOME] missing Wolf Wayland socket under /run/wolf"
            exit 1
          fi

          export MUTTER_DEBUG_DUMMY_MODE_SPECS="''${MUTTER_DEBUG_DUMMY_MODE_SPECS:-''${GAMESCOPE_WIDTH}x''${GAMESCOPE_HEIGHT}@''${GAMESCOPE_REFRESH}}"
          if [ -n "$GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM" ]; then
            export MUTTER_DEBUG_NESTED_OFFSCREEN_TRANSFORM="$GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM"
          fi

          wolf_mode="''${GOW_WOLF_OUTPUT_MODE:-''${GAMESCOPE_WIDTH}x''${GAMESCOPE_HEIGHT}}"
          gow_reconcile_wolf_output_scale "$WAYLAND_DISPLAY" 120 0.1 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
          (
            gow_maintain_wolf_output_scale "$WAYLAND_DISPLAY" 240 0.5 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
          ) &

          gow_export_pulse_server_from_wolf
          gow_require_session_bus /run/user/1000/bus 200 0.1
          gow_export_logind_session_id 1000 retro seat0

          ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface scaling-factor 1 >/dev/null 2>&1 || true
          ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface text-scaling-factor 1.0 >/dev/null 2>&1 || true

          ${mkSyncDbusActivationCommand [
            "MUTTER_DEBUG_DUMMY_MODE_SPECS"
            "MUTTER_DEBUG_NUM_DUMMY_MONITORS"
            "MUTTER_DEBUG_DUMMY_MONITOR_SCALES"
            "MUTTER_DEBUG_NESTED_OFFSCREEN_TRANSFORM"
            "QT_QPA_PLATFORM"
            "QSG_RHI_BACKEND"
            "GOW_GNOME_SHELL_MODE"
            "GOW_GNOME_FORCE_VIRTUAL_MONITOR"
            "GOW_GNOME_MUTTER_DEBUG"
            "GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM"
            "QT_WAYLAND_DISABLE_WINDOWDECORATION"
          ]}
          ${mkImportEnvironmentCommand [
            "MUTTER_DEBUG_DUMMY_MODE_SPECS"
            "MUTTER_DEBUG_NUM_DUMMY_MONITORS"
            "MUTTER_DEBUG_DUMMY_MONITOR_SCALES"
            "MUTTER_DEBUG_NESTED_OFFSCREEN_TRANSFORM"
            "QT_QPA_PLATFORM"
            "QSG_RHI_BACKEND"
            "GOW_GNOME_SHELL_MODE"
            "GOW_GNOME_FORCE_VIRTUAL_MONITOR"
            "GOW_GNOME_MUTTER_DEBUG"
            "GOW_GNOME_NESTED_OFFSCREEN_TRANSFORM"
            "QT_WAYLAND_DISABLE_WINDOWDECORATION"
          ]}

          exec ${pkgs.gnome-session}/bin/gnome-session --session=gnome
        '';
        serviceConfig = mkWolfDesktopServiceConfig "wolf-gnome-session";
      };

      # Small debug/inspection set; GNOME packages come from upstream modules.
      environment.systemPackages = with pkgs; [
        dbus
        dconf
        glib
        systemd
      ];
    };
  };

  nixosKdeSystem = import "${pkgs.path}/nixos" {
    system = pkgs.system;
    configuration = { pkgs, lib, ... }: {
      boot.isContainer = true;
      networking.hostName = "wolf-kde";
      system.stateVersion = "25.05";

      documentation.enable = false;
      documentation.man.enable = false;

      users.allowNoPasswordLogin = true;
      users.mutableUsers = false;
      users.groups.retro.gid = 1000;
      users.groups.video = { };
      users.groups.render = { };
      users.groups.input = { };
      users.groups.audio = { };
      users.users.root.initialHashedPassword = "!";
      users.users.retro = {
        isNormalUser = true;
        uid = 1000;
        group = "retro";
        extraGroups = [ "video" "render" "input" "audio" ];
        home = "/home/retro";
        createHome = true;
        linger = true;
        initialHashedPassword = "!";
      };

      # Keep Plasma definition upstream-driven; Wolf-specific behavior lives in
      # the compatibility shim service below.
      services.desktopManager.plasma6.enable = true;
      services.displayManager.sddm.enable = false;

      programs.dconf.enable = true;
      services.dbus.enable = true;
      services.pipewire.enable = true;
      services.upower.enable = lib.mkForce true;
      environment.etc."xdg/baloofilerc".text = ''
        [Basic Settings]
        Indexing-Enabled=false
      '';
      environment.etc."xdg/kscreenlockerrc".text = ''
        [Daemon]
        Autolock=false
        LockOnResume=false
        Timeout=0
      '';

      # Stage-2 activation in this container rootfs cannot rewrite /bin.
      system.activationScripts.binsh = lib.mkForce "";

      security.pam.services.wolf-session-anchor.startSession = true;
      security.pam.services.wolf-kde-session.startSession = true;

      # Compatibility layer primitive:
      # keep a real logind/PAM user session alive for compositor/session matching.
      systemd.services.wolf-session-anchor = mkWolfSessionAnchorService "wolf-kde-session.service";

      systemd.services.wolf-kde-session = {
        description = "Wolf KDE Plasma Session";
        wantedBy = [ "multi-user.target" ];
        after = [ "dbus.service" "systemd-user-sessions.service" "user@1000.service" "wolf-session-anchor.service" ];
        wants = [ "dbus.service" "user@1000.service" "wolf-session-anchor.service" ];
        path = with pkgs; [
          coreutils
          dbus
          gawk
          gnugrep
          systemd
          kdePackages.plasma-workspace
          wlr-randr
        ];
        preStart = sessionUserDirsPreStart;
        script = ''
          set -euo pipefail

          source /opt/gow/bash-lib/desktop-compat.sh

          export HOME=/home/retro
          export XDG_RUNTIME_DIR=/run/user/1000
          export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
          export XDG_SESSION_TYPE=wayland
          export XDG_SESSION_CLASS=user
          export XDG_SESSION_DESKTOP=KDE
          export XDG_CURRENT_DESKTOP=KDE
          export XDG_SEAT=seat0
          export KDE_FULL_SESSION=true
          export KDE_SESSION_VERSION=6
          export DESKTOP_SESSION=plasma
          export XDG_MENU_PREFIX=plasma-
          export XDG_CONFIG_DIRS="/run/current-system/sw/etc/xdg:/etc/xdg"
          export XDG_DATA_DIRS="/run/current-system/sw/share:/nix/var/nix/profiles/default/share:/etc/profiles/per-user/retro/share:/usr/local/share:/usr/share"
          cat > "$HOME/.config/kscreenlockerrc" <<'EOCFG'
          [Daemon]
          Autolock=false
          LockOnResume=false
          Timeout=0
          EOCFG
          export GAMESCOPE_WIDTH="''${GAMESCOPE_WIDTH:-1920}"
          export GAMESCOPE_HEIGHT="''${GAMESCOPE_HEIGHT:-1080}"
          export GAMESCOPE_REFRESH="''${GAMESCOPE_REFRESH:-60}"
          export GOW_KDE_SESSION_MODE="''${GOW_KDE_SESSION_MODE:-full}"
          export GOW_KDE_APPLY_GRAPHICS_RUNTIME="''${GOW_KDE_APPLY_GRAPHICS_RUNTIME:-1}"
          export GOW_KDE_FORCE_KWIN_GL_ENV="''${GOW_KDE_FORCE_KWIN_GL_ENV:-0}"
          export GOW_KDE_QTQUICK_SOFTWARE="''${GOW_KDE_QTQUICK_SOFTWARE:-0}"
          export GOW_KDE_SET_KWIN_DRM_DEVICE="''${GOW_KDE_SET_KWIN_DRM_DEVICE:-1}"
          export GOW_KDE_INITIAL_WOLF_OUTPUT_RECONCILE="''${GOW_KDE_INITIAL_WOLF_OUTPUT_RECONCILE:-0}"
          export GOW_KDE_STRIP_KICKERDASH="''${GOW_KDE_STRIP_KICKERDASH:-0}"
          export GOW_KDE_REPAIR_BROKEN_WIDGETS="''${GOW_KDE_REPAIR_BROKEN_WIDGETS:-0}"
          export GOW_KDE_RESTORE_KICKERDASH="''${GOW_KDE_RESTORE_KICKERDASH:-1}"
          export GOW_KDE_ENSURE_PANEL="''${GOW_KDE_ENSURE_PANEL:-1}"
          export QT_QPA_PLATFORM=wayland
          if [ "$GOW_KDE_QTQUICK_SOFTWARE" = "1" ]; then
            unset QSG_RHI_BACKEND
            export QT_QUICK_BACKEND=software
          else
            export QSG_RHI_BACKEND="''${QSG_RHI_BACKEND:-opengl}"
            unset QT_QUICK_BACKEND
          fi
          # Avoid repeated Qt Wayland decoration EGL context failures in nested sessions.
          export QT_WAYLAND_DISABLE_WINDOWDECORATION=1

          gow_apply_common_ui_scale_defaults

          sanitize_plasma_profile_if_incompatible() {
            local marker="$HOME/.cache/gow-kde-profile-sanitized-v3"
            local backup_root="$HOME/.local/state/gow-kde-profile-backups"
            local profile_id="plasma-${pkgs.kdePackages.plasma-workspace.version}-${pkgs.kdePackages.plasma-desktop.version}"
            local ts backup_dir
            local current_marker=""
            local force_reset="''${GOW_KDE_FORCE_PROFILE_RESET:-0}"

            if [ "$force_reset" != "1" ] && [ -f "$marker" ]; then
              current_marker="$(${pkgs.coreutils}/bin/cat "$marker" 2>/dev/null || true)"
            fi
            if [ "$current_marker" = "$profile_id" ]; then
              return 0
            fi

            # Reset user Plasma state once per upstream Plasma version for this image.
            # This avoids stale schema/QML caches causing heavy UI error loops and stalls.

            ts="$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)"
            backup_dir="$backup_root/$ts"
            ${pkgs.coreutils}/bin/mkdir -p "$backup_dir"

            echo "[KDE] Resetting Plasma profile state for $profile_id (backup: $backup_dir, force=$force_reset)"

            for f in \
              "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" \
              "$HOME/.config/plasmashellrc" \
              "$HOME/.config/kdeglobals" \
              "$HOME/.config/kwinrc" \
              "$HOME/.config/ktimezonedrc"; do
              if [ -e "$f" ]; then
                ${pkgs.coreutils}/bin/mv "$f" "$backup_dir/"
              fi
            done

            for d in \
              "$HOME/.local/share/plasma" \
              "$HOME/.local/share/kactivitymanagerd"; do
              if [ -e "$d" ]; then
                ${pkgs.coreutils}/bin/mv "$d" "$backup_dir/"
              fi
            done

            ${pkgs.findutils}/bin/find "$HOME/.cache" -maxdepth 1 -type f \
              \( -name 'ksycoca6*' -o -name 'plasma*' -o -name 'qmlcache*' -o -name 'qtshadercache*' \) -delete || true

            for d in \
              "$HOME/.cache/plasmashell" \
              "$HOME/.cache/qmlcache" \
              "$HOME/.cache/qtshadercache-x86_64-little_endian-lp64"; do
              if [ -e "$d" ]; then
                ${pkgs.coreutils}/bin/rm -rf "$d"
              fi
            done

            printf '%s\n' "$profile_id" > "$marker"
          }

          sanitize_plasma_profile_if_incompatible

          restore_kickerdash_from_latest_backup() {
            if [ "''${GOW_KDE_RESTORE_KICKERDASH:-1}" != "1" ]; then
              return 0
            fi

            local appletsrc="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
            local backup_root="$HOME/.local/state/gow-kde-profile-backups"
            local latest_backup=""

            latest_backup="$(${pkgs.findutils}/bin/find "$backup_root" -maxdepth 1 -type f -name 'kickerdash-*.appletsrc' -printf '%T@ %p\n' 2>/dev/null \
              | ${pkgs.coreutils}/bin/sort -nr \
              | ${pkgs.gawk}/bin/awk 'NR == 1 { print $2 }')"

            if [ -z "$latest_backup" ] || [ ! -f "$latest_backup" ]; then
              return 0
            fi

            if ! ${pkgs.gnugrep}/bin/grep -q '^plugin=org\.kde\.plasma\.kickerdash$' "$latest_backup"; then
              return 0
            fi

            if [ -f "$appletsrc" ] && ${pkgs.gnugrep}/bin/grep -q '^plugin=org\.kde\.plasma\.kickerdash$' "$appletsrc"; then
              return 0
            fi

            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$appletsrc")"
            ${pkgs.coreutils}/bin/cp -f "$latest_backup" "$appletsrc"
            echo "[KDE] restored kickerdash widgets from backup $latest_backup"
          }

          restore_kickerdash_from_latest_backup

          strip_broken_kickerdash_from_appletsrc() {
            if [ "''${GOW_KDE_STRIP_KICKERDASH:-0}" != "1" ]; then
              return 0
            fi

            local appletsrc="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
            local tmp_bases="/tmp/gow-kde-kickerdash-bases.txt"
            local tmp_out="/tmp/gow-kde-appletsrc.cleaned"
            local backup=""

            if [ ! -f "$appletsrc" ]; then
              return 0
            fi

            ${pkgs.gawk}/bin/awk '
              /^\[/ { section=$0 }
              /^plugin=org\.kde\.plasma\.kickerdash$/ {
                if (match(section, /^(\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\])/, m)) {
                  print m[1]
                }
              }
            ' "$appletsrc" | ${pkgs.coreutils}/bin/sort -u >"$tmp_bases"

            if [ ! -s "$tmp_bases" ]; then
              return 0
            fi

            backup="$HOME/.local/state/gow-kde-profile-backups/kickerdash-$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S).appletsrc"
            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$backup")"
            ${pkgs.coreutils}/bin/cp -f "$appletsrc" "$backup"

            ${pkgs.gawk}/bin/awk -v bases_file="$tmp_bases" '
              BEGIN {
                while ((getline line < bases_file) > 0) {
                  if (line != "") {
                    skip[line] = 1
                  }
                }
              }
              /^\[/ {
                skip_section = 0
                for (base in skip) {
                  if (index($0, base) == 1) {
                    skip_section = 1
                    break
                  }
                }
              }
              !skip_section { print }
            ' "$appletsrc" >"$tmp_out"

            ${pkgs.coreutils}/bin/mv "$tmp_out" "$appletsrc"
            echo "[KDE] stripped broken kickerdash widgets from $appletsrc (backup: $backup)"
          }

          strip_broken_kickerdash_from_appletsrc

          repair_broken_plasma_widgets() {
            if [ "''${GOW_KDE_REPAIR_BROKEN_WIDGETS:-0}" != "1" ]; then
              return 0
            fi

            (
              local script_file="/tmp/gow-kde-repair-widgets.js"
              local log_file="/tmp/gow-kde-repair-widgets.log"
              local delay_s="''${GOW_KDE_REPAIR_WIDGETS_DELAY:-2}"

              cat > "$script_file" <<'EOSCRIPT'
          const log = (msg) => print("[gow-kde] " + msg);

          function safeWidgets(containment) {
              try {
                  return containment.widgets();
              } catch (e) {
                  log("widgets() failed: " + e);
                  return [];
              }
          }

          function maybeRemove(widget, where) {
              if (!widget) return;
              if (widget.type === "org.kde.plasma.kickerdash") {
                  log("removing broken widget " + widget.type + "#" + widget.id + " from " + where);
                  widget.remove();
              }
          }

          for (const panelId of panelIds.slice()) {
              const panel = panelById(panelId);
              if (!panel) continue;
              for (const widget of safeWidgets(panel)) {
                  maybeRemove(widget, "panel " + panel.id);
              }
          }

          for (const desktop of desktops()) {
              for (const widget of safeWidgets(desktop)) {
                  maybeRemove(widget, "desktop");
              }
          }
          EOSCRIPT

              for _ in $(seq 1 120); do
                if ${pkgs.dbus}/bin/dbus-send --session --dest=org.kde.plasmashell \
                  --type=method_call --print-reply=literal \
                  /PlasmaShell org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
                  sleep "$delay_s"
                  ${pkgs.glib}/bin/gdbus call --session \
                    --dest org.kde.plasmashell \
                    --object-path /PlasmaShell \
                    --method org.kde.PlasmaShell.evaluateScript \
                    "$(${pkgs.coreutils}/bin/cat "$script_file")" >>"$log_file" 2>&1 || true
                  exit 0
                fi
                sleep 0.5
              done

              echo "[KDE] plasmashell DBus service did not appear for widget repair pass" >>"$log_file"
            ) &
          }

          repair_broken_plasma_widgets

          ensure_basic_plasma_panel() {
            if [ "''${GOW_KDE_ENSURE_PANEL:-1}" != "1" ]; then
              return 0
            fi

            (
              local script_file="/tmp/gow-kde-ensure-panel.js"
              local log_file="/tmp/gow-kde-ensure-panel.log"
              local delay_s="''${GOW_KDE_ENSURE_PANEL_DELAY:-2}"

              cat > "$script_file" <<'EOSCRIPT'
          const log = (msg) => print("[gow-kde] " + msg);

          function addFirstAvailable(panel, candidates) {
              for (const plugin of candidates) {
                  if (!knownWidgetTypes.includes(plugin)) {
                      continue;
                  }
                  try {
                      panel.addWidget(plugin);
                      log("added widget " + plugin);
                      return plugin;
                  } catch (e) {
                      log("failed to add widget " + plugin + ": " + e);
                  }
              }
              return "";
          }

          if (panelIds.length > 0) {
              log("panels already present: " + panelIds.join(","));
          } else {
              let panel = new Panel;
              panel.location = "bottom";
              panel.height = 44;
              log("created fallback bottom panel " + panel.id);

              addFirstAvailable(panel, [
                  "org.kde.plasma.kickoff",
                  "org.kde.plasma.kicker"
              ]);
              addFirstAvailable(panel, [
                  "org.kde.plasma.pager"
              ]);
              addFirstAvailable(panel, [
                  "org.kde.plasma.icontasks",
                  "org.kde.plasma.taskmanager"
              ]);
              addFirstAvailable(panel, [
                  "org.kde.plasma.systemtray"
              ]);
              addFirstAvailable(panel, [
                  "org.kde.plasma.digitalclock"
              ]);
          }
          EOSCRIPT

              for _ in $(seq 1 120); do
                if ${pkgs.dbus}/bin/dbus-send --session --dest=org.kde.plasmashell \
                  --type=method_call --print-reply=literal \
                  /PlasmaShell org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
                  sleep "$delay_s"
                  ${pkgs.glib}/bin/gdbus call --session \
                    --dest org.kde.plasmashell \
                    --object-path /PlasmaShell \
                    --method org.kde.PlasmaShell.evaluateScript \
                    "$(${pkgs.coreutils}/bin/cat "$script_file")" >>"$log_file" 2>&1 || true
                  exit 0
                fi
                sleep 0.5
              done

              echo "[KDE] plasmashell DBus service did not appear for ensure panel pass" >>"$log_file"
            ) &
          }

          ensure_basic_plasma_panel

          apply_narrow_plasma_shell() {
            if [ "''${GOW_KDE_NARROW_PLASMA:-0}" != "1" ]; then
              return 0
            fi

            (
              local script_file="/tmp/gow-kde-narrow-plasma.js"
              local log_file="/tmp/gow-kde-narrow-plasma.log"
              local delay_s="''${GOW_KDE_NARROW_PLASMA_DELAY:-2}"

              cat > "$script_file" <<'EOSCRIPT'
          const log = (msg) => print("[gow-kde] " + msg);

          log("narrowing plasmashell state");

          for (const panelId of panelIds.slice()) {
              const panel = panelById(panelId);
              if (!panel) {
                  continue;
              }
              log("removing panel " + panel.id);
              panel.remove();
          }

          for (const desktop of desktops()) {
              for (const widget of desktop.widgets()) {
                  log("removing desktop widget " + widget.type + "#" + widget.id);
                  widget.remove();
              }

              desktop.currentConfigGroup = ["General"];
              desktop.writeConfig("ToolBoxButtonState", "hidden");
              desktop.reloadConfig();
          }
          EOSCRIPT

              for _ in $(seq 1 120); do
                if ${pkgs.dbus}/bin/dbus-send --session --dest=org.kde.plasmashell \
                  --type=method_call --print-reply=literal \
                  /PlasmaShell org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
                  sleep "$delay_s"
                  ${pkgs.glib}/bin/gdbus call --session \
                    --dest org.kde.plasmashell \
                    --object-path /PlasmaShell \
                    --method org.kde.PlasmaShell.evaluateScript \
                    "$(${pkgs.coreutils}/bin/cat "$script_file")" >>"$log_file" 2>&1 || true
                  exit 0
                fi
                sleep 0.5
              done

              echo "[KDE] plasmashell DBus service did not appear for narrow shell pass" >>"$log_file"
            ) &
          }

          apply_narrow_plasma_shell

          if [ "$GOW_KDE_APPLY_GRAPHICS_RUNTIME" = "1" ]; then
            gow_apply_graphics_runtime_env
          fi

          # KWin nested on Wayland can fail GPU discovery in containers and end up
          # with an empty DRM node. Pick the first accessible /dev/dri/card*.
          pick_kwin_drm_device() {
            local node
            shopt -s nullglob
            for node in /dev/dri/card*; do
              [ -c "$node" ] || continue
              [ -r "$node" ] || continue
              printf '%s\n' "$node"
              shopt -u nullglob
              return 0
            done
            shopt -u nullglob
            return 1
          }

          log_kwin_drm_state() {
            local log_file="/tmp/gow-kde-drm.log"
            {
              echo "[KDE] drm probe at $(${pkgs.coreutils}/bin/date --iso-8601=seconds)"
              if [ -d /dev/dri ]; then
                ${pkgs.coreutils}/bin/ls -l /dev/dri || true
              else
                echo "[KDE] /dev/dri missing"
              fi
              echo "[KDE] selected KWIN_DRM_DEVICES=''${KWIN_DRM_DEVICES:-unset}"
            } >"$log_file" 2>&1 || true
          }

          if [ -z "''${KWIN_DRM_DEVICES:-}" ] && [ "''${GOW_KDE_SET_KWIN_DRM_DEVICE:-0}" = "1" ]; then
            kwin_drm_device="$(pick_kwin_drm_device || true)"
            if [ -n "$kwin_drm_device" ]; then
              export KWIN_DRM_DEVICES="$kwin_drm_device"
            fi
          fi
          log_kwin_drm_state
          if [ "$GOW_KDE_FORCE_KWIN_GL_ENV" = "1" ]; then
            export KWIN_OPENGL_INTERFACE="''${KWIN_OPENGL_INTERFACE:-egl}"
            export KWIN_COMPOSE="''${KWIN_COMPOSE:-O2}"
          else
            unset KWIN_OPENGL_INTERFACE
            unset KWIN_COMPOSE
          fi

          if ! gow_export_wolf_wayland_env /run/wolf 80 0.1; then
            echo "[KDE] missing Wolf Wayland socket under /run/wolf"
            exit 1
          fi

          wolf_mode="''${GOW_WOLF_OUTPUT_MODE:-''${GAMESCOPE_WIDTH}x''${GAMESCOPE_HEIGHT}}"
          if [ "''${GOW_KDE_INITIAL_WOLF_OUTPUT_RECONCILE:-0}" = "1" ]; then
            gow_reconcile_wolf_output_scale "$WAYLAND_DISPLAY" 20 0.1 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
          fi
          if [ "''${GOW_KDE_BACKGROUND_WOLF_OUTPUT_RECONCILE:-0}" = "1" ]; then
            (
              gow_reconcile_wolf_output_scale "$WAYLAND_DISPLAY" 120 0.1 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
              if [ "''${GOW_KDE_MAINTAIN_WOLF_OUTPUT_SCALE:-0}" = "1" ]; then
                gow_maintain_wolf_output_scale "$WAYLAND_DISPLAY" 240 0.5 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
              fi
            ) &
          elif [ "''${GOW_KDE_MAINTAIN_WOLF_OUTPUT_SCALE:-0}" = "1" ]; then
            (
              gow_maintain_wolf_output_scale "$WAYLAND_DISPLAY" 240 0.5 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
            ) &
          fi

          echo "[KDE] WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-unset}"
          echo "[KDE] GAMESCOPE=''${GAMESCOPE_WIDTH:-unset}x''${GAMESCOPE_HEIGHT:-unset}@''${GAMESCOPE_REFRESH:-unset}"
          echo "[KDE] XDG_MENU_PREFIX=''${XDG_MENU_PREFIX:-unset}"
          echo "[KDE] KWIN_DRM_DEVICES=''${KWIN_DRM_DEVICES:-unset}"
          echo "[KDE] session mode=''${GOW_KDE_SESSION_MODE:-full}"
          echo "[KDE] apply graphics runtime=''${GOW_KDE_APPLY_GRAPHICS_RUNTIME:-0}"
          echo "[KDE] force kwin gl env=''${GOW_KDE_FORCE_KWIN_GL_ENV:-0}"
          echo "[KDE] qtquick software=''${GOW_KDE_QTQUICK_SOFTWARE:-0}"
          echo "[KDE] QT_QUICK_BACKEND=''${QT_QUICK_BACKEND:-unset}"
          echo "[KDE] QSG_RHI_BACKEND=''${QSG_RHI_BACKEND:-unset}"
          echo "[KDE] KWIN_OPENGL_INTERFACE=''${KWIN_OPENGL_INTERFACE:-unset}"
          echo "[KDE] KWIN_COMPOSE=''${KWIN_COMPOSE:-unset}"
          echo "[KDE] set kwin drm device=''${GOW_KDE_SET_KWIN_DRM_DEVICE:-0}"
          echo "[KDE] strip kickerdash=''${GOW_KDE_STRIP_KICKERDASH:-0}"
          echo "[KDE] repair broken widgets=''${GOW_KDE_REPAIR_BROKEN_WIDGETS:-0}"
          echo "[KDE] restore kickerdash=''${GOW_KDE_RESTORE_KICKERDASH:-1}"
          echo "[KDE] ensure panel=''${GOW_KDE_ENSURE_PANEL:-1}"
          echo "[KDE] repair widgets delay=''${GOW_KDE_REPAIR_WIDGETS_DELAY:-2}"
          echo "[KDE] narrow plasma=''${GOW_KDE_NARROW_PLASMA:-0}"
          echo "[KDE] narrow plasma delay=''${GOW_KDE_NARROW_PLASMA_DELAY:-2}"
          echo "[KDE] initial wolf output reconcile=''${GOW_KDE_INITIAL_WOLF_OUTPUT_RECONCILE:-0}"
          echo "[KDE] background wolf output reconcile=''${GOW_KDE_BACKGROUND_WOLF_OUTPUT_RECONCILE:-0}"
          echo "[KDE] maintain wolf output scale=''${GOW_KDE_MAINTAIN_WOLF_OUTPUT_SCALE:-0}"

          gow_export_pulse_server_from_wolf
          gow_require_session_bus /run/user/1000/bus 200 0.1
          gow_export_logind_session_id 1000 retro seat0

          ${mkSyncDbusActivationCommand [
            "QT_QPA_PLATFORM"
            "QSG_RHI_BACKEND"
            "QT_QUICK_BACKEND"
            "QT_WAYLAND_DISABLE_WINDOWDECORATION"
            "KWIN_DRM_DEVICES"
            "KWIN_OPENGL_INTERFACE"
            "KWIN_COMPOSE"
          ]}
          ${mkImportEnvironmentCommand [
            "QT_QPA_PLATFORM"
            "QSG_RHI_BACKEND"
            "QT_QUICK_BACKEND"
            "QT_WAYLAND_DISABLE_WINDOWDECORATION"
            "GOW_KDE_SESSION_MODE"
            "KWIN_DRM_DEVICES"
            "KWIN_OPENGL_INTERFACE"
            "KWIN_COMPOSE"
          ]}

          plasma_full_session_exec() {
            local runner=""
            for candidate in \
              ${pkgs.kdePackages.plasma-workspace}/libexec/plasma-dbus-run-session-if-needed \
              ${pkgs.kdePackages.plasma-workspace}/bin/plasma-dbus-run-session-if-needed \
              /run/current-system/sw/libexec/plasma-dbus-run-session-if-needed \
              /run/current-system/sw/bin/plasma-dbus-run-session-if-needed; do
              if [ -x "$candidate" ]; then
                runner="$candidate"
                break
              fi
            done

            if [ -n "$runner" ]; then
              echo "[KDE] using session runner: $runner"
              exec "$runner" ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland
            fi

            echo "[KDE] session runner not found, starting Plasma directly"
            exec ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland
          }

          case "$GOW_KDE_SESSION_MODE" in
            minimal)
              exec ${pkgs.kdePackages.kwin}/bin/kwin_wayland --xwayland --exit-with-session=${pkgs.kdePackages.plasma-workspace}/bin/plasmashell
              ;;
            full)
              plasma_full_session_exec
              ;;
            *)
              echo "[KDE] unknown session mode: $GOW_KDE_SESSION_MODE"
              exit 1
              ;;
          esac
        '';
        serviceConfig = mkWolfDesktopServiceConfig "wolf-kde-session";
      };

      # Small debug/inspection set; Plasma packages come from upstream modules.
      environment.systemPackages = with pkgs; [
        dbus
        dconf
        glib
        systemd
        pipewire
        kdePackages.systemsettings
        kdePackages.konsole
        kdePackages.dolphin
        kdePackages.plasma-pa
      ];
    };
  };

  nixosLabwcSystem = import "${pkgs.path}/nixos" {
    system = pkgs.system;
    configuration = { pkgs, lib, ... }: {
      boot.isContainer = true;
      networking.hostName = "wolf-labwc";
      system.stateVersion = "25.05";

      documentation.enable = false;
      documentation.man.enable = false;

      users.allowNoPasswordLogin = true;
      users.mutableUsers = false;
      users.groups.retro.gid = 1000;
      users.groups.video = { };
      users.groups.render = { };
      users.groups.input = { };
      users.groups.audio = { };
      users.users.root.initialHashedPassword = "!";
      users.users.retro = {
        isNormalUser = true;
        uid = 1000;
        group = "retro";
        extraGroups = [ "video" "render" "input" "audio" ];
        home = "/home/retro";
        createHome = true;
        linger = true;
        initialHashedPassword = "!";
      };

      programs.labwc.enable = true;
      programs.dconf.enable = true;
      services.dbus.enable = true;
      services.pipewire.enable = true;
      services.upower.enable = lib.mkForce true;
      xdg.portal = {
        enable = true;
        wlr.enable = lib.mkForce false;
        extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
        config.common.default = lib.mkForce [ "gtk" ];
        config.wlroots.default = lib.mkForce [ "gtk" ];
      };

      # Stage-2 activation in this container rootfs cannot rewrite /bin.
      system.activationScripts.binsh = lib.mkForce "";

      security.pam.services.wolf-session-anchor.startSession = true;
      security.pam.services.wolf-labwc-session.startSession = true;

      systemd.user.services.wolf-noctalia-shell = {
        description = "Wolf Noctalia Shell";
        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = "2s";
          StandardOutput = "append:/tmp/gow-noctalia.log";
          StandardError = "append:/tmp/gow-noctalia.log";
        };
        script = ''
          set -euo pipefail
          : "''${WAYLAND_DISPLAY:?WAYLAND_DISPLAY is required for Noctalia}"
          # Noctalia 4.3.x wrapper can miss wayland protocol data in XDG_DATA_DIRS,
          # which leaves the shell running but without visible panels.
          export XDG_DATA_DIRS="${pkgs.wayland-scanner}/share:''${XDG_DATA_DIRS:-/run/current-system/sw/share:/usr/share}"
          export QT_QPA_PLATFORM=wayland
          exec ${noctaliaShell}/bin/noctalia-shell
        '';
      };

      # Compatibility layer primitive:
      # keep a real logind/PAM user session alive for compositor/session matching.
      systemd.services.wolf-session-anchor = mkWolfSessionAnchorService "wolf-labwc-session.service";

      systemd.services.wolf-labwc-session = {
        description = "Wolf Labwc Session";
        wantedBy = [ "multi-user.target" ];
        after = [ "dbus.service" "systemd-user-sessions.service" "user@1000.service" "wolf-session-anchor.service" ];
        wants = [ "dbus.service" "user@1000.service" "wolf-session-anchor.service" ];
        path = with pkgs; [
          coreutils
          dbus
          gawk
          gnugrep
          systemd
          wlr-randr
          labwc
          noctaliaShell
          waybar
          kitty
          ungoogled-chromium
          emacs
        ];
        preStart = sessionUserDirsPreStart;
        script = ''
          set -euo pipefail

          source /opt/gow/bash-lib/desktop-compat.sh

          export HOME=/home/retro
          export XDG_RUNTIME_DIR=/run/user/1000
          export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
          export XDG_SESSION_TYPE=wayland
          export XDG_SESSION_CLASS=user
          export XDG_SESSION_DESKTOP=labwc
          export XDG_CURRENT_DESKTOP=labwc
          export XDG_SEAT=seat0
          export XDG_CONFIG_DIRS="/run/current-system/sw/etc/xdg:/etc/xdg"
          export XDG_DATA_DIRS="/run/current-system/sw/share:/nix/var/nix/profiles/default/share:/etc/profiles/per-user/retro/share:/usr/local/share:/usr/share"
          export GAMESCOPE_WIDTH="''${GAMESCOPE_WIDTH:-1920}"
          export GAMESCOPE_HEIGHT="''${GAMESCOPE_HEIGHT:-1080}"
          export GAMESCOPE_REFRESH="''${GAMESCOPE_REFRESH:-60}"
          export WLR_BACKENDS="''${WLR_BACKENDS:-wayland}"
          export WLR_NO_HARDWARE_CURSORS="''${WLR_NO_HARDWARE_CURSORS:-1}"

          gow_apply_common_ui_scale_defaults
          gow_apply_graphics_runtime_env

          if ! gow_export_wolf_wayland_env /run/wolf 80 0.1; then
            echo "[Labwc] missing Wolf Wayland socket under /run/wolf"
            exit 1
          fi

          wolf_mode="''${GOW_WOLF_OUTPUT_MODE:-''${GAMESCOPE_WIDTH}x''${GAMESCOPE_HEIGHT}}"
          gow_reconcile_wolf_output_scale "$WAYLAND_DISPLAY" 120 0.1 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
          (
            gow_maintain_wolf_output_scale "$WAYLAND_DISPLAY" 240 0.5 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
          ) &

          gow_export_pulse_server_from_wolf
          gow_require_session_bus /run/user/1000/bus 200 0.1
          gow_export_logind_session_id 1000 retro seat0

          ${mkSyncDbusActivationCommand [
            "WLR_BACKENDS"
            "WLR_NO_HARDWARE_CURSORS"
          ]}
          ${mkImportEnvironmentCommand [
            "WLR_BACKENDS"
            "WLR_NO_HARDWARE_CURSORS"
          ]}

          exec ${pkgs.labwc}/bin/labwc --startup /cfg/labwc/autostart
        '';
        serviceConfig = mkWolfDesktopServiceConfig "wolf-labwc-session";
      };

      environment.systemPackages = with pkgs; [
        dbus
        dconf
        glib
        systemd
        pipewire
        labwc
        noctaliaShell
        waybar
        kitty
        ungoogled-chromium
        emacs
      ];
    };
  };

  nixosXfceSystem = import "${pkgs.path}/nixos" {
    system = pkgs.system;
    configuration = { pkgs, lib, ... }: {
      boot.isContainer = true;
      networking.hostName = "wolf-xfce";
      system.stateVersion = "25.05";

      documentation.enable = false;
      documentation.man.enable = false;

      users.allowNoPasswordLogin = true;
      users.mutableUsers = false;
      users.groups.retro.gid = 1000;
      users.groups.video = { };
      users.groups.render = { };
      users.groups.input = { };
      users.groups.audio = { };
      users.users.root.initialHashedPassword = "!";
      users.users.retro = {
        isNormalUser = true;
        uid = 1000;
        group = "retro";
        extraGroups = [ "video" "render" "input" "audio" ];
        home = "/home/retro";
        createHome = true;
        linger = true;
        initialHashedPassword = "!";
      };

      services.xserver.desktopManager.xfce = {
        enable = true;
        enableWaylandSession = true;
        enableScreensaver = false;
      };
      programs.labwc.enable = true;
      programs.dconf.enable = true;
      services.dbus.enable = true;
      services.pipewire.enable = true;
      services.upower.enable = lib.mkForce true;

      # Stage-2 activation in this container rootfs cannot rewrite /bin.
      system.activationScripts.binsh = lib.mkForce "";

      security.pam.services.wolf-session-anchor.startSession = true;
      security.pam.services.wolf-xfce-session.startSession = true;

      # Compatibility layer primitive:
      # keep a real logind/PAM user session alive for compositor/session matching.
      systemd.services.wolf-session-anchor = mkWolfSessionAnchorService "wolf-xfce-session.service";

      systemd.services.wolf-xfce-session = {
        description = "Wolf XFCE Session";
        wantedBy = [ "multi-user.target" ];
        after = [ "dbus.service" "systemd-user-sessions.service" "user@1000.service" "wolf-session-anchor.service" ];
        wants = [ "dbus.service" "user@1000.service" "wolf-session-anchor.service" ];
        path = with pkgs; [
          coreutils
          dbus
          gnugrep
          gawk
          systemd
          wlr-randr
        ];
        preStart = sessionUserDirsPreStart;
        script = ''
          set -euo pipefail

          source /opt/gow/bash-lib/desktop-compat.sh

          export HOME=/home/retro
          export XDG_RUNTIME_DIR=/run/user/1000
          export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
          export XDG_SESSION_TYPE=wayland
          export XDG_SESSION_CLASS=user
          export XDG_SESSION_DESKTOP=XFCE
          export XDG_CURRENT_DESKTOP=XFCE
          export XDG_SEAT=seat0
          export XDG_CONFIG_DIRS="/run/current-system/sw/etc/xdg:/etc/xdg"
          export XDG_DATA_DIRS="/run/current-system/sw/share:/nix/var/nix/profiles/default/share:/etc/profiles/per-user/retro/share:/usr/local/share:/usr/share"
          export GAMESCOPE_WIDTH="''${GAMESCOPE_WIDTH:-1920}"
          export GAMESCOPE_HEIGHT="''${GAMESCOPE_HEIGHT:-1080}"
          export GAMESCOPE_REFRESH="''${GAMESCOPE_REFRESH:-60}"
          export WLR_BACKENDS="''${WLR_BACKENDS:-wayland}"
          export WLR_NO_HARDWARE_CURSORS="''${WLR_NO_HARDWARE_CURSORS:-1}"

          gow_apply_common_ui_scale_defaults
          gow_apply_graphics_runtime_env

          if ! gow_export_wolf_wayland_env /run/wolf 80 0.1; then
            echo "[XFCE] missing Wolf Wayland socket under /run/wolf"
            exit 1
          fi

          wolf_mode="''${GOW_WOLF_OUTPUT_MODE:-''${GAMESCOPE_WIDTH}x''${GAMESCOPE_HEIGHT}}"
          gow_reconcile_wolf_output_scale "$WAYLAND_DISPLAY" 120 0.1 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
          (
            gow_maintain_wolf_output_scale "$WAYLAND_DISPLAY" 240 0.5 1 "$wolf_mode" /tmp/gow-wolf-randr.log || true
          ) &

          gow_export_pulse_server_from_wolf
          gow_require_session_bus /run/user/1000/bus 200 0.1
          gow_export_logind_session_id 1000 retro seat0

          (
            gow_reconcile_wlr_output_scale "$XDG_RUNTIME_DIR" 120 0.2 1 "" /tmp/gow-xfce-wlr-randr.log || true
            gow_maintain_wlr_output_scale "$XDG_RUNTIME_DIR" 240 0.5 1 "" /tmp/gow-xfce-wlr-randr.log || true
          ) &

          ${mkSyncDbusActivationCommand [
            "WLR_BACKENDS"
            "WLR_NO_HARDWARE_CURSORS"
          ]}
          ${mkImportEnvironmentCommand [
            "WLR_BACKENDS"
            "WLR_NO_HARDWARE_CURSORS"
          ]}

          exec /run/current-system/sw/bin/startxfce4 --wayland
        '';
        serviceConfig = mkWolfDesktopServiceConfig "wolf-xfce-session";
      };

      environment.systemPackages = with pkgs; [
        dbus
        dconf
        glib
        systemd
        pipewire
        labwc
        wlr-randr
        xfce4-panel
        xfdesktop
        xfce4-terminal
        xfce4-settings
      ];
    };
  };
in
{
  inherit
    nixosGnomeSystem
    nixosKdeSystem
    nixosLabwcSystem
    nixosXfceSystem;

  nixosGnomeSystemMount = nixosGnomeSystem.config.system.build.toplevel;
  nixosKdeSystemMount = nixosKdeSystem.config.system.build.toplevel;
  nixosLabwcSystemMount = nixosLabwcSystem.config.system.build.toplevel;
  nixosXfceSystemMount = nixosXfceSystem.config.system.build.toplevel;
}
