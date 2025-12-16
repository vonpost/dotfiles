{ config, bleeding, ... }:
{
  services.picom.enable = false;

  systemd.user.services.picom = {
    description = "Picom compositor (user config)";
    wantedBy = [ "default.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = [ "" "${bleeding.picom}/bin/picom" ];
      Restart = "on-failure";
    };
  };
}
