{ config, lib, pkgs, bleeding, ... }:
let
  inherit (lib) getExe;
in
{
  #= Setup Niri

  services.displayManager = {
    defaultSession = "none+niri";
  };
  programs.niri = {
    enable = true;
    package = bleeding.niri;
  };
  environment.systemPackages = [
    bleeding.xwayland-satellite
  ];


  xdg.portal.extraPortals = with pkgs; [
    xdg-desktop-portal-gnome
    xdg-desktop-portal-gtk
  ];

}
