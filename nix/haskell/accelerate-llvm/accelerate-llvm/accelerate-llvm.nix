{ mkDerivation, accelerate, base, bytestring, constraints
, containers, data-default-class, deepseq, directory, dlist
, exceptions, filepath, llvm-hs, llvm-hs-pure, mtl, primitive
, stdenv, template-haskell, unordered-containers, vector
}:
mkDerivation {
  pname = "accelerate-llvm";
  version = "1.3.0.0";
  src = ./.;
  libraryHaskellDepends = [
    accelerate base bytestring constraints containers
    data-default-class deepseq directory dlist exceptions filepath
    llvm-hs llvm-hs-pure mtl primitive template-haskell
    unordered-containers vector
  ];
  description = "Accelerate backend component generating LLVM IR";
  license = stdenv.lib.licenses.bsd3;
}
