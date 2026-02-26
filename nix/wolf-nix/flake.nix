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
            wolfFirefoxImage
            wolfFirefoxNixosImage
            wolfFirefoxScratchImage
            wolfNvidiaBundleImage
            wolfFirefoxWolfConfig;
          "wolf-base-image" = imagePackages.wolfBaseImage;
          "wolf-base-app-image" = imagePackages.wolfBaseAppImage;
          "wolf-firefox-image" = imagePackages.wolfFirefoxImage;
          "wolf-firefox-nixos-image" = imagePackages.wolfFirefoxNixosImage;
          "wolf-firefox-scratch-image" = imagePackages.wolfFirefoxScratchImage;
          "wolf-nvidia-bundle-image" = imagePackages.wolfNvidiaBundleImage;
          "wolf-firefox-config" = imagePackages.wolfFirefoxWolfConfig;
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
