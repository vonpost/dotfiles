{ isHost ? false, hostname }:
{ config, ... }:
let
  mid = config.my.infra.vmServiceMounts.${hostname}.machineId;
  mountPath = if isHost then "" else "/${mid}";
in
{
  environment.etc."machine-id" = {
    mode = "0644";
    text =
      mid + "\n";
  };

  microvm.shares = [ {
    # On the host
    source = "/var/log/journal${mountPath}";
    # In the MicroVM
    mountPoint = "/var/log/journal${mountPath}";
    tag = "journal";
    proto = "virtiofs";
    socket = "journal.sock";
  } ];
}
