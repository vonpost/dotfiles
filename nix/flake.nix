{
  description = "NixOS configuration (flake)";
  inputs =
        {
          self.submodules = true;
          nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
          # MOTHER is headless; a bad nixpkgs bump can cost physical access.
          # Its pin moves only via `infra update mother`, never with the
          # fleet's nixpkgs.
          nixpkgs-mother.url = "github:NixOS/nixpkgs/nixos-unstable";
          bleeding.url = "github:NixOS/nixpkgs/master";
          sops-nix.url = "github:Mic92/sops-nix";
          sops-nix.inputs.nixpkgs.follows = "nixpkgs";
          microvm.url = "github:microvm-nix/microvm.nix";
          microvm.inputs.nixpkgs.follows = "nixpkgs";
          quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
          rffmpeg-nix.url = ./rffmpeg-nix;
          wolf.url = ./wolf-nix;
        };

  # Wolf/OKAMI pulls CUDA packages; without this cache they build from source.
  nixConfig = {
    extra-substituters = [
      "https://cuda-maintainers.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
    ];
  };

  outputs =
    { self,
      nixpkgs,
      nixpkgs-mother,
      bleeding,
      sops-nix,
      microvm,
      quadlet-nix,
      rffmpeg-nix,
      wolf,
      ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      bleedingPkgs = import bleeding {
        inherit system;
        config.allowUnfree = true;
      };
      bleedingOverlay = final: prev: {
        vector = bleedingPkgs.vector;
      };
      localOverlay = final: prev: {
        infra = final.callPackage ./pkgs/infra.nix { };
      };

      vmNames = [ "UCHI" "SOTO" "KAIZOKU" "DARE" "OKAMI" "MAMORU" "NIKKI" ];

      # Per-VM module additions that fall outside the shared service pattern.
      # OKAMI hosts wolf, which is not yet a pure catalog service.
      vmExtraModules = {
        OKAMI = [
          quadlet-nix.nixosModules.quadlet
          ./wolf-nix/modules/wolf-service.nix
        ];
      };

      mkVm = name: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          bleeding = bleedingPkgs;
        };
        modules = [
          { nixpkgs.overlays = [ bleedingOverlay ]; }
          microvm.nixosModules.microvm
          (./config/infra/vms + "/${name}.nix")
        ] ++ (vmExtraModules.${name} or [ ]);
      };
    in
    {
      packages.${system}.infra =
        nixpkgs.legacyPackages.${system}.callPackage ./pkgs/infra.nix { };

      nixosConfigurations = lib.genAttrs vmNames mkVm // {
        MOTHER = nixpkgs-mother.lib.nixosSystem {
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
              microvm.autostart = vmNames;
              microvm.vms = lib.genAttrs vmNames (name: {
                flake = self;
                updateFlake = "git+file:///root/dotfiles?dir=nix";
              });
            }
          ];
        };
      };

      # Evaluate/build every system closure: nix flake check --no-build for a
      # fast eval-only pass, or plain nix flake check to build everything.
      checks.${system} = lib.genAttrs (vmNames ++ [ "MOTHER" ]) (name:
        self.nixosConfigurations.${name}.config.system.build.toplevel
      );
    };
}
