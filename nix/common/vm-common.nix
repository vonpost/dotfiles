{ hostname
, sshHosts ? {
  mobi = { publicKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+"; };
  TERRA = {publicKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg"; };
  MOTHER = { publicKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQ5oRZYos1W+reVTkkXq8ETxF4RFc90ydcw5jo/dHaG"; };
}
}:
{ lib, config, pkgs, ... }:
let
  infra = config.my.infra;
  svc = import ../lib/vm-service-state.nix { inherit lib; };
  svcMap = import ../config/infra/service-map.nix;
  vmConfig = import ../config/infra/vm-config.nix;
  servicesForVm =
    map (serviceName: svcMap.${serviceName}) vmConfig.${hostname}.serviceMounts;
  statefulServices = map
    (service: builtins.removeAttrs service [ "managedState" "secrets" ])
    (builtins.filter (service: service.managedState or true) servicesForVm);
  hasStatefulServices = statefulServices != [ ];
in
{
  networking.hostName = hostname;

  time.timeZone = "Europe/Stockholm";

  imports = [
    ../lib/modules/infra
    ../okuri/nixos-modules/controller.nix
    ../okuri/nixos-modules/target.nix
    ../config/infra/services
  ] ++ lib.optional (builtins.elem "sabnzbd" vmConfig.${hostname}.serviceMounts) ./sabnzbd_config.nix
    ++ (svc.mkMany statefulServices);

  nixpkgs.overlays = lib.mkBefore [
    (final: prev: {
      okuri = prev.callPackage ../okuri/pkgs/okuri.nix { };
    })
  ];

  my.infra = {
    networkGuest = {
      enable = true;
      name = hostname;
    };
    serviceSecrets = {
      enable = true;
      hostname = hostname;
    };
    loggingAgent = {
      enable = true;
      hostname = hostname;
    };
  };

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "0.0.0.0";
    enabledCollectors = [ "systemd" ];
  };

  environment.systemPackages = with pkgs; [
    tcpdump
    curl
    bind
    conntrack-tools
  ];

  microvm.hypervisor = lib.mkDefault "qemu";
  microvm.registerWithMachined = true;
  microvm.vsock.cid = infra.topology.vms.${hostname}.id;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
  ] ++ lib.optional hasStatefulServices (
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

  # Stable SSH host identity: the rootfs is ephemeral, so boot-generated host
  # keys would change on every reboot. Instead each VM receives its sops-stored
  # key from MOTHER as a systemd credential (fw_cfg) and sshd uses only that.
  # hostKeys must be empty: the module emits its HostKey lines at mkOrder 0,
  # and sshd offers the first ed25519 key listed — a generated key would
  # shadow the stable one. A missing credential can't strand sshd anyway:
  # qemu refuses to start when a credential file is absent on the host.
  microvm.credentialFiles."ssh-host-key" = "/run/secrets/microvm-ssh/${hostname}";
  systemd.services.sshd.serviceConfig.LoadCredential = [ "ssh-host-key" ];
  services.openssh.hostKeys = lib.mkForce [ ];
  services.openssh.extraConfig =
    lib.mkBefore "HostKey /run/credentials/sshd.service/ssh-host-key";

  # With stable identities the whole fleet can pin each other declaratively.
  programs.ssh.knownHosts =
    lib.mapAttrs'
      (vmName: publicKey: lib.nameValuePair "${lib.toLower vmName}.lan" {
        inherit publicKey;
        extraHostNames = [ (lib.toLower vmName) ];
      })
      (import ../config/infra/vm-host-keys.nix);

  users.users.root.openssh.authorizedKeys.keys = map (h: sshHosts.${h}.publicKey ) (builtins.attrNames sshHosts);
  system.stateVersion = "26.05";
}
