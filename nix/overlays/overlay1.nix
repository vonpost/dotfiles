self: super:
let
  lib = super.haskell.lib;
  addPkg = path: rest: lib.dontCheck (lib.dontHaddock (self.haskellPackages.callPackage path rest));
in 
{
  parsec = super.callPackage ../derivations/parsec/default.nix {};
  # octave = super.callPackage ../derivations/octave/default.nix {};
  # lutris = super.pythonPackages.callPackage ../derivations/lutris/chrootenv.nix {};
 #  haskellPackages =  super.haskellPackages.extend(h-sel: h-sup:  {
 #  mkDerivation = expr: h-sup.mkDerivation (expr // { enableLibraryProfiling = true; });
 #  llvm-hs = addPkg ../haskell/llvm-hs/llvm-hs.nix {};
 #  accelerate = addPkg ../haskell/accelerate/accelerate.nix {};
 #  accelerate-llvm = addPkg ../haskell/accelerate-llvm/accelerate-llvm/accelerate-llvm.nix {};
 #  accelerate-llvm-native = addPkg ../haskell/accelerate-llvm/accelerate-llvm-native/accelerate-llvm-native.nix {};
 #  accelerate-llvm-ptx = addPkg ../haskell/accelerate-llvm/accelerate-llvm-ptx/accelerate-llvm-ptx.nix {};
 #  accelerate-blas =  addPkg ../haskell/accelerate-blas/accelerate-blas.nix {};
 #  blas-hs = addPkg ../haskell/blas-hs/blas-hs.nix {};
 #  });
  

 # ghc = self.haskellPackages.ghcWithPackages
 #        (haskellPackages: with haskellPackages; [ categories
 #         accelerate accelerate-llvm accelerate-llvm-native backprop
 #         mwc-random-accelerate accelerate-blas lens-accelerate
 #         ghc-typelits-natnormalise ghc-typelits-knownnat
 #         mnist-idx gnuplot
 #         ]);
}

