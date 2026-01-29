{ hostname
, lanPrefix ? 24
, nameserverHost ? "DARE"
, dnsHost ? nameserverHost
, media ? false
, shareJournal ? true
, mediaShares ? [
    {
      proto = "virtiofs";
      tag = "theta";
      source = "/theta/";
      mountPoint = "/theta";
    }
  ]
, sshKeys ? [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
  ]
, isJournalHost ? false
, vlan ? "wan"
}:
{ lib, ... }:
let
  addrs = import ../lib/lan-address.nix;
  netLib = import ../lib/network-topology.nix;
  nameservers =
    if nameserverHost == null then [] else [ addrs.${nameserverHost}.ip ];
  dnsServers = if dnsHost == null then [] else [ addrs.${dnsHost}.ip ];
  mediaSharesList = if media then mediaShares else [];
in
{
  imports = [ (netLib.mkGuest hostname) ] ++ lib.optionals shareJournal [ (import ./share_journald.nix { isHost = isJournalHost; } ) ];
  microvm.hypervisor = lib.mkDefault "cloud-hypervisor";
  microvm.vsock.cid = addrs.${hostname}.vsock_cid;
  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
  ] ++ mediaSharesList;

  services.openssh.enable = lib.mkDefault true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "yes";
  };

  users.users.root.openssh.authorizedKeys.keys = sshKeys;
  system.stateVersion = "26.05";
}
