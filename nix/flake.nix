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
      nixosConfigurations.MOTHER = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          bleeding = bleedingPkgs;
          ssh_master_keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
            ];
        };
        modules = [
          sops-nix.nixosModules.sops
          ./MOTHER/configuration.nix
          ./MOTHER/contain-qbit-mullvad.nix
          ./MOTHER/contain-vpn.nix
        ];
      };
    };
}
