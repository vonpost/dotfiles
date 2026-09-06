{ lib, nixosConfigurations }:
let
  server = nixosConfigurations.SOTO.config;
  worker = nixosConfigurations.OKAMI.config;
  withoutPortMetadata = (nixosConfigurations.SOTO.extendModules {
    modules = [{
      my.infra.vms.SOTO.provides = lib.mkForce [ "ssh" "node_exporter" ];
      my.infra.vms.OKAMI.provides = lib.mkForce [ "ssh" "node_exporter" ];
    }];
  }).config;
  sharedPaths = [ "/var/lib/jellyfin" "/var/cache/jellyfin" "/data/media" ];
  checks = {
    serverEnabled = server.services.jellyfin.enable && server.services.okuri.enable;
    workerOnly = worker.services.okuri-target.enable
      && !worker.services.jellyfin.enable
      && !(worker.systemd.services ? jellyfin);
    controllerKeyStaysOnServer = server.microvm.credentialFiles ? jellyfin_transcode_ssh_key
      && !(worker.microvm.credentialFiles ? jellyfin_transcode_ssh_key);
    sharedPathsPreserved = builtins.all
      (path: server.fileSystems.${path}.device == worker.fileSystems.${path}.device) sharedPaths;
    sharedIdentityPreserved = server.users.users.jellyfin.uid == worker.users.users.jellyfin.uid
      && server.users.groups.jellyfin.gid == worker.users.groups.jellyfin.gid
      && worker.users.users.jellyfin.isNormalUser;
    firewallDoesNotEnableApplications = withoutPortMetadata.services.jellyfin.enable
      && withoutPortMetadata.services.okuri.enable
      && withoutPortMetadata.services.okuri.targetHost == "okami.lan";
    workerSourceRestriction = worker.services.okuri-target.authorizedKeys == [
      "from=\"10.10.30.25\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzH2Gt2Xs7mNeSpqNCJy2lwT19XC3OiSBNWBHK6zrzF dcol@TERRA"
    ];
  };
in
assert lib.assertMsg (builtins.all (x: x) (builtins.attrValues checks))
  "Role contract failed: ${lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: x: !x) checks))}";
checks
