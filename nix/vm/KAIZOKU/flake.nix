{
 description = "KAIZOKU microvm (guest)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    bleeding.url = "github:NixOS/nixpkgs/master";
  };

  outputs = { self, nixpkgs, microvm, bleeding, ... }:
    let
      system = "x86_64-linux";
      bleedingPkgs = import bleeding {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      nixosConfigurations.KAIZOKU = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          bleeding = bleedingPkgs;
        };
        modules = [
          microvm.nixosModules.microvm
          ./configuration.nix
        ];
      };
    };
}
