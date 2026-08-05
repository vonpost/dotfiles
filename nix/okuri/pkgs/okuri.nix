{ lib, stdenvNoCC, python3, runtimeShell }:

stdenvNoCC.mkDerivation {
  pname = "okuri";
  version = "1.0";

  src = ../src;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${python3}/bin/python3 -m unittest discover -s . -p 'test_*.py'
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/okuri $out/bin
    install -m 644 rewrite.py runtime.py controller.py target.py $out/lib/okuri/

    for role in ffmpeg ffprobe; do
      cat > $out/bin/$role <<EOF
    #!${runtimeShell}
    export OKURI_ROLE=$role
    exec ${python3}/bin/python3 $out/lib/okuri/controller.py "\$@"
    EOF
    done

    cat > $out/bin/okuri <<EOF
    #!${runtimeShell}
    exec ${python3}/bin/python3 $out/lib/okuri/controller.py "\$@"
    EOF

    cat > $out/bin/okuri-target <<EOF
    #!${runtimeShell}
    exec ${python3}/bin/python3 $out/lib/okuri/target.py "\$@"
    EOF

    chmod 755 $out/bin/*
    runHook postInstall
  '';

  meta = with lib; {
    description = "Remote GPU transcode dispatcher for Jellyfin with CPU fallback (rffmpeg replacement)";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
