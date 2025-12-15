{
  description = "NixOS configuration (flake)";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bleeding.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs =
    { self, nixpkgs, bleeding, nixos-hardware, ... }:
    let
      system = "x86_64-linux";
      bleedingPkgs = import bleeding {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosConfigurations.TERRA = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          bleeding = bleedingPkgs;
        };
        modules = [
          nixos-hardware.nixosModules.lenovo-thinkpad-t14-amd-gen1
          ./configuration.nix
        ];
      };
    };
}
