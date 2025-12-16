{ config, pkgs, ... }:

let pulse = pkgs.pulseaudioFull;
in {

  boot = {
    kernelModules = [];
  };

 hardware.bluetooth.enable = true;
 services.blueman.enable = true;

# rtkit is optional but recommended
security.rtkit.enable = true;
services.pipewire = {
  enable = true;
  alsa.enable = true;
  alsa.support32Bit = true;
  pulse.enable = true;
  # If you want to use JACK applications, uncomment this
  #jack.enable = true;
};

}
