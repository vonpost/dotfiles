{ config, lib, pkgs, ... }:

{
  fileSystems = {

  "/boot" = {
    device = "/dev/disk/by-label/boot";
  };
  "/omega" = {
    device = "/dev/disk/by-label/omega";
  };

  "/mnt/btr_pool" = {
    device = "/dev/disk/by-label/vm";
    fsType = "btrfs";
    # No "subvol" option means mount the root (ID 5)
    options = [ "compress=zstd:1" "noatime" ];
  };

  "/state" = {
    device = "/dev/disk/by-label/vm";
    fsType = "btrfs";
    options = [ "subvol=@state" "compress=zstd:1" "noatime" "space_cache=v2" ];
  };

  "/images" = {
    device = "/dev/disk/by-label/vm";
    fsType = "btrfs";
    # Even though we mount with compress=zstd, the directory attribute (+C)
    # overrides it, ensuring raw performance for VM images.
    options = [ "subvol=@images" "compress=zstd:1" "noatime" "space_cache=v2" ];
  };

  "/backups" = {
      device = "/dev/disk/by-label/backups";
      fsType = "btrfs";
      options = [ "compress=zstd:9" "noatime" ]; # High compression for archival
    };
  };
  # --- Ensure Permissions are Correct on Boot ---
  systemd.tmpfiles.rules = [
    "h /state/services/lib - - - - +C"
    "h /images - - - - +C"
  ];
  services.btrbk = {
    instances."daily_state" = {
      onCalendar = "daily";
      settings = {
        snapshot_create = "onchange";
        snapshot_preserve_min = "2d";
        snapshot_preserve     = "2d";
        target_preserve_min   = "no";
        target_preserve       = "14d 10w 6m"; # Long history for state

        volume."/mnt/btr_pool" = {
          # Create snapshots in /mnt/btr_pool/.snapshots
          snapshot_dir = ".snapshots";
          target."/backups/vm/state" = {};

          # Only backup the state subvolume here
          subvolume."@state" = {};
        };
      };
    };

    instances."weekly_images" = {
      onCalendar = "weekly"; # Only runs once a week!
      settings = {
        snapshot_preserve_min = "1w";
        snapshot_preserve     = "2w"; # Keep 2 weeks of local snapshots
        target_preserve_min   = "no";
        target_preserve       = "4w 6m"; # Keep 6 months on backup

        volume."/mnt/btr_pool" = {
          snapshot_dir = ".snapshots";
          target."/backups/vm/images" = {};

          # Only backup the images subvolume here
          subvolume."@images" = {};
        };
      };
    };
  };

  # 3. Enable Maintenance (Crucial for Btrfs health)
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/state" "/backups" "/images"];
  };
}
