{
  description = "NixOS configuration (flake)";
  inputs =
        {
          self.submodules = true;
          nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
          bleeding.url = "github:NixOS/nixpkgs/master";
          sops-nix.url = "github:Mic92/sops-nix";
          sops-nix.inputs.nixpkgs.follows = "nixpkgs";
          microvm.url = "github:microvm-nix/microvm.nix";
          microvm.inputs.nixpkgs.follows = "nixpkgs";
          rffmpeg-nix.url = ./rffmpeg-nix;
          wolf.url = ./wolf-nix;
          UCHI.url = ./vm/UCHI;
          UCHI.inputs.microvm.follows = "microvm";
          SOTO.url = ./vm/SOTO;
          SOTO.inputs.microvm.follows = "microvm";
          KAIZOKU.url = ./vm/KAIZOKU;
          KAIZOKU.inputs.microvm.follows = "microvm";
          DARE.url = ./vm/DARE;
          DARE.inputs.microvm.follows = "microvm";
          OKAMI.url = ./vm/OKAMI;
          OKAMI.inputs.microvm.follows = "microvm";
          MAMORU.url = ./vm/MAMORU;
          MAMORU.inputs.microvm.follows = "microvm";
          NIKKI.url = ./vm/NIKKI;
          NIKKI.inputs.microvm.follows = "microvm";
        };

  outputs =
    { self,
      nixpkgs,
      bleeding,
      sops-nix,
      microvm,
      rffmpeg-nix,
      wolf,
      UCHI,
      SOTO,
      KAIZOKU,
      DARE,
      OKAMI,
      MAMORU,
      NIKKI,
      ... }:
    let
      system = "x86_64-linux";
      bleedingPkgs = import bleeding {
        inherit system;
        config.allowUnfree = true;
      };
      bleedingOverlay = final: prev: {
        vector = bleedingPkgs.vector;
      };
      localOverlay = final: prev: {
        infra-flake-update = final.callPackage ./pkgs/infra-flake-update.nix { };
      };
    in
    {
      packages.${system}.infra-flake-update =
        nixpkgs.legacyPackages.${system}.callPackage ./pkgs/infra-flake-update.nix { };

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
          { nixpkgs.overlays = [ bleedingOverlay localOverlay ]; }
          sops-nix.nixosModules.sops
          microvm.nixosModules.host

          ./MOTHER/configuration.nix

          {
            networking.hostName = "MOTHER";
            microvm.autostart = ["UCHI" "SOTO" "DARE" "OKAMI" "KAIZOKU" "MAMORU" "NIKKI"];
            microvm.vms.UCHI = { flake = UCHI; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/UCHI"; };
            microvm.vms.SOTO = { flake = SOTO; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/SOTO"; };
            microvm.vms.DARE = { flake = DARE; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/DARE"; };
            microvm.vms.KAIZOKU = { flake = KAIZOKU; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/KAIZOKU"; };
            microvm.vms.OKAMI = { flake = OKAMI; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/OKAMI"; };
            microvm.vms.MAMORU = { flake = MAMORU; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/MAMORU"; };
            microvm.vms.NIKKI = { flake = NIKKI; updateFlake = "git+file:///root/dotfiles/?dir=nix/vm/NIKKI"; };
          }
        ];
      };
      nixosConfigurations.UCHI = UCHI.nixosConfigurations.UCHI;
      nixosConfigurations.SOTO = SOTO.nixosConfigurations.SOTO;
      nixosConfigurations.DARE = DARE.nixosConfigurations.DARE;
      nixosConfigurations.KAIZOKU = KAIZOKU.nixosConfigurations.KAIZOKU;
      nixosConfigurations.OKAMI = OKAMI.nixosConfigurations.OKAMI;
      nixosConfigurations.MAMORU = MAMORU.nixosConfigurations.MAMORU;
      nixosConfigurations.NIKKI = NIKKI.nixosConfigurations.NIKKI;
    };
}
