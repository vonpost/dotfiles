{ self, config, pkgs, lib, microvm, bleeding, wolf, ... }:
let
  hostname = "OKAMI";
  topology = config.my.infra.topology;
  sotoVm = topology.vms.SOTO;
  sotoPrimaryVlan = lib.head sotoVm.assignedVlans;
  sotoIp = "10.10.${toString topology.vlans.${sotoPrimaryVlan}.id}.${toString sotoVm.id}";
  wolfImagePackages = pkgs.callPackage ../../../wolf-nix/packages/images.nix { };
  # wolf-native = import ../../../common/wolf.nix {inherit pkgs config lib;};

in
{
  # systemd.services.wolf-dev.serviceConfig.ExecStart = "${wolf-native}/bin/wolf";
  services.wolf = {
    enable = true;
    podmanLoadImages = true;
    podmanImages = [
      wolfImagePackages.wolfKdeImage
    ];
    extraApps = [
      wolfImagePackages.wolfKdeApp
    ];
    wolfDen.enable = true;
    hostPulseAudio.anonymousSocket.enable = true;
  };

  imports = [
    (import ../../../common/vm-common.nix { hostname = hostname; })
  ];

  ## ─────────────────────────────────────────────
  ## microvm basics
  ## ─────────────────────────────────────────────

  microvm.vcpu = 12;
  microvm.mem  = 22000;

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
  ## Remote transcode target (okuri)
  ## ─────────────────────────────────────────────

  services.okuri-target = {
    enable = true;
    authorizedKeys = [
      "from=\"${sotoIp}\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzH2Gt2Xs7mNeSpqNCJy2lwT19XC3OiSBNWBHK6zrzF dcol@TERRA"
    ];
  };

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
