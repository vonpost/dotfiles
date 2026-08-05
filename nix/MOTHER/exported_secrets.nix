{ config, lib, pkgs, ... }:
let
  vmConfig = config.my.infra.vmServiceMounts;
  svcMap = config.my.infra.services;

  enabledServiceNames =
    lib.unique (
      lib.concatLists (
        lib.mapAttrsToList (_vmName: vmCfg: vmCfg.serviceMounts) vmConfig
      )
    );

  toSopsSecretName = source:
    let
      prefix = "/run/secrets/";
    in
      if lib.hasPrefix prefix source then
        lib.removePrefix prefix source
      else
        throw "Service secret source '${source}' must be under ${prefix}";

  # Per-VM SSH host keys, passed into each guest via microvm.credentialFiles
  # (qemu fw_cfg -> systemd credential -> sshd HostKey). The qemu runner opens
  # these as the microvm user, hence the owner/group.
  microvmHostKeySecrets =
    lib.listToAttrs (
      map (vmName:
        lib.nameValuePair "microvm-ssh/${vmName}" {
          sopsFile = ../secrets/microvm-ssh.yaml;
          key = vmName;
          owner = "microvm";
          group = "kvm";
          mode = "640";
        })
        (builtins.attrNames vmConfig)
    );

  generatedServiceSecrets =
    lib.listToAttrs (
      lib.concatLists (
        map (serviceName:
          let
            service = svcMap.${serviceName};
          in
            lib.mapAttrsToList (_credentialName: secret:
              let
                sopsCfg = secret.sops or { };
              in
              lib.nameValuePair
                (toSopsSecretName secret.source)
                (sopsCfg // {
                  owner = "microvm";
                  group = "kvm";
                  mode = sopsCfg.mode or "640";
                })
            ) (service.secrets or { })
        ) enabledServiceNames
      )
    );
in

{
    sops = {
      defaultSopsFile = ../secrets/secrets.yaml;
      age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
      keepGenerations = 0;
      secrets = generatedServiceSecrets // microvmHostKeySecrets // {
        "wifi" = {
          format = "dotenv";
          sopsFile = ../secrets/wifi.env;
          group="wpa_supplicant";
          mode= "640";
          key = "";
        };
        "wg/MOTHER" = {
          mode = "640";
          owner = "systemd-network";
          group = "systemd-network";
        };
      };
    };
}
