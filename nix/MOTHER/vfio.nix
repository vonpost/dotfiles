let
  # GTX 4070
  gpuIDs = [
    "10de:2705" # GPU
    "10de:22bb" # AUDIO
  ];
in { pkgs, lib, config, ... }: {
  options.vfio = with lib;
    {
      enable = mkEnableOption "Configure the machine for VFIO";

      gpuIDs = {
        default = [];
        type = types.listOf types.str;
      };
    };

  config = let cfg = config.vfio;
  in {
    boot = {

      initrd.kernelModules = [
        "vfio_pci"
        "vfio"
        "vfio_iommu_type1"
        #"vfio_virqfd"
        # "nvidia"
        # "nvidia_modeset"
        # "nvidia_uvm"
        # "nvidia_drm"
      ];

      blacklistedKernelModules = [ "nvidia" "nvidia_drm" "nvidia_modeset" "nvidia_uvm" "nvidiafb" "nouveau" ];

      kernelParams = [
        # disable efi buffer
        "video=efifb:off"
        # enable IOMMU
        "amd_iommu=on"
      ] ++ lib.optional cfg.enable
        # isolate the GPU
        ("vfio-pci.ids=" + lib.concatStringsSep "," gpuIDs);
    };
  };
}
