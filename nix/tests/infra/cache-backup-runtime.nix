# Exercise real Btrfs snapshot/send behavior, including conversion of an
# existing cache and the same pre-start check used by MOTHER's daily backup.
{ nixosConfigurations }:
{ pkgs, lib, ... }:
let
  host = nixosConfigurations.MOTHER.config;
  layout = import ../../lib/service-state-layout.nix { inherit lib; infra = host.my.infra; };
  cache = layout.cacheDirectory host.my.infra.services.jellyfin "transcodes";
  guard = host.system.build.checkServiceCacheSubvolumes;
  prepare = host.system.build.prepareServiceCacheSubvolumes;
  cacheRules = builtins.filter (rule: lib.hasInfix "${cache} " rule) host.systemd.tmpfiles.rules;
  tmpfiles = pkgs.writeText "transcode-cache.conf" (lib.concatStringsSep "\n" cacheRules);
in
{
  name = "infra-cache-backup-runtime";
  requiredFeatures.kvm = false;
  globalTimeout = 600;
  nodes.machine = {
    virtualisation.memorySize = 768;
    virtualisation.emptyDiskImages = [ 512 512 ];
    boot.supportedFilesystems = [ "btrfs" ];
    environment.systemPackages = [ pkgs.btrfs-progs ];
    users.users.btrbk = { isSystemUser = true; group = "btrbk"; };
    users.groups.btrbk = { };
    systemd.services.test-backup = {
      serviceConfig = {
        inherit (host.systemd.services.btrbk-daily_state.serviceConfig) ExecStartPre User Group;
        Type = "oneshot";
        StateDirectory = "test-backup";
      };
      script = "touch /var/lib/test-backup/started";
    };
  };
  testScript = ''
    cache = "${cache}"
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkfs.btrfs /dev/vdb; mkfs.btrfs /dev/vdc")
    machine.succeed("mkdir -p /pool /state /backup; mount /dev/vdb /pool; mount /dev/vdc /backup")
    machine.succeed("btrfs subvolume create /pool/@state; mount -o subvol=@state /dev/vdb /state")
    machine.succeed(f"mkdir -p {cache} /state/services/lib/jellyfin")
    machine.succeed(f"echo cached-segment > {cache}/segment.mp4; chmod 640 {cache}/segment.mp4; chown -R 2104:2104 {cache}")
    machine.succeed("echo database > /state/services/lib/jellyfin/library.db")
    machine.succeed("btrfs subvolume snapshot -r /state /pool/before")
    machine.succeed("set -o pipefail; btrfs send /pool/before | btrfs receive /backup")
    machine.succeed("test -f /backup/before/services/cache/jellyfin/transcodes/segment.mp4")

    # Provisioning must not silently convert a live ordinary directory.
    # The real systemd pre-start check prevents the backup as well.
    machine.succeed("systemd-tmpfiles --create ${tmpfiles}")
    machine.fail("${prepare}")
    machine.fail("${guard}")
    machine.fail("systemctl start test-backup")
    machine.fail("test -e /var/lib/test-backup/started")
    machine.succeed(f"test -f {cache}/segment.mp4")

    # The one-time maintenance procedure preserves cache data with reflinks.
    # On MOTHER both VM exporters and the backup timer must be stopped first.
    machine.succeed(f"btrfs subvolume create {cache}.new-subvolume")
    machine.succeed(f"cp -a --reflink=always {cache}/. {cache}.new-subvolume/")
    machine.succeed(f"sync -f {cache}.new-subvolume")
    machine.succeed(f"mv {cache} {cache}.before-subvolume; mv {cache}.new-subvolume {cache}")
    machine.fail("${guard}")  # Old files would still be part of @state.
    machine.succeed(f"cmp {cache}/segment.mp4 {cache}.before-subvolume/segment.mp4")
    assert machine.succeed(f"stat -c '%u:%g %a' {cache}/segment.mp4").strip() == "2104:2104 640"
    machine.succeed(f"rm -r {cache}.before-subvolume")
    machine.succeed("systemd-tmpfiles --create ${tmpfiles}")
    machine.succeed("${prepare}")
    machine.succeed("${guard}")
    machine.succeed("systemctl reset-failed test-backup; systemctl start test-backup")
    machine.succeed("test -f /var/lib/test-backup/started")

    # The cache stays usable, but neither full nor incremental backups carry
    # its contents. Database state and earlier backup contents are preserved.
    machine.succeed(f"echo another-segment > {cache}/next.mp4")
    machine.succeed("echo new-database >> /state/services/lib/jellyfin/library.db")
    machine.succeed("btrfs subvolume snapshot -r /state /pool/after")
    machine.succeed("test -z \"$(ls -A /pool/after/services/cache/jellyfin/transcodes)\"")
    machine.succeed("set -o pipefail; btrfs send -p /pool/before /pool/after | btrfs receive /backup")
    machine.fail("test -e /backup/after/services/cache/jellyfin/transcodes/segment.mp4")
    machine.fail("test -e /backup/after/services/cache/jellyfin/transcodes/next.mp4")
    machine.succeed("cmp /state/services/lib/jellyfin/library.db /backup/after/services/lib/jellyfin/library.db")
    machine.succeed("test -f /backup/before/services/cache/jellyfin/transcodes/segment.mp4")
    machine.succeed("mkdir /backup/full; btrfs send /pool/after | btrfs receive /backup/full")
    machine.fail("test -e /backup/full/after/services/cache/jellyfin/transcodes/segment.mp4")
    machine.succeed("cmp /state/services/lib/jellyfin/library.db /backup/full/after/services/lib/jellyfin/library.db")

    # A restore need not contain the empty nested stub. Provisioning creates
    # the cache again, with the correct ownership and a checked boundary.
    machine.succeed(f"mv {cache} /pool/saved-cache")
    machine.fail("${guard}")
    machine.succeed("systemd-tmpfiles --create ${tmpfiles}")
    machine.succeed("${prepare}")
    machine.succeed("${guard}")
    assert machine.succeed(f"stat -c '%u:%g %a' {cache}").strip() == "2104:2104 755"
    machine.succeed(f"test -z \"$(ls -A {cache})\"")
    machine.shutdown()
  '';
}
