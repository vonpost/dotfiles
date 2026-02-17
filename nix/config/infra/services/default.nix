{ ... }:
{
  imports = [
    ./jelly-media.nix
    ./arr.nix
    ./downloads.nix

    ../../../common/nginx.nix
    ../../../common/myaddr.nix
    ../../../common/recyclarr.nix
  ];
}
