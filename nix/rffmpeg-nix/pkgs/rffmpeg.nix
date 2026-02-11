{ pkgs, lib, fetchFromGitHub, python3 }:

let
  pythonEnv = python3.withPackages (ps: with ps; [
    click
    pyyaml
    psycopg2
  ]);
in
pkgs.python3Packages.buildPythonApplication rec {
  pname = "rffmpeg";
  version = "0.1";
  pyproject = false;

  src = fetchFromGitHub {
    owner = "joshuaboniface";
    repo = "rffmpeg";
    rev = "master";
    hash = "sha256-UI//X2L6sGWVllfNrRzHrlF4yG+83eldXYVBMrgQqiM=";
  };

  # Critical: avoid Nix-generated Python entrypoint wrappers
  dontWrapPythonPrograms = true;

  # We’re going to run using pythonEnv directly, so no need to propagate deps here.
  propagatedBuildInputs = [ ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin

    install -m 755 rffmpeg $out/bin/rffmpeg

    # Force the interpreter to one that includes click/pyyaml/psycopg2
    substituteInPlace $out/bin/rffmpeg \
      --replace "#!/usr/bin/env python3" "#!${pythonEnv}/bin/python3" \
      --replace "#!/usr/bin/python3" "#!${pythonEnv}/bin/python3" \
      --replace "#!/usr/bin/env python"  "#!${pythonEnv}/bin/python3" \
      --replace "#!/usr/bin/python"      "#!${pythonEnv}/bin/python3"
    substituteInPlace $out/bin/rffmpeg \
      --replace 'if "rffmpeg" in cmd_name:' 'if os.path.basename(cmd_name) == "rffmpeg":'

    # Preserve $0-based emulation via symlinks (no wrapper involved)
    ln -s rffmpeg $out/bin/ffmpeg
    ln -s rffmpeg $out/bin/ffprobe

    runHook postInstall
  '';

  meta = with lib; {
    description = "Remote SSH FFmpeg wrapper (for Jellyfin remote transcoding)";
    homepage = "https://github.com/joshuaboniface/rffmpeg";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
  };
}
