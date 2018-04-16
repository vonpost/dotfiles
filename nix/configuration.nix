# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:
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
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  # Steam controller
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="28de", MODE="0666"
    KERNEL=="uinput", MODE="0660", GROUP="users", OPTIONS+="static_node=uinput"
  '';


  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/sda"; # or "nodev" for efi only
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call config.boot.kernelPackages.tp_smapi ];
  networking.enableIPv6 = false;
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
  };
  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  nixpkgs.config = {
		allowUnfree = true;
		chromium = {
		   enablePepperFlash = true;
		  enablePepperPDF = true;
      enableWildVine = true;
		   };
  };

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    # BROWSER
    qutebrowser

    # GAMING
    steam
    discord

    # VIDEO 
    ffmpeg
    mpv

    # AUDIO
    alsaUtils
    pulsemixer


    # MATH
    texlive.combined.scheme-full
    # PROGRAMMING
    emacs
    vim
    ghc
    gcc
    git

    #ACCESSORIES
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
    wineStaging
    
    #POWER MANAGEMENT
    powertop
    tlp
    acpi
 
    # HASKELL
    # XMONAD stuff
    haskellPackages.xmonad-contrib
    haskellPackages.xmonad-extras
    haskellPackages.xmonad
    haskellPackages.xmobar
  ];

  
  #urxvt stuff
  #daemon
  services.urxvtd.enable = true;

    
  # EMACS configuration stuff
  services.emacs.defaultEditor = true;
  services.emacs.enable = true;
  services.emacs.package = with pkgs; (emacsWithPackages (with emacsPackagesNg; [
    auctex
    ace-window
    rainbow-mode
    rainbow-delimiters
    treemacs
    treemacs-evil
    evil-collection
    visual-regexp-steroids
    flycheck
    haskell-mode
    highlight-parentheses
    magit
    nix-mode
    pdf-tools
    smartparens
    smooth-scrolling
    ivy
    swiper
    counsel
    ivy-pass
    tidal
    evil
    frames-only-mode
    latex-preview-pane
  ]));

  # Hide cursor when idle.
  services.unclutter-xfixes.enable = true;
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # Enable CUPS to print documents.
  # services.printing.enable = true;

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
    #horizontal scroll sucks on bad touchpad
    libinput.horizontalScrolling = false;

    # DISPLAY MANAGER

    displayManager.sessionCommands = ''
        ${pkgs.xlibs.xsetroot}/bin/xsetroot -cursor_name left_ptr # Set cursor
    '';

    displayManager.slim = {
      enable = true;
      defaultUser = "dcol";
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
  hardware = {
    opengl = {
      enable = true;
      driSupport = true;
      driSupport32Bit = true;
    };
  };
  
  powerManagement.enable = true;
  services.fprintd.enable = true;
  services.tlp.enable = true;
  services.acpid.powerEventCommands = "systemctl suspend";
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
  system.stateVersion = "17.09"; # Did you read the comment?

}
