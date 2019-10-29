{ mkDerivation, base, openblasCompat, stdenv, storable-complex
, vector
}:
mkDerivation {
  pname = "blas-hs";
  version = "0.1.1.0";
  src = ./.;
  configureFlags = [ "-fopenblas" ];
  libraryHaskellDepends = [ base storable-complex ];
  librarySystemDepends = [ openblasCompat ];
  testHaskellDepends = [ base vector ];
  homepage = "https://github.com/Rufflewind/blas-hs";
  description = "Low-level Haskell bindings to Blas";
  license = stdenv.lib.licenses.mit;
}
