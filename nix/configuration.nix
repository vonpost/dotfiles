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
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./audio.nix
    ];
  

  # periodic GC
  nix.gc.automatic = true;
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 30d";

  # Use the GRUB 2 boot loader.
  boot.kernelPackages = pkgs.linuxPackages_latest;       
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.extraConfig = ''
  GRUB_CMDLINE_LINUX_DEFAULT="quiet splash psmouse.synaptics_intertouch=0"
  '';
  # Steam controller
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="28de", MODE="0666"
    KERNEL=="uinput", MODE="0660", GROUP="users", OPTIONS+="static_node=uinput"
  '';


  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/sda"; # or "nodev" for efi only
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call config.boot.kernelPackages.tp_smapi ];
  #networking.enableIPv6 = false;
  networking.hostName = "LAIN"; # Define your hostname.
  #networking.connman.enable = true;
  # networking.wicd.enable = true;
  networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;
  # Select internationalisation properties.
  i18n = {
    consoleFont = "Lat2-Terminus16";
    consoleKeyMap = "us";
    defaultLocale = "en_US.UTF-8";
  };
  # Shell aliases
  environment.shellAliases = {
    em = "emacsclient -c";
    emt = "emacsclient -nw";
    editnix = "em ~/dotfiles/nix/configuration.nix";
    updatenix = "sh ~/dotfiles/nix/updateConfig.sh";
    updatenixlocal = "sh ~/dotfiles/nix/updateConfigLocalNixpkgs.sh";
  };
  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  nixpkgs.config = {
		allowUnfree = true;
  };
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget

  environment.systemPackages = with pkgs; [
    # BROWSER
    qutebrowser

    # GAMING
    steam
    discord
    wine-staging

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
    
    #ACCESSORIES
    qbittorrent
    xpdf
    wpa_supplicant_gui
    rofi-pass
    pass
    gnupg
    rxvt_unicode
    screenfetch
    ghostscript
    wget
    rofi
    xclip
    maim
    ranger
    libnotify
    dunst
    oblogout
    pamixer
    feh
    
    #POWER MANAGEMENT
    powertop
    tlp
    acpi
 
    # HASKELL
    haskellPackages.categories
    
    # XMONAD stuff
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
  # services.emacs.install = true;
   


  services.emacs.package = with pkgs; (emacsWithPackages (with emacsPackagesNg; [
    auctex
    rainbow-mode
    rainbow-delimiters
    evil-collection
    visual-regexp-steroids
    flycheck
    haskell-mode
    highlight-parentheses
    magit
    dante
    nix-buffer
    company
    company-math
    projectile
    nix-mode
    pdf-tools
    ranger
    ivy
    swiper
    counsel
    ivy-pass
    evil
    frames-only-mode
    latex-preview-pane
    which-key
    rust-mode
  ]));

  # Hide cursor when idle.
  services.unclutter-xfixes.enable = true;
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # Enable X11
  services.xserver = {
    enable = true;
    layout = "us";
    xkbOptions = "eurosign:e";


    # WINDOW MANAGER
    windowManager = {
      default = "xmonad";
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
    # Trackpoint settings
    displayManager.sessionCommands = ''
    xinput set-prop "TPPS/2 IBM TrackPoint" "libinput Accel Speed" 1
    xinput set-prop "TPPS/2 IBM TrackPoint" "libinput Accel Profile Enabled" 0, 1
    '';
    displayManager.lightdm = {
      enable = true;
      autoLogin.enable = true;
      autoLogin.user = "dcol";
      greeter.enable = false;
    };
    displayManager.slim = {
      enable = false;
      autoLogin = true;    
    };
    desktopManager.default = "none";
    desktopManager.xterm.enable = false;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.extraUsers.dcol = {
    isNormalUser = true;
    createHome = true;
    home = "/home/dcol/";
    description = "Daniel Collin";
    extraGroups = ["audio" "wheel" "networkmanager"];
    useDefaultShell = true;
  };

  # enable to allow ios connection for tethering
  services.usbmuxd.enable = true;
  security.sudo.enable = true;
  nixpkgs.config.packageOverrides = pkgs: {
     vaapiIntel = pkgs.vaapiIntel.override { enableHybridCodec = true; };
   };
  hardware = {
    opengl = {
      enable = true;
      driSupport = true;
      driSupport32Bit = true;
    extraPackages = with pkgs;
        [ vaapiIntel libvdpau  libvdpau-va-gl vaapiVdpau ];

    };
  };
  # nix.nixPath = [
  #   "/home/dcol/nixpkgs/"
  #   "/nix/var/nix/profiles/per-user/root/channels/nixos"
  #   "nixos-config=/home/dcol/dotfiles/nix/configuration.nix/"
  # ];
   nix.nixPath = [
    "/home/dcol/nixpkgs"
    "/home/dcol/dotfiles/nix"
    "nixpkgs-overlays=/home/dcol/dotfiles/nix/overlays/"
    "/nix/var/nix/profiles/per-user/root/channels/nixos"
            "nixpkgs=/etc/nixos/nixpkgs"
            "nixos=/etc/nixos/nixos"
            "nixos-config=/etc/nixos/configuration.nix"
            "services=/etc/nixos/services"
          ];
  
  #H 
  # Power management
  powerManagement.enable = true;
  services.fprintd.enable = true;
  services.tlp.enable = true;
  services.upower.enable = true;
  # Map CAPS to ESC / CTRL
  services.interception-tools.enable = true;
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

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
   system.stateVersion = "18.03"; # Did you read the comment?

}
