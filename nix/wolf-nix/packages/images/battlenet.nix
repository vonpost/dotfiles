{ pkgs, lib, imageTag, basePath, mkWolfSessionAnchorService
, sessionUserDirsPreStart, mkWolfDesktopServiceConfig, swaySessionConfig }:

let
  # Official binaries: do not autoPatchelf them against host Nix libraries.
  # GE runs in the Steam Linux Runtime supplied by UMU. Update explicitly.
  protonVersion = "GE-Proton11-12";
  protonArchive = pkgs.fetchurl {
    url = "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${protonVersion}/${protonVersion}-x86_64.tar.gz";
    hash = "sha256-BZUVnkF8Pbv7fMOuDT7RWmF8xgeqI+91bqeQKdevXXA=";
  };
  # This only unpacks binaries. Keep it local rather than sending the archive
  # to a remote compiler and copying the much larger extracted tree back.
  proton = pkgs.runCommandLocal protonVersion { nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ]; } ''
    mkdir -p "$out"
    tar -xzf ${protonArchive} --strip-components=1 -C "$out"
    test -x "$out/proton"
  '';
  # Keep UMU current without moving the fleet's nixpkgs pin. Hashes match the
  # maintained nixpkgs package for 1.4.4; retain its FHS wrapper and checks.
  umuUnwrapped = pkgs.umu-launcher-unwrapped.overrideAttrs (_: rec {
    version = "1.4.4";
    src = pkgs.fetchFromGitHub {
      owner = "Open-Wine-Components";
      repo = "umu-launcher";
      tag = version;
      hash = "sha256-0KJtJd0tY8ewoaUIJ+1cIDlr7eRTWLGTpkkNMn60JIY=";
    };
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      hash = "sha256-f9Me1dCS5GxXN4mADS6Z20M7YnX5ck3JXOXUFhM+h5o=";
    };
  });
  umu = pkgs.umu-launcher.override { umu-launcher-unwrapped = umuUnwrapped; };
  wowup = pkgs.callPackage ./wowup-cf.nix { };
  launcher = pkgs.writeShellApplication {
    name = "wolf-battlenet";
    # Checking this tiny script should not ship the whole Proton closure to
    # the remote builder either.
    derivationArgs.preferLocalBuild = true;
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.util-linux pkgs.python3 umu ];
    text = ''
      export WOLF_BATTLENET_PROTON=${proton}
      export WOLF_BATTLENET_DEFAULTS=${./battlenet-defaults.py}
    '' + builtins.readFile ./battlenet-launcher.sh;
  };
  wowupLauncher = pkgs.writeShellApplication {
    name = "wolf-wowup";
    derivationArgs.preferLocalBuild = true;
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux pkgs.python3 pkgs.zenity wowup ];
    text = ''
      export WOLF_WOWUP_SETTINGS=${./wowup-settings.py}
    '' + builtins.readFile ./wowup-launcher.sh;
  };
  sessionApp = pkgs.writeShellApplication {
    name = "wolf-battlenet-session-app";
    derivationArgs.preferLocalBuild = true;
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux pkgs.zenity pkgs.sway launcher ];
    text = builtins.readFile ./battlenet-session.sh;
  };
  system = import "${pkgs.path}/nixos" {
    system = pkgs.system;
    configuration = { lib, ... }: {
      boot.isContainer = true;
      networking.hostName = "wolf-battlenet";
      networking.useDHCP = false;
      system.stateVersion = "25.05";
      documentation.enable = false;
      documentation.man.enable = false;
      users.allowNoPasswordLogin = true;
      users.mutableUsers = false;
      users.groups.retro.gid = 1000;
      users.groups.video = { };
      users.groups.render = { };
      users.groups.input = { };
      users.groups.audio = { };
      users.users.root.initialHashedPassword = "!";
      users.users.retro = {
        isNormalUser = true;
        uid = 1000;
        group = "retro";
        extraGroups = [ "video" "render" "input" "audio" ];
        home = "/home/retro";
        createHome = true;
        linger = true;
        initialHashedPassword = "!";
      };
      services.dbus.enable = true;
      services.dbus.implementation = lib.mkForce "dbus";
      security.rtkit.enable = true;
      fonts.packages = [ pkgs.liberation_ttf pkgs.noto-fonts ];
      # Same container activation constraint as the existing Steam closure.
      system.activationScripts.binsh = lib.mkForce "";
      systemd.tmpfiles.rules = [ "d /run/gow-graphics 0755 retro retro -" ];
      security.pam.services.wolf-session-anchor.startSession = true;
      security.pam.services.wolf-battlenet-session.startSession = true;
      systemd.services.wolf-session-anchor = mkWolfSessionAnchorService "wolf-battlenet-session.service";
      systemd.services.wolf-battlenet-session = {
        description = "Wolf Battle.net / WoW session";
        wantedBy = [ "multi-user.target" ];
        after = [ "dbus.service" "systemd-user-sessions.service" "user@1000.service" "wolf-session-anchor.service" ];
        wants = [ "dbus.service" "user@1000.service" "wolf-session-anchor.service" ];
        path = with pkgs; [ coreutils dbus gawk gnugrep systemd wlr-randr sway ];
        preStart = sessionUserDirsPreStart;
        script = ''
          set -euo pipefail
          source /opt/gow/bash-lib/desktop-compat.sh
          export HOME=/home/retro
          export XDG_RUNTIME_DIR=/run/user/1000
          export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
          export XDG_SESSION_TYPE=wayland
          export XDG_SESSION_CLASS=user
          export XDG_SEAT=seat0
          export XDG_CURRENT_DESKTOP=sway
          export XDG_SESSION_DESKTOP=sway
          export GOW_GRAPHICS_RUNTIME_DIR=/run/gow-graphics
          export GOW_NVIDIA_PREFIX=/run/nvidia-driver
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

          gow_apply_common_ui_scale_defaults
          gow_apply_common_xdg_defaults
          gow_apply_graphics_runtime_env
          gow_export_wolf_wayland_env /run/wolf 80 0.1
          gow_export_pulse_server_from_wolf
          gow_require_session_bus /run/user/1000/bus 200 0.1
          gow_export_logind_session_id 1000 retro seat0

          cfg_dir="$(mktemp -d /tmp/battlenet-sway.XXXXXX)"
          trap 'rm -rf "$cfg_dir"' EXIT
          cat > "$cfg_dir/config" <<EOF
          default_border none
          output * resolution ''${GAMESCOPE_WIDTH:-1920}x''${GAMESCOPE_HEIGHT:-1080} position 0,0
          # Start Xwayland while UMU prepares Proton, before Wine needs X11.
          xwayland force
          workspace game
          for_window [class="(?i)battle.net.*"] floating enable
          assign [class="(?i)wowup.*"] workspace addons
          include ${swaySessionConfig}
          # Leave Super to the client's XMonad and Ctrl+Alt+Shift to Moonlight.
          bindsym Ctrl+Shift+6 exec ${lib.getExe wowupLauncher}
          bindsym Ctrl+Shift+8 [class="(?i)wowup.*"] kill
          bindsym Ctrl+Shift+9 exec ${pkgs.sway}/bin/swaymsg exit
          exec ${lib.getExe sessionApp}
          EOF
          sway --unsupported-gpu -c "$cfg_dir/config"
        '';
        serviceConfig = mkWolfDesktopServiceConfig "wolf-battlenet-session" // {
          Restart = "no";
          # End the container when the user quits instead of restarting the app.
          ExecStopPost = "+${pkgs.systemd}/bin/systemctl --no-block poweroff";
        };
      };
      environment.systemPackages = [ pkgs.dbus pkgs.systemd pkgs.sway pkgs.xwayland launcher wowupLauncher ];
    };
  };
