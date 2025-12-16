{ config, lib, pkgs, ... }:

{
  services.displayManager = {
    defaultSession = "none+xmonad";
  };
  services.xserver = {
    enable = true;
    xkb = {
      layout = "us";
      options = "eurosign:e";
    };
    videoDrivers = [ "amdgpu" ];
    # WINDOW MANAGER
    windowManager = {
      xmonad = {
        enable = true;
        enableContribAndExtras = true;
        extraPackages = haskellPackages: [
          haskellPackages.xmonad-contrib
	        haskellPackages.xmonad-extras
	        haskellPackages.xmonad
	      ];
      };
    };


    # DISPLAY MANAGER
    displayManager.sessionCommands =
        # Set background image with feh
        # Trackpoint settings
        ''
        feh --bg-tile /home/dcol/wallpapers/mactex1.png
        xinput set-prop "TPPS/2 Elan TrackPoint" "libinput Accel Speed" 1
        xinput set-prop "TPPS/2 Elan TrackPoint" "libinput Accel Profile Enabled" 0, 1
        xsetroot -cursor_name  left_ptr
        '';
    desktopManager.xterm.enable = false;
  };
}
