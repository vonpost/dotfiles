#Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:
let
  bleeding = import <bleeding> {  };
  staging = import <staging> {  };
  # Should be pkgs.emacsGcc but tired of recompiling all the fucking time.
  myEmacs = pkgs.emacs;
in
{
  imports =
    [ # Include the results of the hardware scan.
      <nixos-hardware/lenovo/thinkpad/t14/amd/gen1>
      /etc/nixos/hardware-configuration.nix
      ./power_management.nix
      ./audio.nix
      ./wg/wg_client.nix
      ./picom.nix
  ];
  services.fwupd.enable = true;

  virtualisation.docker.enable = true;

  # periodic GC
  nix.gc.automatic = true;
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 30d";
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
    qutebrowser

    # GAMING
    discord
    moonlight-qt
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
    ghc
    gcc
    git
    #idris
    direnv
    nix-direnv

    #ACCESSORIES
    alacritty
    imagemagick
    (pkgs.writeShellScriptBin "alacrittyc" ''
      # Try to create a window via IPC; if daemon isn't up, start it, then try again.
      ${pkgs.alacritty}/bin/alacritty msg --socket "$XDG_RUNTIME_DIR/alacritty.sock" create-window "$@"
    '')

    htop
    jellyfin-media-player
    brightnessctl
    # qbittorrent
    wpa_supplicant_gui
 #  rofi-pass
 #  pass
    gnupg
    rxvt-unicode-unwrapped
    screenfetch
    wget
    rofi
    xclip
    maim
    pywal16
  # ranger
    libnotify
    dunst
    pamixer
    feh
    piper
    libinput
    
    #POWER MANAGEMENT
    acpi
    # haskell
    # haskellPackages.categories
    # haskellPackages.accelerate
    # haskellPackages.accelerate-llvm-native
    # XMONAD stuff
    # haskellPackages.Agda
    haskellPackages.xmonad-contrib
    haskellPackages.xmonad-extras
    haskellPackages.xmonad

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

  # Hide cursor when idle.
  services.unclutter-xfixes.enable = true;
  # Enable ratbagd for configuring mouse
  services.ratbagd.enable = true;
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  networking = {
    hostName = "TERRA";
    useDHCP = false;
    useNetworkd = true;
    interfaces = {
      enp5s0.useDHCP = true;
      wlp3s0.useDHCP = true;
      enp7s0f3u2c4i2.useDHCP = true;
    };
    wireless.enable = true;
    firewall.enable = false;
    nameservers = ["1.1.1.1" "8.8.8.8"];
  };

  # Enable X11
  services.libinput.enable = true;
  services.displayManager = {
    defaultSession = "none+xmonad";
    autoLogin.enable = true;
    autoLogin.user = "dcol";
  };
  services.xserver = {
    enable = true;
    xkb = {
      layout = "us";
      options = "eurosign:e";
    };
    videoDrivers = [ "amdgpu" ];
    # WINDOW MANAGER
    windowManager = {
      xmonad = {
        enable = true;
        enableContribAndExtras = true;
        extraPackages = haskellPackages: [
          haskellPackages.xmonad-contrib
	        haskellPackages.xmonad-extras
	        haskellPackages.xmonad
	      ];
      };
    };


    # DISPLAY MANAGER
    displayManager.sessionCommands =
        # Set background image with feh
        ''
        wal -i ~/wallpapers/clockwork.jpg
        wal -Rqe
        '' +
        # Trackpoint settings
        ''
        xinput set-prop "TPPS/2 Elan TrackPoint" "libinput Accel Speed" 1
        xinput set-prop "TPPS/2 Elan TrackPoint" "libinput Accel Profile Enabled" 0, 1
        xsetroot -cursor_name  left_ptr
        '';
    desktopManager.xterm.enable = false;
  };
  fonts.packages = with pkgs; [
    tewi-font
  ];

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
      extraPackages = with pkgs; [
        amdvlk
      ];

      extraPackages32 = with pkgs; [
        driversi686Linux.amdvlk
      ];
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
  systemd.services.networkd-wait-online.enable = false;
  # Build nixos configs remotely for speed
	nix.buildMachines = [ {
	 hostName = "mother.lan";
	 system = "x86_64-linux";
	 maxJobs = 10;
	}];
	nix.distributedBuilds = true;
  fileSystems."/theta" = {
    device = "mother.lan:/theta";
    fsType = "nfs";
    options = [ "x-systemd.automount" "noauto" "x-systemd.idle-timeout=600" ];
  };

}
