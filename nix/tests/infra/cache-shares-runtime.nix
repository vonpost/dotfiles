# Use the real SOTO mount definitions in a disposable VM. Independent VirtioFS
# connections emulate the writer and reader caches without touching the fleet.
{ nixosConfigurations }:
{ pkgs, ... }:
let
  server = nixosConfigurations.SOTO.config;
  worker = nixosConfigurations.OKAMI.config;
  transcodes = "/var/cache/jellyfin/transcodes";
  serverShare = builtins.head (builtins.filter (s: s.mountPoint == transcodes) server.microvm.shares);
  workerShare = builtins.head (builtins.filter (s: s.mountPoint == transcodes) worker.microvm.shares);
  stateShare = builtins.head (builtins.filter (s: s.tag == "state") server.microvm.shares);
  exports = [
    { tag = "state"; subdir = "state"; inherit (stateShare) cache; }
    { tag = serverShare.tag; subdir = "state/cache/jellyfin/transcodes"; inherit (serverShare) cache; }
    { tag = "worker-transcodes"; subdir = "state/cache/jellyfin/transcodes"; inherit (workerShare) cache; }
    # Keep the control on a separate mount: a submount under the service bind
    # can propagate back to its /state alias in the same guest.
    { tag = "cached-control"; subdir = "state/cache/jellyfin/transcodes"; inherit (stateShare) cache; }
  ];
in
{
  name = "infra-cache-shares-runtime";
  # This can run locally under TCG when KVM isn't available.
  requiredFeatures.kvm = false;
  globalTimeout = 600;
  nodes.machine = {
    boot.kernelModules = [ "virtiofs" ];
    virtualisation.memorySize = 768;
    virtualisation.qemu.enableSharedMemory = true;
    virtualisation.qemu.options = map (export:
      "-chardev socket,id=${export.tag},path=$JELLYFIN_TEST_SHARE_DIR/${export.tag}.sock "
      + "-device vhost-user-fs-pci,chardev=${export.tag},tag=${export.tag}"
    ) exports;
    virtualisation.fileSystems = builtins.intersectAttrs {
      "/state" = null;
      "/var/lib/jellyfin" = null;
      "/var/cache/jellyfin" = null;
      ${transcodes} = null;
    } server.fileSystems // {
      "/worker-transcodes" = { device = "worker-transcodes"; fsType = "virtiofs"; };
      "/cached-control" = { device = "cached-control"; fsType = "virtiofs"; };
    };
    environment.systemPackages = [ pkgs.python3 ];
  };
  testScript = ''
    import json
    import os
    from pathlib import Path
    import subprocess
    import time

    root = Path(os.environ["TMPDIR"])
    os.environ["JELLYFIN_TEST_SHARE_DIR"] = str(root)
    (root / "state/lib/jellyfin").mkdir(parents=True)
    (root / "state/cache/jellyfin/transcodes").mkdir(parents=True)
    daemons = []
    logs = []
    try:
        for export in json.loads('${builtins.toJSON exports}'):
            log = (root / (export["tag"] + ".log")).open("w")
            logs.append(log)
            socket = root / (export["tag"] + ".sock")
            # The disposable guest has no access to real host state. Map its
            # users to the test runner so this also runs as an ordinary user.
            process = subprocess.Popen([
                "${pkgs.virtiofsd}/bin/virtiofsd",
                "--socket-path=" + str(socket),
                "--shared-dir=" + str(root / export["subdir"]),
                "--cache=" + export["cache"],
                "--sandbox=none", "--seccomp=none",
                "--translate-uid=squash-guest:0:" + str(os.getuid()) + ":4294967295",
                "--translate-gid=squash-guest:0:" + str(os.getgid()) + ":4294967295",
            ], stdout=log, stderr=log)
            daemons.append(process)
            deadline = time.monotonic() + 10
            while not socket.exists():
                assert process.poll() is None, (root / (export["tag"] + ".log")).read_text()
                assert time.monotonic() < deadline, "virtiofsd socket timeout"
                time.sleep(0.05)
        machine.start()
        machine.wait_for_unit("multi-user.target")
        for mount in ["/state", "/var/lib/jellyfin", "/var/cache/jellyfin/transcodes", "/worker-transcodes", "/cached-control"]:
            print(machine.succeed("findmnt -M " + mount))
        machine.succeed("python3 ${./cache-coherence.py} ${pkgs.jellyfin-ffmpeg}/bin/ffmpeg", timeout=180)
        machine.shutdown()
    finally:
        for process in daemons:
            process.terminate()
        for process in daemons:
            process.wait(timeout=10)
        for log in logs:
            log.close()
  '';
}
