{
  description = "Standalone Wolf package and NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
  };

  outputs = { self, nixpkgs, quadlet-nix, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      overlays.default = final: prev: {
        wolf = prev.callPackage ./packages/wolf.nix { pkgs = prev; };
      };

      packages = forAllSystems (system:
        let
          lib = nixpkgs.lib;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
          imagePackages = pkgs.callPackage ./packages/images.nix { };
        in
        {
          inherit (pkgs) wolf;
          inherit (imagePackages)
            wolfBaseImage
            wolfBaseAppImage
            wolfStubImage
            wolfKdeImage
            wolfKdeSystem
            wolfKdeWolfConfig;
          "wolf-base-image" = imagePackages.wolfBaseImage;
          "wolf-base-app-image" = imagePackages.wolfBaseAppImage;
          "wolf-stub-image" = imagePackages.wolfStubImage;
          "wolf-kde-image" = imagePackages.wolfKdeImage;
          "wolf-kde-system" = imagePackages.wolfKdeSystem;
          "wolf-kde-config" = imagePackages.wolfKdeWolfConfig;
          default = pkgs.wolf;
        }
      );

      nixosModules.wolf = {
        imports = [
          quadlet-nix.nixosModules.quadlet
          ./modules/wolf-service.nix
        ];
      };
      nixosModules.default = self.nixosModules.wolf;
    };
}
