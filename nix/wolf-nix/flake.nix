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
        ({
          inherit (pkgs) wolf;
          inherit (imagePackages)
            wolfBaseImage
            wolfBaseAppImage
            wolfFirefoxImage
            wolfFirefoxNixosImage
            wolfFirefoxWolfConfig;
          "wolf-base-image" = imagePackages.wolfBaseImage;
          "wolf-base-app-image" = imagePackages.wolfBaseAppImage;
          "wolf-firefox-image" = imagePackages.wolfFirefoxImage;
          "wolf-firefox-nixos-image" = imagePackages.wolfFirefoxNixosImage;
          "wolf-firefox-config" = imagePackages.wolfFirefoxWolfConfig;
          default = pkgs.wolf;
        }
        // lib.optionalAttrs (imagePackages ? wolfSteamImage) {
          inherit (imagePackages)
            wolfSteamImage
            wolfSteamWolfConfig;
          "wolf-steam-image" = imagePackages.wolfSteamImage;
          "wolf-steam-config" = imagePackages.wolfSteamWolfConfig;
        })
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
