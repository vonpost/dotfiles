{ lib, stdenvNoCC, fetchFromGitHub, makeWrapper, python3 }:

let
  py = python3.withPackages (ps: with ps; [
    click
    pyyaml
    # Optional (only if you configure postgres in rffmpeg.yml):
    psycopg2
  ]);
in
stdenvNoCC.mkDerivation rec {
  pname = "rffmpeg";
  version = "unstable-2022-07-19";

  src = fetchFromGitHub {
    owner = "joshuaboniface";
    repo = "rffmpeg";
    # Pin this to a commit or tag you prefer
    rev = "master";
    # Fill this in with: nix-prefetch-url --unpack <url>  OR  nix flake lock updates
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -D -m 0755 rffmpeg $out/libexec/rffmpeg

    # Run the script with a known Python + deps
    makeWrapper ${py}/bin/python3 $out/bin/rffmpeg \
      --add-flags $out/libexec/rffmpeg

    # rffmpeg is intended to be invoked as ffmpeg/ffprobe
    ln -s $out/bin/rffmpeg $out/bin/ffmpeg
    ln -s $out/bin/rffmpeg $out/bin/ffprobe

    runHook postInstall
  '';

  meta = with lib; {
    description = "Remote SSH FFmpeg wrapper (for Jellyfin remote transcoding)";
    homepage = "https://github.com/joshuaboniface/rffmpeg";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
  };
}
