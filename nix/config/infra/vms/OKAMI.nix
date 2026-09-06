{ config, pkgs, lib, quadlet-nix, ... }:
let
  hostname = "OKAMI";
  wolfImagePackages = pkgs.callPackage ../../../wolf-nix/packages/images.nix { };
  # wolf-native = import ../../../common/wolf.nix {inherit pkgs config lib;};

in
{
  # systemd.services.wolf-dev.serviceConfig.ExecStart = "${wolf-native}/bin/wolf";
  services.wolf = {
    enable = true;
    podmanLoadImages = true;
    podmanImages = [
      # wolfKdeImage is an alias of the shared stub image (M3).
      wolfImagePackages.wolfStubImage
    ];
    extraApps = [
      wolfImagePackages.wolfKdeApp
      # Nix Steam closure on the stub, owning the WolfSteam runner name (the
      # 249 GB games profile). Cutover user-approved 2026-08-26 after a
      # verified stream on the WolfSteamNix validation profile.
      wolfImagePackages.wolfSteamApp
    ];
    # The upstream ghcr Steam app is superseded by wolfSteamApp, which takes
    # over its runner name (= profile dir); two apps must not share it.
    removeDefaultApps = [ "WolfSteam" ];
    wolfDen.enable = true;
    hostPulseAudio.anonymousSocket.enable = true;
  };

  imports = [
    quadlet-nix.nixosModules.quadlet
    ../../../wolf-nix/modules/wolf-service.nix
  ];

  ## ─────────────────────────────────────────────
  ## microvm basics
  ## ─────────────────────────────────────────────

  microvm.devices = [
    { bus = "pci"; path = "0000:09:00.0"; } # GPU
    { bus = "pci"; path = "0000:09:00.1"; } # HDMI audio
  ];

  # Mount the block volume where Podman stores container state.
  microvm.volumes = [
    {
      mountPoint = "/var/lib/containers";
      image = "/images/microvm/${hostname}-containers.img";
      size = 40 * 1024; # MiB
      fsType = "ext4";
      autoCreate = true;
    }
  ];

  ## ─────────────────────────────────────────────
  ## NVIDIA (guest owns GPU via VFIO)
  ## ─────────────────────────────────────────────

  nixpkgs.config.allowUnfree = true;

  # Wolf docs requirement: ensure KMS is enabled and modeset=1
  boot.kernelParams = [ "nvidia_drm.modeset=1" ];
  boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" "fuse" ];

  hardware.nvidia = {
    open = false; # required to be explicit on >= 560
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
  };
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;

  ## ─────────────────────────────────────────────
  ## Podman
  ## ─────────────────────────────────────────────

  virtualisation.podman.enable = true;
  virtualisation.podman.dockerSocket.enable = true;

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };
  services.xserver.videoDrivers = ["nvidia"];

  ## ─────────────────────────────────────────────
  ## Admin & debugging
  ## ─────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    pciutils
    vulkan-tools
    curl
    config.hardware.nvidia.package.bin
    iptables
    tcpdump
    jellyfin-ffmpeg
    #wolf-native
  ];
}
