{ config, pkgs, ... }:

let pulse = pkgs.pulseaudioFull;
in {

  boot = {
    kernelModules = [];
  };

  hardware.pulseaudio = {
    enable = true;
    support32Bit = true;
    package = pulse;
    extraConfig = "load-module module-switch-on-connect";
  };

}
