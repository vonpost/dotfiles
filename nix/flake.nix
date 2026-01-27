{
  description = "NixOS configuration (flake)";
  inputs =
        {
          self.submodules = true;
          nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
          bleeding.url = "github:NixOS/nixpkgs/master";
          nixos-hardware.url = "github:NixOS/nixos-hardware";
          sops-nix.url = "github:Mic92/sops-nix";
          sops-nix.inputs.nixpkgs.follows = "nixpkgs";
          microvm.url = "github:microvm-nix/microvm.nix";
          microvm.inputs.nixpkgs.follows = "nixpkgs";
          UCHI.url = ./vm/UCHI;
          SOTO.url = ./vm/SOTO;
          KAIZOKU.url = ./vm/KAIZOKU;
          DARE.url = ./vm/DARE;
          OKAMI.url = ./vm/OKAMI;
          MAMORU.url = ./vm/MAMORU;
        };

  outputs =
    { self,
      nixpkgs,
      bleeding,
      nixos-hardware,
      sops-nix,
      microvm,
      UCHI,
      SOTO,
      KAIZOKU,
      DARE,
      OKAMI,
      MAMORU,
      ... }:
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
          microvm.nixosModules.host

          ./MOTHER/configuration.nix
          ./lib/host-state-map.nix

          {
            networking.hostName = "MOTHER";
            microvm.stateDir = "/aleph/vm-pool/microvm";
            microvm.autostart = ["UCHI" "SOTO" "DARE" "OKAMI" "KAIZOKU" "MAMORU"];
            microvm.vms.UCHI = { flake = UCHI; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/UCHI"; };
            microvm.vms.SOTO = { flake = SOTO; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/SOTO"; };
            microvm.vms.DARE = { flake = DARE; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/DARE"; };
            microvm.vms.KAIZOKU = { flake = KAIZOKU; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/KAIZOKU"; };
            microvm.vms.OKAMI = { flake = OKAMI; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/OKAMI"; };
            microvm.vms.MAMORU = { flake = MAMORU; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/MAMORU"; };
          }
        ];
      };
    };
}
