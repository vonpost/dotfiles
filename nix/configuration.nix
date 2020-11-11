# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:
let
  myEmacs = pkgs.emacs.override {
    withGTK3 = false;
    withGTK2 = false;
  };
  emacsWithPackages = (pkgs.emacsPackagesNgGen myEmacs).emacsWithPackages;
  overlays = import /home/dcol/dotfiles/nix/overlays/overlay1.nix;
  hibernation = ''
battery0=`cat /sys/class/power_supply/BAT0/capacity`
battery1=`cat /sys/class/power_supply/BAT1/capacity`
status=`cat /sys/class/power_supply/BAT0/status`
if [[ "$battery0" -le 5 && "$battery1" -le 5  && "$status" == Discharging ]]
then
    ${pkgs.libnotify}/bin/notify-send -t 10000 "Battery low, going into hibernation!"
    sleep 10
    ${pkgs.systemd}/bin/systemctl hybrid-sleep
fi
  '';

in 
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./audio.nix
    ];
    # Add overlays to path

  # periodic GC
  nixpkgs.overlays = [ overlays ]; 
  nix.gc.automatic = true;
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 30d";
  # nix options for derivations to persist garbage collection
  nix.extraOptions = ''
    keep-outputs = true
    keep-derivations = true
  '';
  # Use the GRUB 2 boot loader.
  boot.kernelPackages = pkgs.linuxPackages_latest;       
  # boot.kernel.sysctl."net.ipv6.conf.eth0.disable_ipv6" = true;
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.extraConfig = ''
  GRUB_CMDLINE_LINUX_DEFAULT="quiet splash psmouse.synaptics_intertouch=0"
  '';

  boot.loader.grub.device = "/dev/sda"; # or "nodev" for efi only
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call config.boot.kernelPackages.tp_smapi ];
  #networking.enableIPv6 = false;
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };
  # Shell aliases
  environment.shellAliases = {
    ssh = "TERM=xterm ssh";
    em = "emacsclient -c";
    emt = "emacsclient -nw";
    editnix = "em ~/dotfiles/nix/configuration.nix";
    updatenix = "sh ~/dotfiles/nix/updateConfig.sh";
    updatenixlocal = "sh ~/dotfiles/nix/updateConfigLocalNixpkgs.sh";
  };
  environment.variables.TERM = "linux";
  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  # New video driver for xorg "modesetting" doesn't work with xbacklight, so we use brightnessctl instead
  nixpkgs.config = {
		allowUnfree = true;
  };
  environment.systemPackages = with pkgs; [
    # BROWSER
    qutebrowser

    # GAMING
    parsec
    discord
    # wineWowPackages.staging

    # VIDEO 
    vaapiIntel
    libva-utils
    libva-full
    vaapi-intel-hybrid
    ffmpeg
    mpv

    # AUDIO
    alsaUtils
    pulsemixer


    # MATH
    texlive.combined.scheme-full
    aspell
    aspellDicts.en
    aspellDicts.en-computers
    aspellDicts.en-science
    aspellDicts.sv
    
    # PROGRAMMING
    vim
    ghc
    gcc
    git
    #idris
    direnv

    #ACCESSORIES
    brightnessctl
    # qbittorrent
    wpa_supplicant_gui
    rofi-pass
    pass
    gnupg
    rxvt_unicode
    screenfetch
    wget
    rofi
    xclip
    maim
    ranger
    libnotify
    dunst
    pamixer
    feh
    piper
    
    #POWER MANAGEMENT
    powertop
    tlp
    acpi
    # haskell
    # haskellPackages.categories
    # haskellPackages.accelerate
    # haskellPackages.accelerate-llvm-native
    # XMONAD stuff
    haskellPackages.Agda
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
   
  # zerotier
  services.zerotierone.enable = true;

  services.emacs.package = with pkgs; (emacsWithPackages (with emacsPackagesNg; [
    # graphviz-dot-mode
    # idris-mode
    # csharp-mode
    # auctex
    # agda2-mode
    # rainbow-mode
    # rainbow-delimiters
    # evil-collection
    # visual-regexp-steroids
    # flycheck
    # haskell-mode
    # highlight-parentheses
    # magit
    # dante
    # nix-buffer
    # company
    # company-math
    # projectile
    # nix-mode
    # pdf-tools
    # ranger
    # ivy
    # swiper
    # counsel
    # ivy-pass
    # evil
    # frames-only-mode
    # latex-preview-pane
    # which-key
    # rust-mode
  ]));

  # Hide cursor when idle.
  services.unclutter-xfixes.enable = true;
  # Enable ratbagd for configuring mouse
  services.ratbagd.enable = true;
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  networking = {
    hostName = "LAIN";
    useDHCP = false;
    useNetworkd = true;
    interfaces = {
      enp0s25.useDHCP = true;
      wlp3s0.useDHCP = true;
    };
    wireless.enable = true;
    firewall.enable = false;
  };

  # Enable X11
  services.xserver = {
    enable = true;
    layout = "us";
    xkbOptions = "eurosign:e";


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

    # ENABLE TOUCHPAD
    libinput.enable = true;
    libinput.accelProfile = "flat";
    #horizontal scroll sucks on bad touchpad
    libinput.horizontalScrolling = false;
    # DISPLAY MANAGER
    displayManager.sessionCommands =
    # Set background image with feh

    ''
    wal -i ~/wallpapers/tennis.jpg
    '' +
    # Start emacs daemon, for some reason doesnt do naturally
    ''
    emacs --daemon &
    '' +   
    # Disable Trackpad
    ''
    xinput --disable "Synaptics TM3053-004"
    ''+ 
    # Trackpoint settings
    ''
    xinput set-prop "TPPS/2 IBM TrackPoint" "libinput Accel Speed" 1
    xinput set-prop "TPPS/2 IBM TrackPoint" "libinput Accel Profile Enabled" 0, 1
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
    
    extraGroups = ["video" "audio" "wheel" ];
    useDefaultShell = true;
  };

  # enable to allow ios connection for tethering
  services.usbmuxd.enable = true;
  security.sudo.enable = true;
  hardware = {
    trackpoint = {
      enable = true;
      speed = 225;
      sensitivity = 184;
    };
    opengl = {
      enable = true;
      driSupport = true;
      driSupport32Bit = true;
    extraPackages = with pkgs;
        [ vaapiIntel libvdpau  libvdpau-va-gl vaapiVdpau ];

    };
  };
  services.printing.enable = true;
  services.printing.drivers = [pkgs.gutenprint pkgs.gutenprintBin pkgs.hplipWithPlugin];

   nix.nixPath = [ 
    "nixpkgs-overlays=/home/dcol/dotfiles/nix/overlays-compat/"
    "nixpkgs=/home/dcol//.nix-defexpr/channels/nixos"
    "nixos-hardware=/home/dcol/.nix-defexpr/channels/nixos-hardware"
    "nixos-config=/home/dcol/dotfiles/nix/configuration.nix"
          ];
  
  # Power management
  powerManagement.enable = true;
  services.tlp.enable = true;
  # Map CAPS to ESC / CTRL
  services.interception-tools.enable = true;
  systemd = {
    user = {
      timers.battery-check = {
        wantedBy = [ "timers.target" ];
        partOf = [ "battery-check.service" ];
        timerConfig.OnBootSec = "1m";
        timerConfig.OnUnitInactiveSec = "1m";

      };
      services.battery-check = {
        serviceConfig.Type = "oneshot";
        script = hibernation;
      };
    };

    # wait-online keeps getting stuck, so disable it.
    services.systemd-networkd-wait-online.enable = false;
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
  swapDevices = [
    { device = "/dev/disk/by-label/swap"; }
  ];
  # Build nixos configs remotely for speed
	nix.buildMachines = [ {
	 hostName = "192.168.1.11";
	 system = "x86_64-linux";
	 maxJobs = 10;
	}];
	nix.distributedBuilds = true;
  fileSystems."/theta" = {
    device = "192.168.1.11:/theta";
    fsType = "nfs";
  };

}
