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

      inventory = import ./config/infra/inventory.nix;
      vmNames = let names = map (vm: vm.name) inventory;
        in assert lib.assertMsg (builtins.length names == builtins.length (lib.unique names))
          "Duplicate VM names in config/infra/inventory.nix"; names;
      vms = lib.listToAttrs (map (vm: lib.nameValuePair vm.name vm) inventory);

      mkVm = name: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit quadlet-nix;
          bleeding = bleedingPkgs;
        };
        modules = [
          { nixpkgs.overlays = [ bleedingOverlay ]; }
          microvm.nixosModules.microvm
          (import ./common/vm-common.nix { hostname = name; })
        ] ++ (vms.${name}.modules or [ ]);
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
      ) // (
        let pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: { okuri = final.callPackage ./okuri/pkgs/okuri.nix { }; })
          ];
        };
          infraCheck = name:
            let results = import (./tests/infra + "/${name}.nix") {
              inherit lib;
              inherit (self) nixosConfigurations;
            };
            in builtins.deepSeq results (pkgs.runCommand "infra-${name}-check" { } ''
              echo 'Infrastructure ${name} contract passed' > "$out"
            '');
        in {
          infra-state = infraCheck "state";
          infra-inventory = infraCheck "inventory";
          infra-roles = infraCheck "roles";
          infra-observability = infraCheck "observability";
          infra-network = infraCheck "network";
          infra-deploy = pkgs.runCommand "infra-deploy-check" {
            nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.jq pkgs.coreutils pkgs.gnugrep ];
            INFRA_TEST_SCRIPT = ./lib/infra.sh;
          } ''
            python ${./tests/infra/test_deploy.py}
            touch "$out"
          '';
          okuri-unit = pkgs.okuri;
          okuri-integration =
            pkgs.testers.runNixOSTest (import ./okuri/tests/integration.nix);
        }
      );
    };
}
