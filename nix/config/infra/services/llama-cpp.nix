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
      port = llamaCppCfg.port;
      host = llamaCppCfg.host;
      model = llamaCppCfg.model;
      modelsDir = llamaCppCfg.modelsDir;
      extraFlags = llamaCppCfg.extraFlags;
    };

    systemd.services.llama-cpp-router-watchdog = {
      description = "Restart llama-cpp if router mode leaves behind a zombie worker";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${routerWatchdog}/bin/llama-cpp-router-watchdog";
      };
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
