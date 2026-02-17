{ hostname
, sshHosts ? {
  mobi = { publicKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+"; };
  TERRA = {publicKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg"; };
  MOTHER = { publicKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQ5oRZYos1W+reVTkkXq8ETxF4RFc90ydcw5jo/dHaG"; };
}
, isJournalHost ? false
}:
{ lib, config, ... }:
let
  netLib = import ../lib/network-topology.nix { inherit lib; };
  svc = import ../lib/vm-service-state.nix {inherit lib;};
  svcMap = import ../lib/service-map.nix;
  vmConfig = import ../lib/vm-config.nix;
  servicesForVm = map (serviceName: svcMap.${serviceName}) vmConfig.${hostname}.serviceMounts;
  statefulServices = map
    (service: builtins.removeAttrs service [ "managedState" "secrets" ])
    (builtins.filter (service: service.managedState or true) servicesForVm);
in
{
  networking.hostName = hostname;

  time.timeZone = "Europe/Stockholm";

  imports = [
    (netLib.mkGuest hostname)
    (import ./share_journald.nix { isHost = isJournalHost; hostname=hostname; })
    ../lib/microvm-shares.nix
    (import ../lib/vm-service-secrets.nix { inherit hostname; })
  ]
    ++ (svc.mkMany statefulServices);
  microvm.hypervisor = lib.mkDefault "qemu";
  microvm.vsock.cid = netLib.vms.${hostname}.id;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
  ] ++ lib.optional (statefulServices != [ ]) (
    {
      proto = "virtiofs";
      tag = "state";
      source = "/run/microvm-staging/${hostname}";
      mountPoint = "/state";
    }
  );

  services.openssh.enable = lib.mkDefault true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "yes";
  };

  users.users.root.openssh.authorizedKeys.keys = map (h: sshHosts.${h}.publicKey ) (builtins.attrNames sshHosts);
  system.stateVersion = "26.05";
}
