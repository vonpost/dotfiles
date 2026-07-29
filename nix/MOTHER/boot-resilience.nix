{ config, pkgs, ... }:
{
  # MOTHER is offsite: anything that wedges the machine must resolve itself.
  # kernel.panic=20 (configuration.nix) reboots after panics; the board's
  # SP5100 TCO hardware watchdog covers hard lockups where even the panic
  # handler is gone. systemd pets it while running; 30s of silence resets
  # the box. RebootWatchdogSec bounds a hung reboot/shutdown.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10m";
  };

  # Automatic boot assessment: new boot entries carry a try counter, and a
  # boot only counts as good once boot-complete.target is reached and the
  # entry blessed. After `tries` bad boots, systemd-boot falls back to the
  # previous generation on its own. This closes the reboot gap that the
  # runtime deadman in `infra deploy mother` cannot cover.
  boot.loader.systemd-boot.bootCounting = {
    enable = true;
    tries = 2;
  };

  # "Good" must mean reachable from outside, not merely booted: require sshd
  # plus the WireGuard interface before blessing. A boot that comes up
  # without remote access burns a try, and the next reboot falls back.
  systemd.services.boot-reachable = {
    description = "Gate boot blessing on remote reachability";
    requiredBy = [ "boot-complete.target" ];
    before = [ "boot-complete.target" ];
    after = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "5min";
    };
    path = [ pkgs.iproute2 config.systemd.package ];
    script = ''
      wg_if=${config.services.wg_server_systemd.internalInterface}
      for _ in $(seq 90); do
        if systemctl is-active --quiet sshd.service \
           && ip link show "$wg_if" > /dev/null 2>&1; then
          exit 0
        fi
        sleep 2
      done
      echo "not blessing this boot: sshd or $wg_if missing after 3 minutes" >&2
      exit 1
    '';
  };
}
