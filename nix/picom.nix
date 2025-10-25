{ config, ... }:

let
  bleeding = import <bleeding> {  };
in
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

  # services.picom = {
  #   enable = true;
  #   package = pkgs.picom-next;

  #   backend = "glx";
  #   vSync = true;

  #   fade = true;
  #   fadeDelta = 10;
  #   fadeSteps = [0.05 0.05];
  #   fadeExclude = [
  #     "window_type *= 'menu'"
  #   ];

  #   activeOpacity = 1;
  #   inactiveOpacity = 1;
  #   opacityRules = [
  #     "90:class_g = 'rofi'"
  #     "70:class_g = 'Alacritty'"
  #     "70:class_g = 'Emacs'"
  #     "100:class_g = 'slop'"
  #   ];

  #   settings = {
  #     glx-no-stencil = true;
  #     glx-copy-from-font = false;
  #     use-damage = false;

  #     frame-opacity = 1;
  #     blur-background = true;
  #     blur-method = "dual_kawase";
  #     blur-strength = 6;

  #     corner-radius = 8;

  #     rounded-corners-exclude = [
  #       "window_type = 'dock'"
  #     ];

  #     # pijulius specifics
  #     animations = true;
  #     animation-stiffness = 500;
  #     animation-window-mass = 1.0;
  #     animation-dampening = 26;
  #     animation-delta = 10;
  #     animation-force_steps = false;
  #     animation-clamping = true;

  #     animation-for-open-window = "slide-up";
  #     animation-for-menu-window = "slide-down";
  #     animation-for-transient-window = "slide-down";
  #     animation-for-unmap-window = "slide-up";

  #     animation-for-next-tag = "slide-right";
  #     animation-for-prev-tag = "slide-left";
  #     enable-fading-next-tag = true;
  #     enable-fading-prev-tag = true;
  #   };
  # };
}
