{ ... }:
{
  imports = [
    ./jelly-media.nix
    ./arr.nix
    ./downloads.nix
    ./nginx.nix
    ./myaddr.nix
    ./recyclarr.nix
    ./acme.nix
    ./geoip.nix
    ./observability.nix
    ./log-digest.nix
    ./llama-cpp.nix
  ];
}
