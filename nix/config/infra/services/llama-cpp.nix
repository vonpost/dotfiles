{ config, lib, pkgs, bleeding, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  llamaCppCfg = import ./llama-cpp-config.nix;
  routerWatchdog = pkgs.writeShellApplication {
    name = "llama-cpp-router-watchdog";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      procps
      systemd
    ];
    text = ''
      set -eu

      main_pid="$(systemctl show -p MainPID --value llama-cpp.service)"
      if [ -z "$main_pid" ] || [ "$main_pid" = "0" ]; then
        exit 0
      fi

      child_pids="$(pgrep -P "$main_pid" -x llama-server || true)"
      if [ -z "$child_pids" ]; then
        exit 0
      fi

      zombie_detected=0
      for pid in $child_pids; do
        stat="$(ps -o stat= -p "$pid" | tr -d '[:space:]')"
        case "$stat" in
          *Z*)
            zombie_detected=1
            ;;
        esac
      done

      if [ "$zombie_detected" -eq 1 ]; then
        echo "llama-cpp-router-watchdog: restarting llama-cpp because zombie worker child was detected"
        systemctl restart llama-cpp.service
      fi
    '';
  };
in
{
  config = lib.mkIf (svc.hasService "llama-cpp") {
    services.llama-cpp = {
      enable = true;
      package = bleeding.llama-cpp.override { cudaSupport = true; };
      port = svc.getPort "llama_server";
      host = llamaCppCfg.host;
      model = llamaCppCfg.model;
      modelsDir = llamaCppCfg.modelsDir;
      extraFlags = llamaCppCfg.extraFlags;
    };

    # The GPU is shared with wolf and jellyfin, and llama-cpp serves nothing but
    # logDigest. So it never auto-starts: a timer opens a window, and
    # RuntimeMaxSec closes it whether or not the digest finished.
    systemd.services.llama-cpp.wantedBy = lib.mkForce [ ];
    # Requisite refuses starts outside an active window without opening one.
    # PartOf also stops watchdog-restarted workers when that window closes.
    systemd.services.llama-cpp.requisite = [ "llama-cpp-window.service" ];
    systemd.services.llama-cpp.after = [ "llama-cpp-window.service" ];
    systemd.services.llama-cpp.partOf = [ "llama-cpp-window.service" ];
    systemd.services.llama-cpp.serviceConfig.TimeoutStopSec = "15s";

    systemd.services.llama-cpp-window = {
      description = "Bounded GPU window for llama-cpp";
      serviceConfig = {
        # RuntimeMaxSec does not bound a oneshot unit. Keep a real main process
        # alive, and queue server startup only after this unit becomes active.
        Type = "exec";
        ExecStart = "${pkgs.coreutils}/bin/sleep ${toString llamaCppCfg.gpuWindowSeconds}";
        ExecStartPost = "${pkgs.systemd}/bin/systemctl --no-block start llama-cpp.service";
        ExecStopPost = "${pkgs.systemd}/bin/systemctl --no-block stop llama-cpp.service";
        RuntimeMaxSec = llamaCppCfg.gpuWindowMaxSec;
        TimeoutStartSec = "30s";
        TimeoutStopSec = "20s";
        Restart = "no";
      };
    };

    # Absolute close times also cover a delayed opening; the runtime limit is
    # a second independent backstop. Neither timer catches up after boot.
    systemd.services.llama-cpp-window-close = {
      description = "Close the overnight llama-cpp GPU window";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl stop llama-cpp-window.service llama-cpp.service";
        TimeoutStartSec = "45s";
      };
    };
    systemd.timers.llama-cpp-window-close = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = llamaCppCfg.gpuWindowClose;
        Persistent = false;
        AccuracySec = "1s";
      };
    };

    systemd.timers.llama-cpp-window = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = llamaCppCfg.gpuWindowOpen;
        # Not Persistent: a missed window must not reopen at an arbitrary time
        # after boot, which would defeat the whole point of bounding it.
        Persistent = false;
        AccuracySec = "1s";
      };
    };

    systemd.services.llama-cpp-router-watchdog = {
      description = "Restart llama-cpp if router mode leaves behind a zombie worker";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${routerWatchdog}/bin/llama-cpp-router-watchdog";
      };
      # Only meaningful while llama-cpp is actually running.
      unitConfig.ConditionPathExists = "/run/systemd/units/invocation:llama-cpp.service";
    };

    systemd.timers.llama-cpp-router-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3m";
        OnUnitActiveSec = "2m";
        Unit = "llama-cpp-router-watchdog.service";
      };
    };
  };
}
