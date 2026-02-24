{
  description = "Standalone Wolf package and NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
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
        in
        {
          inherit (pkgs) wolf;
          default = pkgs.wolf;
        }
      );

      nixosModules.wolf = import ./modules/wolf-service.nix;
      nixosModules.default = self.nixosModules.wolf;
    };
}
