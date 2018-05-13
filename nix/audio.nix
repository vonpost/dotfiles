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
  };

  environment.systemPackages = with pkgs; [ 
  ];


}
