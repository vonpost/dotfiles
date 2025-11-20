{ config, pkgs, lib, ... }:
let
  trackpoint_new_name="PS/2 Synaptics TouchPad";
in
{
  # 1. Kernel: TrackPoint polling hack
  boot.kernelModules = [ "psmouse" ];
  boot.kernelParams  = [ "psmouse.proto=imps" ];

  # 2. libinput global config (no raw xorg.conf)
  services.libinput = {
    enable = true;

    mouse = {
      accelProfile = "flat";
      accelSpeed   = "1.0";
      additionalOptions = ''
      MatchProduct "${trackpoint_new_name}"
      '';
    };
  };

  # Mark the internal PS/2 device as a pointing stick
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="event[0-9]*", ENV{ID_PATH}=="platform-i8042-serio-1", ENV{ID_INPUT_POINTINGSTICK}="1"
  '';

  # 3. TrackPoint-specific speed bump via libinput quirk
  environment.etc."libinput/local-overrides.quirks".text = ''
    [Trackpoint Override]
    MatchName=*Synaptics*TouchPad*
    AttrTrackpointMultiplier=1.5
  '';
  # services.xserver.inputClassSections = [
  #   ''
  #     Section "InputClass"
  #       Identifier "Custom TrackPoint Accel"
  #       MatchProduct "PS/2 Synaptics TouchPad"
  #       MatchDriver "libinput"

  #       Option "AccelProfile" "custom"

  #       # A piecewise-linear curve:
  #       # speed input → speed output
  #       Option "AccelCustomMotionPoints" "0.00 0.00, 0.10 0.20, 0.30 0.80, 0.50 1.60, 1.00 4.00"

  #       # Optional: make scrolling smoother too
  #       Option "AccelCustomScrollPoints" "0.00 0.00, 0.30 0.50, 1.00 2.00"
  #     EndSection
  #   ''
  # ];


  environment.systemPackages = with pkgs; [ libinput ];
}
