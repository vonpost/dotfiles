{
  description = "NixOS configuration (flake)";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bleeding.url = "github:NixOS/nixpkgs/master";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, bleeding, nixos-hardware, sops-nix, ... }:
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
          sops-nix.nixosModules.sops
          ./laptop/configuration.nix
        ];
      };
    };
}
