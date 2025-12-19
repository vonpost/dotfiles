{
  description = "NixOS configuration (flake)";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bleeding.url = "github:NixOS/nixpkgs/master";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";

  };

  outputs =
    { self, nixpkgs, bleeding, nixos-hardware, sops-nix, microvm, ... }:
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
          ./MOTHER/contain-qbit-mullvad.nix
          ./MOTHER/contain-vpn.nix

          {
            networking.hostName = "MOTHER";
            microvm.autostart = [
              "UCHI"
              #"SOTO"
            ];
            microvm.stateDir = "/aleph/vm-pool/microvm";

            microvm.vms.UCHI = {
              pkgs = import nixpkgs { system = "x86_64-linux"; };
              config = {
                microvm.hypervisor = "cloud-hypervisor";

                microvm.shares = [
                  {
                    proto = "virtiofs";
                    tag = "ro-store";
                    source = "/nix/store";
                    mountPoint = "/nix/.ro-store";
                  }
                ];
                microvm.binScripts.tap-up = lib.mkAfter ''
                  ${lib.getExe' pkgs.iproute2 "ip"} link set dev vm-myvm up
                  ${lib.getExe' pkgs.iproute2 "ip"} link set dev vm-myvm master br0
                '';

                microvm.interfaces = [
                  {
                    type = "tap";
                    id = "vm-UCHI";
                    mac = "02:00:00:00:00:01";
                  }
                ];

                services.openssh.enable = true;
                users.users.root.openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDG2YxFYwcWwrsS0TecE+6wPLGzerQAbVDyKy4HvSev+ ed25519-key-20221208"
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBarHkA8npoU1VmJPcRIdAAIdvQN7E1D+a+LXp7hmg daniel.j.collin@gmail.com"
            ];
                networking.firewall.enable = false;
                networking.useHostResolvConf = false;
                networking.enableIPv6 = false;
                networking.hostName = "UCHI";
                networking.useDHCP = true;



                services.jellyfin = {
                  enable = true;
                };
              };
            };
            #extraModules = [];
          }
        ];
      };
    };
}
