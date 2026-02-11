{
 description = "SOTO microvm (guest)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    bleeding.url = "github:NixOS/nixpkgs/master";
    rffmpeg-nix.url = ../../rffmpeg-nix;
  };

  outputs = { self, nixpkgs, microvm, bleeding, rffmpeg-nix, ... }:
    let
      system = "x86_64-linux";
      bleedingPkgs = import bleeding {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      nixosConfigurations.SOTO = nixpkgs.lib.nixosSystem {
        inherit system;


        specialArgs = {
          bleeding = bleedingPkgs;
        };
        modules = [
          microvm.nixosModules.microvm
          rffmpeg-nix.nixosModules.rffmpeg
          {
              nixpkgs.overlays = [
                rffmpeg-nix.overlays.default
              ];
              microvm.credentialFiles = { jellyfin_transcode_ssh_key = "/run/secrets/ssh/jellyfin"; };
              systemd.services.jellyfin.serviceConfig.LoadCredential="jellyfin_transcode_ssh_key";
              services.rffmpeg.enable = true;
              services.rffmpeg.hosts = [ "okami.lan" ];

          }
          ./configuration.nix
        ];
      };
    };
}
