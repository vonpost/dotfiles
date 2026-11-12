{ lib, appimageTools, fetchurl }:

let
  pname = "wowup-cf";
  # Keep the addon manager current without moving the fleet's nixpkgs pin.
  version = "2.25.4";
  src = fetchurl {
    url = "https://github.com/WowUp/WowUp.CF/releases/download/v${version}/WowUp-CF-${version}.AppImage";
    hash = "sha256-tKOFboaUo1wgLJ2xjLPOyqHrf8Do+oS0ZzL2fcs8Jc4=";
  };
  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;
  extraInstallCommands = ''
    install -Dm444 ${contents}/${pname}.desktop $out/share/applications/${pname}.desktop
    substituteInPlace $out/share/applications/${pname}.desktop \
      --replace-fail 'Exec=AppRun' 'Exec=${pname}'
    cp -r ${contents}/usr/share/icons $out/share
  '';
  meta = {
    description = "World of Warcraft addon manager with CurseForge support";
    homepage = "https://wowup.io/";
    license = lib.licenses.unfree;
    mainProgram = pname;
    platforms = [ "x86_64-linux" ];
  };
}
