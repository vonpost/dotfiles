{ nixpkgs ? import /home/dcol/nixpkgs {}, compiler ? "ghc863" }:
nixpkgs.pkgs.haskell.packages.${compiler}.callPackage ./llvm-hs.nix { }
