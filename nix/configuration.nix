# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];
  # periodic GC
  nix.gc.automatic = true;
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 30d";

  # Use the GRUB 2 boot loader.
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  # boot.loader.grub.efiSupport = true;
  # boot.loader.grub.efiInstallAsRemovable = true;
  # boot.loader.efi.efiSysMountPoint = "/boot/efi";
  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/sda"; # or "nodev" for efi only
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call config.boot.kernelPackages.tp_smapi ];
  networking.enableIPv6 = false;
  networking.hostName = "LAIN"; # Define your hostname.
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
    editnix = "em ~/dotfiles/nix/configuration.nix";
    updatenix = "sh ~/dotfiles/nix/updateConfig.sh";
  };
  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    # BROWSER
    # would prefer using chromium, but doesnt support native client for chrome remote desktop 
    google-chrome
    # GAMING
    steam
    discord 

    # VIDEO PLAYER
    mpv

    # AUDIO
    pulsemixer

    # PROGRAMMING
    emacs
    vim
    ghc
    gcc
    git

    #ACCESSORIES
    rxvt_unicode
    screenfetch
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

    # XMONAD stuff
    haskellPackages.xmonad-contrib
    haskellPackages.xmonad-extras
    haskellPackages.xmonad
    haskellPackages.xmobar
  ];

  nixpkgs.config = {
		 allowUnfree = true;
		 chromium = {
		   # enablePepperFlash = true;
		   # enablePepperPDF = true;
		   };

  };

  # EMACS configuration stuff

  services.emacs.defaultEditor = true;
  services.emacs.enable = true;
  services.emacs.package = with pkgs; (emacsWithPackages (with emacsPackagesNg; [
      evil
      haskell-mode
      intero
      nix-mode
      org
      python-mode
      frames-only-mode
      ivy

  ]));
  
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable the X11 and xmonad.
  # services.xserver.enable = true;
  # services.xserver.layout = "us";
  # services.xserver.xkbOptions = "eurosign:e";
  # services.xserver.windowManager.xmonad = {
  # 	enable = true;
  # 	enableContribAndExtras = true;
  # 	extraPackages = haskellPackages: [
  # 		haskellPackages.xmonad-contrib
  # 		haskellPackages.xmonad-extras
  # 		haskellPackages.xmonad
  # 	];
  # };
  # services.xserver.windowManager.default = "xmonad";

  # enable X11
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

    # DISPLAY MANAGER

    displayManager.sessionCommands = ''
        ${pkgs.xlibs.xsetroot}/bin/xsetroot -cursor_name left_ptr # Set cursor
        ${pkgs.xlibs.xsetroot}/bin/xsetroot -solid pink # Set bg color
    '';

    displayManager.slim = {
      enable = true;
      defaultUser = "dcol";
      autoLogin = true;    
    };
  };
  # services.xserver.libinput.enable = true;
  # services.xserver.displayManager.slim.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.extraUsers.dcol = {
    isNormalUser = true;
    createHome = true;
    home = "/home/dcol/";
    description = "Daniel Collin";
    extraGroups = [ "wheel" "networkmanager"];
    useDefaultShell = true;
  };
  security.sudo.enable = true;
  hardware.pulseaudio = {
     enable = true;
     support32Bit = true;
  };
  hardware.opengl = {
     enable = true;
     driSupport = true;
     driSupport32Bit = true;
  };
  services.tlp.enable = true;
  services.logind.extraConfig = "HandlePowerKey=ignore";
  systemd.user.services.dunst = {
    enable = true;
    description = "dunst daemon";
    wantedBy = [ "default.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.dunst}/bin/dunst";
      Restart = "always";
    };
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "17.09"; # Did you read the comment?

}
