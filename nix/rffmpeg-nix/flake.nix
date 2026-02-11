{
  description = "rffmpeg on NixOS (Jellyfin remote transcoding wrapper)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      overlays.default = final: prev: {
        rffmpeg = prev.callPackage ./pkgs/rffmpeg.nix { };
      };

      nixosModules.rffmpeg = import ./nixos-modules/rffmpeg.nix;

      packages = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        in { inherit (pkgs) rffmpeg; }
      );
    };
}
