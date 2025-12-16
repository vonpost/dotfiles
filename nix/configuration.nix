#Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, bleeding, ... }:
let
  # Should be pkgs.emacsGcc but tired of recompiling all the fucking time.
  myEmacs =   ((pkgs.emacsPackagesFor pkgs.emacs-gtk).emacsWithPackages (epkgs: [
    epkgs.vterm
  ]));
  myRofi =  pkgs.rofi.override { plugins = [ pkgs.rofi-bluetooth pkgs.rofi-rbw]; };
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./power_management.nix
      ./audio.nix
      ./wg/wg_client_systemd.nix
      ./picom.nix
      ./xserver.nix
      ./t14-trackpoint.nix
      #./wayland.nix
  ];
  services.fwupd.enable = true;

  virtualisation.docker.enable = true;

  # periodic GC
  nix.gc.automatic = true;
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 30d";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "23.11";

  # Use the GRUB 2 boot loader.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = ["ntfs"];
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call config.boot.kernelPackages.tp_smapi ];
  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;
  #
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };
  services.lorri.enable = true;

  # Shell aliases
  environment.shellAliases = {
    ssh = "TERM=xterm ssh";
    em = "emacsclient -c";
    emt = "emacsclient -nw";
  };
  environment.variables.TERM = "linux";
  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  nixpkgs.config = {
    allowUnfree = true;
  };

  environment.systemPackages = with pkgs; [
    # BROWSER
    bleeding.qutebrowser

    #email
    # mu
    # isync


    # GAMING
    bleeding.discord
    bleeding.moonlight-qt
    #lutris
    #(wineWowPackages.staging.override { wineBuild = "wine64"; })

    # VIDEO 

    # AUDIO
    alsa-utils
    pulsemixer


    # MATH
   # texlive.combined.scheme-full
    # texlive.combined.scheme-full
    # (aspellWithDicts (dicts: with dicts; [ en en-computers en-science sv]))
   # aspellDicts.sv
    
    # PROGRAMMING
    vim
    python3Packages.python-lsp-server
    ghc
    gcc
    git
    #idris
    nix-direnv

    #bitwarden
    pinentry-all

    #ACCESSORIES
    ripgrep
    alacritty
    imagemagick
    (pkgs.writeShellScriptBin "alacrittyc" ''
      # Try to create a window via IPC; if daemon isn't up, start it, then try again.
      ${pkgs.alacritty}/bin/alacritty msg --socket "$XDG_RUNTIME_DIR/alacritty.sock" create-window "$@"
    '')

    htop
    # bleeding.jellyfin-media-player , relies on insecure qtwebengine
    acpi
    brightnessctl
    wpa_supplicant_gui
    gnupg
    rxvt-unicode-unwrapped
    screenfetch
    wget
    myRofi
    rofi-bluetooth
    rofi-rbw
    rbw
    xdotool
    xclip
    maim
    libnotify
    dunst
    pamixer
    feh
    piper
    libinput

    openrazer-daemon
  ];


    hardware.openrazer.enable = true;
     hardware.openrazer.users = ["dcol"];


  #urxvt stuff
  # daemon
  services.urxvtd.enable = true;


  # EMACS configuration stuff
  services.emacs.defaultEditor = true;
  services.emacs.enable = true;
  services.emacs.install = true;

  services.emacs.package = myEmacs;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/home/dcol/.ssh/id_ed25519" ];
    secrets = {
      "wg/TERRA" = {};
      "ssh/TERRA" = {};
      "mullvad" = {};
    };
  };

  services.mullvad-vpn = {
    enable = true;
    package = pkgs.mullvad-vpn;
  };

  programs.direnv.enable = true;
  programs.nix-ld.enable = true;


  # Hide cursor when idle.
  services.unclutter-xfixes.enable = true;
  # Enable ratbagd for configuring mouse
  services.ratbagd.enable = true;
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  # Use systemd-networkd + systemd-resolved
  systemd.network.enable = true;
  services.resolved = {
    enable = true;
    # Optional: use this as fallback for non-lan stuff if Mullvad isn't enforcing its own
    fallbackDns = [ "9.9.9.9" ];
  };

  networking = {
    hostName = "TERRA";
    useDHCP = false;
    useNetworkd = true;
    useHostResolvConf = false;
    interfaces = {
      enp5s0.useDHCP = true;
      wlp3s0.useDHCP = true;
      enp7s0f3u2c4i2.useDHCP = true;
    };
    wireless.enable = true;
    firewall.enable = false;
  };

  # Enable X11
  services.displayManager = {
    autoLogin.enable = true;
    autoLogin.user = "dcol";
  };


  fonts = {
    packages = with pkgs; [
      tewi-font
      nerd-fonts.blex-mono
      eb-garamond
    ];
    enableDefaultPackages = true;
  };


  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.extraUsers.dcol = {
    isNormalUser = true;
    createHome = true;
    home = "/home/dcol/";
    description = "Daniel Collin";
    extraGroups = ["video" "audio" "wheel" "libvirtd" "docker"];
    useDefaultShell = true;
  };

  # enable to allow ios connection for tethering
  services.usbmuxd.enable = true;
  security.sudo.enable = true;
  hardware = {
    trackpoint = {
      enable = true;
      speed = 255;
      sensitivity = 255;
      device = "TPPS/2 Elan TrackPoint";
    };
    cpu.amd.updateMicrocode = true;
    graphics = {
      enable = true;
    };
  };

  # services.printing.enable = true;
  # services.printing.drivers = [pkgs.gutenprint pkgs.gutenprintBin pkgs.hplipWithPlugin];
  # Map CAPS to ESC / CTRL
  # Remap Ctrl and CapsLock
 services.interception-tools = {
    enable = true;
    plugins = [ pkgs.interception-tools-plugins.caps2esc ];
    udevmonConfig = ''
    - JOB: "${pkgs.interception-tools}/bin/intercept -g $DEVNODE | ${pkgs.interception-tools-plugins.caps2esc}/bin/caps2esc | ${pkgs.interception-tools}/bin/uinput -d $DEVNODE"
      DEVICE:
        EVENTS:
          EV_KEY: [KEY_CAPSLOCK, KEY_ESC]
    '';
  };

  systemd.user.services.dunst = {
    enable = true;
    description = "dunst daemon";
    wantedBy = [ "default.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.dunst}/bin/dunst";
      Restart = "always";
    };
  };

  systemd.user.services.alacritty-daemon = {
    description = "Alacritty single-instance daemon";
    after = [ "graphical-session-pre.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];

    serviceConfig = {
      # Clean up stale socket before binding
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f %t/alacritty.sock";
      ExecStart = "${pkgs.alacritty}/bin/alacritty --daemon --socket %t/alacritty.sock";

      # Also remove on stop, just in case
      ExecStopPost = "${pkgs.coreutils}/bin/rm -f %t/alacritty.sock";

      # Be strict about shutdown so we actually hit ExecStopPost
      KillSignal = "SIGTERM";
      TimeoutStopSec = 5;

      Restart = "on-failure";
    };
  };



  swapDevices = [
    { device = "/dev/disk/by-label/swap"; }
  ];
  systemd.network.wait-online.anyInterface = true;
  # Build nixos configs remotely for speed
	# nix.buildMachines = [ {
	#  hostName = "root@192.168.1.11";
	#  system = "x86_64-linux";
	#  maxJobs = 10;
	# }];
    nix.buildMachines = [
    {
      hostName = "mother.lan";
      sshUser = "root";
      # 'ssh-ng' is faster if both machines are NixOS but falls flat if the
      # machine Nix will attempt a connection to is not NixOS. In such a case
      # you must use 'ssh' instead.
      protocol = "ssh-ng";

      # This can be an absolute path to a private key or it can be managed
      # with something like Agenix, or SOPS.
      sshKey = "/home/dcol/.ssh/id_rsa";

      # Systems for which builds will be offloaded.
      systems = ["x86_64-linux" ];

      # Default is 1 but may keep the builder idle in between builds
      maxJobs = 10;
      # How fast is the builder compared to your local machine
      speedFactor = 10;

      supportedFeatures = ["big-parallel" "kvm" "nixos-test"];
    }
  ];

	nix.distributedBuilds = true;
  fileSystems."/theta" = {
    device = "mother.lan:/theta";
    fsType = "nfs";
    options = [
      "x-systemd.requires=wg-quick-wg0.service"
      "x-systemd.after=wg-quick-wg0.service"
      "x-systemd.automount"
      "noauto"
      "_netdev"
      "x-systemd.idle-timeout=300"
      "nofail" ];
  };

}
