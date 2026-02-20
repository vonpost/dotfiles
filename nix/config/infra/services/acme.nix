{ config, lib, pkgs, ... }:
let
  svc = import ./lib.nix { inherit config; };
in
{
  config = lib.mkIf (svc.hasService "acme") {
    security.acme.acceptTerms = true;
    security.acme.defaults.email = "daniel.j.collin@gmail.com";
    users.users.nginx.extraGroups = [ "acme" ];
  };
}
