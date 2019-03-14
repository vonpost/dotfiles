{ mkDerivation, array, attoparsec, base, bytestring, Cabal
, containers, exceptions, llvm_7, llvm-hs-pure, mtl
, pretty-show, process, QuickCheck, stdenv, tasty, tasty-hunit
, tasty-quickcheck, template-haskell, temporary, transformers
, utf8-string
}:
mkDerivation {
  pname = "llvm-hs";
  version = "7.0.1";
  src = ./.;
  revision = "1";
  editedCabalFile = "0nxyjcnsph4mlyxqy47m67ayd4mnpxx3agy5vx7f4v74bg4xx44a";
  setupHaskellDepends = [ base Cabal containers ];
  libraryHaskellDepends = [
    array attoparsec base bytestring containers exceptions llvm-hs-pure
    mtl template-haskell transformers utf8-string
  ];
  libraryToolDepends = [ llvm_7 ];
  testHaskellDepends = [
    base bytestring containers llvm-hs-pure mtl pretty-show process
    QuickCheck tasty tasty-hunit tasty-quickcheck temporary
    transformers
  ];
  homepage = "http://github.com/llvm-hs/llvm-hs/";
  description = "General purpose LLVM bindings";
  license = stdenv.lib.licenses.bsd3;
}
