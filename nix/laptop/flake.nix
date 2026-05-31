{
  description = "TERRA laptop NixOS configuration";

  inputs =
        {
          self.submodules = true;
          nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
          bleeding.url = "github:NixOS/nixpkgs/master";
          nixos-hardware.url = "github:NixOS/nixos-hardware";
          sops-nix.url = "github:Mic92/sops-nix";
          sops-nix.inputs.nixpkgs.follows = "nixpkgs";
        };

  outputs =
    { self,
      nixpkgs,
      bleeding,
      nixos-hardware,
      sops-nix,
      ... }:
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
      localOverlay = final: prev: {
        infra-flake-update = final.callPackage ../pkgs/infra-flake-update.nix { };
      };
    in
    {
      packages.${system}.infra-flake-update =
        nixpkgs.legacyPackages.${system}.callPackage ../pkgs/infra-flake-update.nix { };

      nixosConfigurations.TERRA = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          bleeding = bleedingPkgs;
        };
        modules = [
          { nixpkgs.overlays = [ bleedingOverlay localOverlay ]; }
          nixos-hardware.nixosModules.lenovo-thinkpad-t14-amd-gen1
          sops-nix.nixosModules.sops
          ./configuration.nix
        ];
      };
    };
}
