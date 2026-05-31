{ config, pkgs, ... }:

let
  lowBatteryPercent = 20;
  criticalBatteryPercent = 10;
  hybridSleepDelaySeconds = 30;
  desktopUser = "dcol";

  batteryGuard = pkgs.writeShellApplication {
    name = "terra-battery-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libnotify
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      is_uint() {
        case "''${1:-}" in
          ""|*[!0-9]*) return 1 ;;
          *) return 0 ;;
        esac
      }

      battery_percent() {
        local bat now full capacity
        local total_now=0
        local total_full=0
        local capacity_total=0
        local capacity_count=0

        shopt -s nullglob
        for bat in /sys/class/power_supply/BAT*; do
          [ -d "$bat" ] || continue

          if [ -r "$bat/energy_now" ] && [ -r "$bat/energy_full" ]; then
            now="$(<"$bat/energy_now")"
            full="$(<"$bat/energy_full")"
          elif [ -r "$bat/charge_now" ] && [ -r "$bat/charge_full" ]; then
            now="$(<"$bat/charge_now")"
            full="$(<"$bat/charge_full")"
          else
            now=""
            full=""
          fi

          if is_uint "$now" && is_uint "$full" && [ "$full" -gt 0 ]; then
            total_now=$((total_now + now))
            total_full=$((total_full + full))
          elif [ -r "$bat/capacity" ]; then
            capacity="$(<"$bat/capacity")"
            if is_uint "$capacity"; then
              capacity_total=$((capacity_total + capacity))
              capacity_count=$((capacity_count + 1))
            fi
          fi
        done

        if [ "$total_full" -gt 0 ]; then
          printf '%s\n' $((total_now * 100 / total_full))
        elif [ "$capacity_count" -gt 0 ]; then
          printf '%s\n' $((capacity_total / capacity_count))
        else
          return 1
        fi
      }

      on_battery() {
        local ps type online status

        shopt -s nullglob
        for ps in /sys/class/power_supply/*; do
          [ -r "$ps/type" ] || continue
          type="$(<"$ps/type")"
          case "$type" in
            Mains|USB|USB_C|USB_PD)
              if [ -r "$ps/online" ]; then
                online="$(<"$ps/online")"
                [ "$online" = "1" ] && return 1
              fi
              ;;
          esac
        done

        for ps in /sys/class/power_supply/BAT*; do
          [ -r "$ps/status" ] || continue
          status="$(<"$ps/status")"
          [ "$status" = "Discharging" ] && return 0
        done

        return 1
      }

      notify_desktop() {
        local title="$1"
        local body="$2"
        local user="${desktopUser}"
        local uid

        if ! uid="$(id -u "$user" 2>/dev/null)"; then
          return 0
        fi
        [ -S "/run/user/$uid/bus" ] || return 0

        runuser -u "$user" -- env \
          XDG_RUNTIME_DIR="/run/user/$uid" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
          notify-send \
            --app-name="Battery" \
            --urgency=critical \
            --expire-time=0 \
            "$title" \
            "$body" || true
      }

      notify_low() {
        local percent now level last_level="" last=0
        local state_dir="''${XDG_RUNTIME_DIR:-/tmp}/terra-battery-guard"
        local state_file="$state_dir/notified-low"
        local state_level_file="$state_dir/notified-low-level"

        mkdir -p "$state_dir"

        if ! on_battery; then
          rm -f "$state_file" "$state_level_file"
          return 0
        fi

        percent="$(battery_percent)" || return 0
        if [ "$percent" -gt ${toString lowBatteryPercent} ]; then
          rm -f "$state_file" "$state_level_file"
          return 0
        fi

        if [ -r "$state_file" ]; then
          last="$(<"$state_file")"
          is_uint "$last" || last=0
        fi
        if [ -r "$state_level_file" ]; then
          last_level="$(<"$state_level_file")"
        fi

        now="$(date +%s)"
        if [ "$percent" -le ${toString criticalBatteryPercent} ]; then
          level="critical"
        else
          level="low"
        fi

        if [ "$level" = "$last_level" ] && [ $((now - last)) -lt 600 ]; then
          return 0
        fi

        notify-send \
          --app-name="Battery" \
          --urgency=critical \
          --expire-time=0 \
          "Battery low ($percent%)" \
          "Plug in power. TERRA will hybrid-sleep after ${toString hybridSleepDelaySeconds} seconds below ${toString criticalBatteryPercent}%."

        printf '%s\n' "$now" > "$state_file"
        printf '%s\n' "$level" > "$state_level_file"
      }

      hybrid_sleep_low() {
        local percent now last=0
        local sleep_delay=${toString hybridSleepDelaySeconds}
        local state_dir="/run/terra-battery-guard"
        local state_file="$state_dir/hybrid-sleep-low"

        mkdir -p "$state_dir"

        if ! on_battery; then
          rm -f "$state_file"
          return 0
        fi

        percent="$(battery_percent)" || return 0
        if [ "$percent" -gt ${toString criticalBatteryPercent} ]; then
          rm -f "$state_file"
          return 0
        fi

        if [ -r "$state_file" ]; then
          last="$(<"$state_file")"
          is_uint "$last" || last=0
        fi

        now="$(date +%s)"
        if [ $((now - last)) -lt 900 ]; then
          return 0
        fi

        printf '%s\n' "$now" > "$state_file"
        printf 'Battery at %s%%; hybrid-sleep in %s seconds unless power is connected\n' "$percent" "$sleep_delay"
        notify_desktop \
          "Battery critical ($percent%)" \
          "Hybrid-sleep in $sleep_delay seconds unless power is connected."
        sleep "$sleep_delay"

        if ! on_battery; then
          rm -f "$state_file"
          printf 'Power connected; cancelling hybrid-sleep\n'
          notify_desktop \
            "Hybrid-sleep cancelled" \
            "Power is connected."
          return 0
        fi

        percent="$(battery_percent)" || return 0
        if [ "$percent" -gt ${toString criticalBatteryPercent} ]; then
          rm -f "$state_file"
          printf 'Battery recovered to %s%%; cancelling hybrid-sleep\n' "$percent"
          notify_desktop \
            "Hybrid-sleep cancelled" \
            "Battery recovered to $percent%."
          return 0
        fi

        printf 'Battery at %s%%; running systemctl hybrid-sleep\n' "$percent"
        systemctl hybrid-sleep
      }

      case "''${1:-}" in
        notify-low)
          notify_low
          ;;
        hybrid-sleep-low)
          hybrid_sleep_low
          ;;
        *)
          printf 'Usage: %s {notify-low|hybrid-sleep-low}\n' "$0" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  ############################
  ## Power management basics
  ############################
  powerManagement.enable = true;
  powerManagement.powertop.enable = true;

  services = {
    power-profiles-daemon.enable = false;
    tlp = {
        enable = true;
        settings = {
            # CPU_BOOST_ON_AC = 1;
            # CPU_BOOST_ON_BAT = 0;
            # CPU_SCALING_GOVERNOR_ON_AC = "performance";
            # CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
            STOP_CHARGE_THRESH_BAT0 = 95;
        };
    };
    system76-scheduler.settings.cfsProfiles.enable = true;
  };

  ########################################
  ## Suspend on lid / power-button actions
  ########################################
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend"; # close lid -> suspend
    HandleLidSwitchExternalPower = "suspend"; # also suspend when on AC
    HandleLidSwitchDocked = "ignore"; # don't suspend if docked

    HandlePowerKey = "suspend"; # short press power button -> suspend
    HandlePowerKeyLongPress = "poweroff"; # long press -> power off
  };
  services.upower = {
    enable = true;
    usePercentageForPolicy = true;
    percentageLow = lowBatteryPercent;       # show "low" warning
    percentageCritical = criticalBatteryPercent;  # "critical" state
    percentageAction = 5;     # when to act
    criticalPowerAction = "HybridSleep";  # fallback action at percentageAction
  };

  boot.resumeDevice = builtins.head (map (d: d.device) config.swapDevices);
  services.acpid.enable = true;

  systemd.user.services.terra-low-battery-notify = {
    description = "Persistent low battery notification for TERRA";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${batteryGuard}/bin/terra-battery-guard notify-low";
    };
  };

  systemd.user.timers.terra-low-battery-notify = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnStartupSec = "30s";
      OnUnitActiveSec = "60s";
      AccuracySec = "15s";
      Unit = "terra-low-battery-notify.service";
    };
  };

  systemd.services.terra-low-battery-hybrid-sleep = {
    description = "Hybrid-sleep TERRA when battery is critically low";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${batteryGuard}/bin/terra-battery-guard hybrid-sleep-low";
    };
  };

  systemd.timers.terra-low-battery-hybrid-sleep = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "60s";
      AccuracySec = "15s";
      Unit = "terra-low-battery-hybrid-sleep.service";
    };
  };
}
