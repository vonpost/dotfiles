{ config, pkgs, lib, ... }:

let
  svc = import ../config/infra/services/lib.nix { inherit config; };
  myaddrUpdateScript = pkgs.writeShellScript "myaddr-update" ''
    set -euo pipefail

    echo "reading api and fetching current ip"
    ip="''$(${pkgs.curl}/bin/curl -fsS https://api.ipify.org)"
    url="https://myaddr.tools/update?key=''$(${pkgs.coreutils}/bin/cat $CREDENTIALS_DIRECTORY/myaddr_api_key)&ip=''${ip}"

    ${pkgs.curl}/bin/curl -fsS --retry 3 --retry-delay 1 "''$url"

    echo "myaddr.tools updated to $ip"
  '';
in
{
  config = lib.mkIf (svc.hasService "myaddr") {

    systemd.services.myaddr-update = {
      description = "Update myaddr.tools dynamic DNS";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = myaddrUpdateScript;
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
        OnUnitActiveSec = "60m";  # adjust to taste (5-15m typical)
        Unit = "myaddr-update.service";
        Persistent = true;
        RandomizedDelaySec = "30s";
      };
    };
  };
}
