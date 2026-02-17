{ hostname }:
{ lib, ... }:
let
  vmConfig = import ./vm-config.nix;
  svcMap = import ./service-map.nix;

  servicesForVm = map (serviceName:
    let service = svcMap.${serviceName};
    in service // {
      _secretUnit = service.unit or service.name or serviceName;
    }
  ) vmConfig.${hostname}.serviceMounts;

  secretEntries =
    lib.concatLists (
      map (service:
        lib.mapAttrsToList (secretName: secret: {
          name = secretName;
          source = secret.source;
          unit = service._secretUnit;
        }) (service.secrets or { })
      ) servicesForVm
    );

  credentialFiles = lib.listToAttrs (map (secret:
    lib.nameValuePair secret.name secret.source
  ) secretEntries);

  loadCredentialByUnit =
    builtins.foldl'
      (acc: secret:
        acc // {
          ${secret.unit} = (acc.${secret.unit} or [ ]) ++ [ secret.name ];
        }
      )
      { }
      secretEntries;

  loadCredentialServices =
    lib.mapAttrs (_unit: credentials: {
      serviceConfig.LoadCredential = lib.mkForce ( lib.unique credentials );
    }) loadCredentialByUnit;
in
{
  config = {
    microvm.credentialFiles = credentialFiles;
    systemd.services = loadCredentialServices;
  };
}
