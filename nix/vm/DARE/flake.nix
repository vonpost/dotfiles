{
  description = "DARE MicroVM (Unbound)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bleeding.url = "github:NixOS/nixpkgs/master";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, bleeding, microvm, ... }:
    let
      system = "x86_64-linux";
      bleedingPkgs = import bleeding {
        inherit system;
        config.allowUnfree = true;
      };
      bleedingPackageNames = [
        "vector"
      ];
      bleedingOverlay = final: prev:
        nixpkgs.lib.genAttrs bleedingPackageNames (name: bleedingPkgs.${name});
    in
    {
      nixosConfigurations.DARE = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          bleeding = bleedingPkgs;
        };
        modules = [
          { nixpkgs.overlays = [ bleedingOverlay ]; }
          microvm.nixosModules.microvm
          ../../config/infra/vms/DARE.nix
        ];
      };
    };
}
