 Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:
let
  bleeding = import <bleeding> {  };
  staging = import <staging> {  };
  community = import (builtins.fetchTarball {
      url = https://github.com/nix-community/emacs-overlay/archive/master.tar.gz;
    });
  overlays = import ./overlays/overlay1.nix;
  myEmacs = pkgs.emacsGcc;
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./audio.nix
      ./cachix.nix
    ];
  services.fwupd.enable = true;

  nixpkgs.overlays = [ overlays community ];
  # periodic GC
  nix.gc.automatic = true;
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 30d";

  # Use the GRUB 2 boot loader.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call config.boot.kernelPackages.tp_smapi ];
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
    parsec
    discord
    #(wineWowPackages.staging.override { wineBuild = "wine64"; })

    # VIDEO 

    # AUDIO
    alsaUtils
    pulsemixer


    # MATH
   # texlive.combined.scheme-full
    texlive.combined.scheme-full
    (aspellWithDicts (dicts: with dicts; [ en en-computers en-science sv]))
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
    brightnessctl
    # qbittorrent
    wpa_supplicant_gui
 #  rofi-pass
 #  pass
    gnupg
    rxvt_unicode
    screenfetch
    wget
    rofi
    xclip
    maim
    pywal
  # ranger
    libnotify
    dunst
    pamixer
    feh
    piper
    libinput
    
    #POWER MANAGEMENT
    powertop
    tlp
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
  ];

  
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
    };
    wireless.enable = true;
    firewall.enable = false;
  };

  # Enable X11
  services.xserver = {
    enable = true;
    libinput.enable = true;
    layout = "us";
    xkbOptions = "eurosign:e";

    videoDrivers = [ "amdgpu" ];
    # WINDOW MANAGER
    displayManager.defaultSession = "none+xmonad";
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
    wal -i ~/wallpapers/tennis.jpg
    '' +
    # Trackpoint settings
    ''
    xinput set-prop "TPPS/2 Elan TrackPoint" "libinput Accel Speed" 1
    xinput set-prop "TPPS/2 Elan TrackPoint" "libinput Accel Profile Enabled" 0, 1
    xsetroot -cursor_name  left_ptr
    '';
    displayManager = {
      autoLogin.enable = true;
      autoLogin.user = "dcol";
    };
    desktopManager.xterm.enable = false;
  };

  fonts.fonts = with pkgs; [
    tewi-font
  ];
  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.extraUsers.dcol = {
    isNormalUser = true;
    createHome = true;
    home = "/home/dcol/";
    description = "Daniel Collin";
    extraGroups = ["video" "audio" "wheel" "libvirtd"];
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
    opengl = {
      enable = true;
      driSupport = true;
      driSupport32Bit = true;
    };
  };
hardware.opengl.extraPackages = with pkgs; [
  amdvlk
];
# For 32 bit applications
# Only available on unstable

hardware.opengl.extraPackages32 = with pkgs; [
 driversi686Linux.amdvlk
];
  services.printing.enable = true;
  services.printing.drivers = [pkgs.gutenprint pkgs.gutenprintBin pkgs.hplipWithPlugin];
  
  # Power management
  powerManagement.enable = true;
  #services.tlp.enable = true;
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
 systemd = {
#    # wait-online keeps getting stuck, so disable it.
   services.systemd-networkd-wait-online.enable = false;
 };
 nix.nixPath = ["nixpkgs=/nix/var/nix/profiles/per-user/dcol/channels/nixos"
                "nixos-config=/etc/nixos/configuration.nix"
                "bleeding=/nix/var/nix/profiles/per-user/dcol/channels/bleeding"
                "staging=/nix/var/nix/profiles/per-user/dcol/channels/staging"];
  systemd.user.services.dunst = {
    enable = true;
    description = "dunst daemon";
    wantedBy = [ "default.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.dunst}/bin/dunst";
      Restart = "always";
    };
  };
  swapDevices = [
    { device = "/dev/disk/by-label/swap"; }
  ];
  # Build nixos configs remotely for speed
	# nix.buildMachines = [ {
	#  hostName = "192.168.1.11";
	#  system = "x86_64-linux";
	#  maxJobs = 10;
	# }];
	# nix.distributedBuilds = true;
  # fileSystems."/theta" = {
  #   device = "192.168.1.11:/theta";
  #   fsType = "nfs";
  # };
}