in
{
  wolfBattleNetSystem = system.config.system.build.toplevel;
  wolfBattleNetLauncher = launcher;
  wolfBattleNetSession = sessionApp;
  wolfWowUpLauncher = wowupLauncher;
  wolfBattleNetProton = proton;
  wolfBattleNetApp = {
    title = "Battle.net / WoW";
    icon_png_path = "https://lutris.net/games/icon/battlenet.png";
    runner = {
      type = "docker";
      name = "WolfBattleNet";
      image = "localhost/wolf/stub:${imageTag}";
      mounts = [
        "/nix/store:/nix/store:ro"
        "/nix/var/nix/db:/nix/var/nix/db:ro"
        "/sys/fs/cgroup:/sys/fs/cgroup:rw"
        "/var/lib/wolf/nvidia-driver:/run/nvidia-driver:ro"
      ];
      env = [
        "UNAME=root"
        "PATH=${basePath}:/run/current-system/sw/bin:/run/current-system/sw/sbin"
        "GOW_NIXOS_SYSTEM=${system.config.system.build.toplevel}"
        "GOW_GRAPHICS_RUNTIME_DIR=/run/gow-graphics"
        "GOW_NVIDIA_PREFIX=/run/nvidia-driver"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      # Match the existing NixOS-on-stub runner, including nested bwrap support.
      base_create_json = builtins.toJSON {
        StopSignal = "RTMIN+3";
        HostConfig = {
          IpcMode = "host";
          Privileged = false;
          CgroupnsMode = "host";
          CapAdd = [ "NET_RAW" "MKNOD" "NET_ADMIN" "SYS_ADMIN" "SYS_NICE" "SYS_PTRACE" ];
          SecurityOpt = [ "label=disable" "apparmor=unconfined" "seccomp=unconfined" ];
          Devices = [
            { PathOnHost = "/dev/fuse"; PathInContainer = "/dev/fuse"; CgroupPermissions = "rwm"; }
            { PathOnHost = "/dev/dri"; PathInContainer = "/dev/dri"; CgroupPermissions = "rwm"; }
          ];
          Ulimits = [ { Name = "nofile"; Soft = 10240; Hard = 524288; } ];
          DeviceCgroupRules = [ "c 10:229 rmw" "c 13:* rmw" "c 226:* rmw" "c 244:* rmw" ];
          Tmpfs = {
            "/run" = "rw,nosuid,nodev,size=64m,mode=755";
            "/run/lock" = "rw,nosuid,nodev,size=16m,mode=755";
            "/tmp" = "rw,nosuid,nodev,size=1024m,mode=1777";
          };
        };
      };
    };
  };
}
