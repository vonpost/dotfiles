{ config, pkgs, ... }:
let
  wgIf = config.services.wg_server_systemd.internalInterface;
  # Both wg peers run PersistentKeepalive=25, so a handshake younger than
  # ~3 minutes is cryptographic proof that inbound traffic reaches us.
  # Outbound ping is the weaker fallback signal: it avoids burning boot
  # tries when every peer happens to be offline, while still failing on
  # dead WAN/routing.
  reachabilityProbe = pkgs.writeShellScript "reachability-probe" ''
    set -eu
    now=$(date +%s)
    hs=$(${pkgs.wireguard-tools}/bin/wg show ${wgIf} latest-handshakes 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '{print $2}' | sort -n | tail -1)
    if [ -n "''${hs:-}" ] && [ "$hs" -gt 0 ] && [ $((now - hs)) -lt 180 ]; then
      echo "reachable: wg handshake $((now - hs))s ago"
      exit 0
    fi
    if ${pkgs.iputils}/bin/ping -c1 -W3 9.9.9.9 > /dev/null 2>&1; then
      echo "reachable (weak): no recent wg handshake, but outbound works"
      exit 0
    fi
    exit 1
  '';
in
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

  # "Good" must mean provably reachable, not merely booted: sshd up AND the
  # reachability probe passing (wg handshake, or at least working outbound).
  # A boot that comes up dark burns a try and the next one falls back. The
  # window is deliberately generous: recovery may depend on VMs (MAMORU
  # carries the WAN path) that take a while to come up, and a healthy boot
  # exits the loop on the first success.
  systemd.services.boot-reachable = {
    description = "Gate boot blessing on remote reachability";
    requiredBy = [ "boot-complete.target" ];
    before = [ "boot-complete.target" ];
    after = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "20min";
    };
    path = [ config.systemd.package ];
    script = ''
      for _ in $(seq 450); do
        if systemctl is-active --quiet sshd.service && ${reachabilityProbe}; then
          exit 0
        fi
        sleep 2
      done
      echo "not blessing this boot: no reachability evidence after 15 minutes" >&2
      exit 1
    '';
  };

  # Escalation stage for the runtime deadman (infra deploy mother): after a
  # rollback fires, the deadman schedules this service. Rolling back config
  # does not always roll back network *state* — a reboot into the restored
  # generation rebuilds it from scratch, and lands in a counted boot entry
  # gated by the same reachability probe. Started only by the deadman's
  # stage-2 timer, never at boot.
  systemd.services.infra-net-rescue = {
    description = "Reboot if still unreachable after deadman rollback";
    serviceConfig.Type = "oneshot";
    path = [ config.systemd.package ];
    script = ''
      if ${reachabilityProbe}; then
        echo "reachability restored by rollback; staying up"
        exit 0
      fi
      echo "still unreachable after rollback; rebooting to rebuild network state"
      systemctl reboot
    '';
  };
}
