{ config, pkgs, ... }:

{
  ############################
  ## Power management basics
  ############################
  powerManagement.enable = true;
  powerManagement.powertop.enable = true;

  services = {
    power-profiles-daemon.enable = false;
    tlp = {
        enable = true;
        settings = {
            # CPU_BOOST_ON_AC = 1;
            # CPU_BOOST_ON_BAT = 0;
            # CPU_SCALING_GOVERNOR_ON_AC = "performance";
            # CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
            STOP_CHARGE_THRESH_BAT0 = 95;
        };
    };
    system76-scheduler.settings.cfsProfiles.enable = true;
  };

  ########################################
  ## Suspend on lid / power-button actions
  ########################################
  services.logind = {
    lidSwitch = "suspend";              # close lid -> suspend
    lidSwitchExternalPower = "suspend"; # also suspend when on AC (change to "ignore" if you prefer)
    lidSwitchDocked = "ignore";         # don't suspend if docked (tweak to taste)

    powerKey = "suspend";               # short press power button -> suspend
    powerKeyLongPress = "poweroff";     # long press -> power off
  };
  services.upower = {
    enable = true;
    usePercentageForPolicy = true;
    percentageLow = 15;       # show "low" warning
    percentageCritical = 7;   # "critical" state
    percentageAction = 5;     # when to act
    criticalPowerAction = "Hibernate";  # action at percentageAction
  };

  boot.resumeDevice = builtins.head (map (d: d.device) config.swapDevices);
  services.acpid.enable = true;
}
