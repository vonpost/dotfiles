{ config, pkgs, ... }:

let pulse = pkgs.pulseaudioFull;
in {

  boot = {
    kernelModules = ["snd-seq" "snd-rawmidi"];
  };

  hardware.pulseaudio = {
    enable = true;
    support32Bit = true;
    package = pulse;
  };

  environment.systemPackages = with pkgs; [ 
   jack2Full
   supercollider
   haskellPackages.tidal
  ];


}
