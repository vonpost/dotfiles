# Two-node integration test for the full okuri dispatch/fallback matrix.
# The "GPU" is simulated by a stub ffmpeg whose behaviour is toggled through
# flag files on the target (/tmp/gpu-dead, /tmp/nvenc-broken, /tmp/slow-mode).
{ pkgs, lib, ... }:

let
  inherit (import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs)
    snakeOilPrivateKey snakeOilPublicKey;

  targetStub = pkgs.symlinkJoin {
    name = "ffmpeg-target-stub";
    paths = [
      (pkgs.writeShellScriptBin "ffmpeg" ''
        echo "$@" >> /tmp/ffmpeg.argv
        case " $* " in
          (*" -version "*) echo "ffmpeg version 7.1-okuri-target-stub"; exit 0 ;;
        esac
        if [ -f /tmp/force-fail ]; then
          echo "Error muxing a packet: broken input" >&2
          exit 3
        fi
        if [ -f /tmp/nvenc-broken ]; then
          case "$*" in
            (*nvenc*|*cuda*)
              echo "OpenEncodeSessionEx failed: out of memory" >&2
              exit 1 ;;
          esac
        fi
        if [ -f /tmp/slow-mode ]; then
          exec ${pkgs.coreutils}/bin/sleep 600
        fi
        exit 0
      '')
      (pkgs.writeShellScriptBin "ffprobe" ''
        echo "probe $@" >> /tmp/ffmpeg.argv
        echo "{}"
      '')
    ];
  };

  localStub = pkgs.symlinkJoin {
    name = "ffmpeg-local-stub";
    paths = [
      (pkgs.writeShellScriptBin "ffmpeg" ''
        echo "$@" >> /tmp/local.argv
        case " $* " in
          (*" -version "*) echo "ffmpeg version 7.1-okuri-local-stub" ;;
        esac
      '')
      (pkgs.writeShellScriptBin "ffprobe" ''
        echo "probe $@" >> /tmp/local.argv
        echo "{}"
      '')
    ];
  };

  gpuArgs = "-hwaccel cuda -hwaccel_output_format cuda -i file:/tmp/in.mkv"
    + " -c:v h264_nvenc -preset p1 /tmp/out.m3u8";
in
{
  name = "okuri-integration";

  nodes = {
    target = { pkgs, ... }: {
      imports = [ ../nixos-modules/target.nix ];
      services.openssh.enable = true;
      networking.firewall.enable = false;
      services.okuri-target = {
        enable = true;
        ffmpegPackage = targetStub;
        authorizedKeys = [ snakeOilPublicKey ];
        gpuPreflight.command =
          [ "${pkgs.runtimeShell}" "-c" "! test -f /tmp/gpu-dead" ];
      };
    };

    controller = { pkgs, ... }: {
      imports = [ ../nixos-modules/controller.nix ];
      networking.firewall.enable = false;
      services.okuri = {
        enable = true;
        targetHost = "target";
        remoteUser = "jellyfin";
        sshKeyPath = "/etc/okuri-test/id_snakeoil";
        localFfmpegPackage = localStub;
        fallback.fastFailSeconds = 15;
      };
      # The module normally rides on the jellyfin service's user; the test
      # node has no Jellyfin, so provide the user the tmpfiles rules expect.
      users.users.jellyfin = {
        isSystemUser = true;
        group = "jellyfin";
      };
      users.groups.jellyfin = { };
      environment.etc."okuri-test/id_snakeoil" = {
        source = snakeOilPrivateKey;
        mode = "0600";
      };
    };
  };

  testScript = ''
    start_all()
    target.wait_for_unit("sshd.service")
    target.wait_for_unit("multi-user.target")
    controller.wait_for_unit("multi-user.target")

    ffmpeg = "${pkgs.okuri}/bin/ffmpeg"
    ffprobe = "${pkgs.okuri}/bin/ffprobe"
    okuri = "${pkgs.okuri}/bin/okuri"
    gpu_args = "${gpuArgs}"

    with subtest("healthy: dispatch lands remote with untouched argv"):
        controller.succeed(f"{ffmpeg} {gpu_args}")
        line = target.succeed("tail -1 /tmp/ffmpeg.argv")
        assert "h264_nvenc" in line and "cuda" in line, line
        controller.fail("test -f /tmp/local.argv")

    with subtest("okuri check reports healthy"):
        controller.succeed(f"{okuri} check")

    with subtest("dead GPU preflight routes to software on the target"):
        target.succeed("touch /tmp/gpu-dead")
        controller.succeed(f"{ffmpeg} {gpu_args}")
        line = target.succeed("tail -1 /tmp/ffmpeg.argv")
        assert "libx264" in line and "cuda" not in line, line
        target.succeed("rm /tmp/gpu-dead")

    with subtest("fast GPU failure retries in software on the target"):
        target.succeed("touch /tmp/nvenc-broken; rm -f /tmp/ffmpeg.argv")
        controller.succeed(f"{ffmpeg} {gpu_args}")
        lines = target.succeed("cat /tmp/ffmpeg.argv").strip().splitlines()
        assert len(lines) == 2, lines
        assert "h264_nvenc" in lines[0], lines
        assert "libx264" in lines[1] and "cuda" not in lines[1], lines
        target.succeed("journalctl -t okuri-target | grep -q FALLBACK")
        target.succeed("rm /tmp/nvenc-broken")

    with subtest("target down falls back to local software"):
        target.succeed("systemctl stop sshd.service")
        controller.succeed("rm -f /run/okuri/cm-*")
        controller.succeed(f"{ffmpeg} {gpu_args}")
        line = controller.succeed("tail -1 /tmp/local.argv")
        assert "libx264" in line and "cuda" not in line, line
        controller.succeed("journalctl -t okuri | grep -q FALLBACK")
        target.succeed("systemctl start sshd.service")

    with subtest("remote encode errors propagate, no local retry"):
        controller.succeed("rm -f /tmp/local.argv")
        target.succeed("touch /tmp/force-fail")
        # A non-GPU failure on the target must reach the caller unchanged
        # (exit 3) and must not trigger the local fallback.
        rc, _ = controller.execute(f"{ffmpeg} {gpu_args} < /dev/null")
        assert rc == 3, rc
        controller.fail("test -f /tmp/local.argv")
        target.succeed("rm /tmp/force-fail")

    with subtest("ffprobe round-trips"):
        out = controller.succeed(
            f"{ffprobe} -v quiet -print_format json -show_streams file:/tmp/in.mkv")
        assert "{}" in out, out

    with subtest("killed dispatch leaves no orphan process on the target"):
        target.succeed("touch /tmp/slow-mode")
        controller.succeed(
            f"systemd-run --unit=okuri-slow {ffmpeg} "
            "-i file:/tmp/in.mkv -c:v h264_nvenc /tmp/out2.m3u8")
        target.wait_until_succeeds("pgrep -f 'sleep 60[0]'")
        controller.succeed("systemctl kill --signal=SIGKILL okuri-slow.service")
        target.wait_until_fails("pgrep -f 'sleep 60[0]'")
        target.succeed("rm /tmp/slow-mode")
  '';
}
