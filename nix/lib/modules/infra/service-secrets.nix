{ lib, config, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.my.infra.serviceSecrets;
  services = config.my.infra.services;
  vms = config.my.infra.vms;

  servicesForHost =
    map
      (serviceName:
        let service = services.${serviceName};
        in service // { _secretUnit = service.unit; }
      )
      (vms.${cfg.hostname}.services or [ ]);

  secretEntries =
    lib.concatLists (
      map
        (service:
          lib.mapAttrsToList
            (secretName: secret: {
              name = secretName;
              source = secret.source;
              unit = service._secretUnit;
            })
            service.secrets
        )
        servicesForHost
    );

  credentialFiles =
    lib.listToAttrs (
      map (secret: lib.nameValuePair secret.name secret.source) secretEntries
    );

  loadCredentialByUnit =
    builtins.foldl'
      (acc: secret:
        acc
        // {
          ${secret.unit} = (acc.${secret.unit} or [ ]) ++ [ secret.name ];
        }
      )
      { }
      secretEntries;

  loadCredentialServices =
    lib.mapAttrs
      (_unit: credentials: {
        serviceConfig.LoadCredential = lib.mkForce (lib.unique credentials);
      })
      loadCredentialByUnit;
in
{
  options.my.infra.serviceSecrets = {
    enable = mkEnableOption "microvm credentialFiles + LoadCredential wiring for service secrets";
    hostname = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "VM hostname key in my.infra.vms.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.hostname vms;
        message = "my.infra.serviceSecrets.hostname '${cfg.hostname}' does not exist in my.infra.vms";
      }
    ];

    microvm.credentialFiles = credentialFiles;
    systemd.services = loadCredentialServices;
  };
}
