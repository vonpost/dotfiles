{ config, pkgs, lib, ... }:

let
  myaddrEnvFile = "/myaddr/env";

  myaddrUpdateScript = pkgs.writeShellScript "myaddr-update" ''
    set -euo pipefail

    ip="''$(${pkgs.curl}/bin/curl -fsS https://api.ipify.org)"
    url="https://myaddr.tools/update?key=''${MYADDR_KEY}&ip=''${ip}"

    ${pkgs.curl}/bin/curl -fsS --retry 3 --retry-delay 1 "''$url"

    echo "myaddr.tools updated to $ip"
  '';
in
{

  microvm.shares = [
    {
      proto = "virtiofs";
      tag = "myaddr";
      source = "/run/secrets/myaddr";
      mountPoint = "/myaddr";
    }
  ];

  systemd.services.myaddr-update = {
    description = "Update myaddr.tools dynamic DNS";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = myaddrUpdateScript;

      EnvironmentFile = "/myaddr/env";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      SystemCallArchitectures = "native";
    };
  };

  systemd.timers.myaddr-update = {
    description = "Timer for myaddr.tools dynamic DNS update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "60m";  # adjust to taste (5–15m typical)
      Unit = "myaddr-update.service";
      Persistent = true;
      RandomizedDelaySec = "30s";
    };
  };
}
