# { stdenv, fetchurl, makeWrapper
# , dpkg, patchelf
# , libX11, SDL, libGL 
# , libva }
let pkgs = import ~/nixpkgs {};
in
with pkgs;
let
  inherit (stdenv) lib;
  tail = lib.makeLibraryPath
    [stdenv.cc.cc xlibs.libX11 libGL libudev libva pulseaudio];
  opengl="/run/opengl-driver/lib:/run/opengl-driver/lib32";
in
stdenv.mkDerivation rec {
  name = "parsec";

  src = fetchurl {
      url = "https://s3.amazonaws.com/parsec-build/package/parsec-linux.deb";
      sha256 = "0wx2nchjr0cbd8a9wdq38wf6kiyxw6892gda4a69w670pqg9bvdy";
    };

  buildInputs = [ dpkg ];

  nativeBuildInputs = [ makeWrapper ];

  unpackPhase = ''
    dpkg -X $src .
  '';

  installPhase = ''
    mkdir $out
    cp -r usr/* $out
    patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" $out/bin/parsecd
    wrapProgram $out/bin/parsecd --set LD_LIBRARY_PATH ${opengl}:${tail}
    '';

  meta = with stdenv.lib; {
    description = "An application for playing games remotely";
    homepage = https://parsecgaming.com/;
    license = licenses.unfree;
    platforms = ["x86_64-linux" ];
  };
}
