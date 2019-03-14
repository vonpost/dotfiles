self: super:
let
  lib = super.haskell.lib;
  addPkg = path: rest: lib.dontCheck (lib.dontHaddock (self.haskellPackages.callPackage path rest));
in 
{
  parsec = super.callPackage ../derivations/parsec/default.nix {};
  haskellPackages =  super.haskellPackages.extend(h-sel: h-sup:  {
  mkDerivation = expr: h-sup.mkDerivation (expr // { enableLibraryProfiling = true; });
  llvm-hs = addPkg ../haskell/llvm-hs/llvm-hs.nix {};
  accelerate = addPkg ../haskell/accelerate/accelerate-debug-profile.nix {};
  accelerate-llvm = addPkg ../haskell/accelerate-llvm/accelerate-llvm.nix {};
  accelerate-llvm-native = addPkg ../haskell/accelerate-llvm-native/accelerate-llvm-native.nix {};
  });
  

 ghc = self.haskellPackages.ghcWithPackages
        (haskellPackages: with haskellPackages; [ categories
         accelerate accelerate-llvm accelerate-llvm-native
         ]);
}

