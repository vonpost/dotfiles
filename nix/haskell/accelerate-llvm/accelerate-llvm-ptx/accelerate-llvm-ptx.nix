{ mkDerivation, accelerate, accelerate-llvm, base, bytestring
, containers, cuda, deepseq, directory, dlist, file-embed, filepath
, hashable, llvm-hs, llvm-hs-pure, mtl, nvvm, pretty, process
, stdenv, template-haskell, unordered-containers
}:
mkDerivation {
  pname = "accelerate-llvm-ptx";
  version = "1.3.0.0";
  src = ./.;
  libraryHaskellDepends = [
    accelerate accelerate-llvm base bytestring containers cuda deepseq
    directory dlist file-embed filepath hashable llvm-hs llvm-hs-pure
    mtl nvvm pretty process template-haskell unordered-containers
  ];
  testHaskellDepends = [ accelerate base ];
  description = "Accelerate backend for NVIDIA GPUs";
  license = stdenv.lib.licenses.bsd3;
}
