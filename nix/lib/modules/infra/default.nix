{ ... }:
{
  imports = [
    ../../../config/infra/site-defaults.nix
    ./schema.nix
    ./service-state.nix
    ./service-secrets.nix
    ./host-service-mounts.nix
    ./network-host.nix
    ./network-guest.nix
    ./network-gateway.nix
    ./network-dns.nix
  ];
}
