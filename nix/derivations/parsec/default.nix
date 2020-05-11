{ stdenv, fetchurl, makeWrapper
, dpkg, patchelf
, libX11, libGL 
, libva, xlibs, libudev, pulseaudio}:
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
      sha256 = "1hfdzjd8qiksv336m4s4ban004vhv00cv2j461gc6zrp37s0fwhc";
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
