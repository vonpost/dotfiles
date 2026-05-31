{ config, lib, pkgs, ... }:

{
  boot = {

  # Enable hypervisor
  kernelModules = [ "kvm-amd" ];
  };
  virtualisation = {
    libvirtd = {
             enable = true;
    };
  };
}
