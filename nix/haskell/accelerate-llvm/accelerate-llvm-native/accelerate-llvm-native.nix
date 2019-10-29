{ mkDerivation, accelerate, accelerate-llvm, base, bytestring, c2hs
, Cabal, cereal, containers, deepseq, directory, dlist, filepath
, ghc, ghc-prim, hashable, libffi, llvm-hs, llvm-hs-pure
, lockfree-queue, mtl, stdenv, template-haskell, unique, unix
, vector
}:
mkDerivation {
  pname = "accelerate-llvm-native";
  version = "1.3.0.0";
  src = ./.;
  libraryHaskellDepends = [
    accelerate accelerate-llvm base bytestring Cabal cereal containers
    deepseq directory dlist filepath ghc ghc-prim hashable libffi
    llvm-hs llvm-hs-pure lockfree-queue mtl template-haskell unique
    unix vector
  ];
  libraryToolDepends = [ c2hs ];
  testHaskellDepends = [ accelerate base ];
  description = "Accelerate backend for multicore CPUs";
  license = stdenv.lib.licenses.bsd3;
}
