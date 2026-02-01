{ isHost ? false, hostname}:
let
  addr = import ../lib/lan-address.nix;
  mid=addr.${hostname}.machineId;
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
