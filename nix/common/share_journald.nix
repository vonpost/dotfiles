{ self, config, lib, pkgs, ... }:
let
  addr = import ../lib/lan-address.nix;
in
{
  environment.etc."machine-id" = {
    mode = "0644";
    text =
      addr.${config.networking.hostName}.machineId + "\n";
  };

  microvm.shares = [ {
    # On the host
    source = "/aleph/vm-pool/microvm/${config.networking.hostName}/journal";
    # In the MicroVM
    mountPoint = "/var/log/journal";
    tag = "journal";
    proto = "virtiofs";
    socket = "journal.sock";
  } ];
}
