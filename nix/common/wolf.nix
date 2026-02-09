{ lib, pkgs, ...}:
with lib;
with pkgs;
let
  # Your target Wolf commit
  wolfRev = "ea4a75d59deb9171dde3d21d6beb2785cb69585";
  wolfHash = "sha256-KgBkxL7mIs8TBL3hbkq8tMFRgfo1dDcequ1AE6I2UKQ=";

  # Copying the “deps as sources” idea from the dev-nix flake.
  # These hashes come from that branch’s flake.nix, so they should be correct
  # for those dependency versions. If master changed a dependency/version,
  # CMake will tell you which extra one needs adding.
  deps = {
    boost_json = fetchFromGitHub {
      owner = "boostorg";
      repo = "json";
      rev = "boost-1.75.0";
      hash = "sha256-c/spP97jrs6gfEzsiMpdt8DDP6n1qOQbLduY+1/i424=";
    };

    eventbus = fetchFromGitHub {
      owner = "games-on-whales";
      repo = "eventbus";
      rev = "abb3a48";
      hash = "sha256-LHBsjvZtxid4KIFQclqs2I155J/9UpDR1NhlSFx4OvU=";
    };

    immer = fetchFromGitHub {
      owner = "arximboldi";
      repo = "immer";
      rev = "e02cbd795e9424a8405a8cb01f659ad61c0cbbc7";
      hash = "sha256-buIaXxoJSTbqzsnxpd33BUCQtTGmdd10j1ArQd5rink=";
    };

    inputtino = fetchFromGitHub {
      owner = "games-on-whales";
      repo = "inputtino";
      rev = "fd136cfe492b4375b4507718bcca1f044588fc6f";
      hash = "sha256-snbcjCFyBDqTf/jkxvA3Hvkz7/27fCDT5oWFi2lAQn0=";
    };

    mdns_cpp = fetchFromGitHub {
      owner = "games-on-whales";
      repo = "mdns_cpp";
      rev = "0d57ae3";
      hash = "sha256-mG/Ob5SIqcIyp5r5IpFh8bJOSul1zRzKvrvdfywVwcg=";
    };

    fmtlib = fetchFromGitHub {
      owner = "fmtlib";
      repo = "fmt";
      rev = "11.0.1";
      hash = "sha256-EPidbZxCvysrL64AzbpJDowiNxqy4ii+qwSWAFwf/Ps=";
    };

    range = fetchFromGitHub {
      owner = "ericniebler";
      repo = "range-v3";
      rev = "0.12.0";
      hash = "sha256-bRSX91+ROqG1C3nB9HSQaKgLzOHEFy9mrD2WW3PRBWU=";
    };

    enet = fetchFromGitHub {
      owner = "cgutman";
      repo = "enet";
      rev = "47e42dbf422396ce308a03b5a95ec056f0f0180c";
      hash = "sha256-ZAmkyDpdriEZUt4fs/daQFx5YqPYFTaU2GULWIN1AwI=";
    };

    nanors = fetchFromGitHub {
      owner = "sleepybishop";
      repo = "nanors";
      rev = "19f07b513e924e471cadd141943c1ec4adc8d0e0";
      hash = "sha256-lpEDW5JZmFMPdJlS0/2a4MZU68dt7lz633ymbuSUyBc=";
    };

    peglib = fetchFromGitHub {
      owner = "yhirose";
      repo = "cpp-peglib";
      rev = "v1.8.5";
      hash = "sha256-GeQQGJtxyoLAXrzplHbf2BORtRoTWrU08TWjjq7YqqE=";
    };

    tomlplusplus = fetchFromGitHub {
      owner = "marzer";
      repo = "tomlplusplus";
      rev = "v3.4.0";
      hash = "sha256-h5tbO0Rv2tZezY58yUbyRVpsfRjY3i+5TPkkxr6La8M=";
    };

    cpptrace = fetchFromGitHub {
      owner = "jeremy-rifkin";
      repo = "cpptrace";
      rev = "448c325";
      hash = "sha256-JGwRhmsd0xiHkK0JW0AUvWAnJA9UztK2wQ+c5aq2y6E=";
    };

    reflect_cpp = fetchFromGitHub {
      owner = "getml";
      repo = "reflect-cpp";
      rev = "e29d43e8ad80d8f22518c69f495ac690a8174393";
      hash = "sha256-eHOgPF/aNdnLaZwvoVdW0Sv6NIv3oHrBIBgq5/to/io=";
    };

    libdwarf_lite = fetchFromGitHub {
      owner = "jeremy-rifkin";
      repo = "libdwarf-lite";
      rev = "v0.11.0";
      hash = "sha256-S2KDfWqqdQfK5+eQny2X5k0A5u9npkQ8OFRLBmTulao=";
    };

    simplewebserver = fetchFromGitLab {
      owner = "eidheim";
      repo = "Simple-Web-Server";
      rev = "bdb1057";
      hash = "sha256-C9i/CyQG9QsDqIx75FbgiKp2b/POigUw71vh+rXAdyg=";
    };
  };

in
stdenv.mkDerivation (finalAttrs: {
  pname = "wolf";
  version = wolfRev;

  src = fetchFromGitHub {
    owner = "games-on-whales";
    repo = "wolf";
    rev = wolfRev;
    hash = wolfHash;
    fetchSubmodules = true;
  };

  nativeBuildInputs = [
    cmake
    pkg-config
    makeWrapper
    ninja
    wrapGAppsHook3
    go
    patchelf
  ];

  buildInputs = [
    openssl
    boost
    icu
    fmt
    range-v3
    enet
    libevdev
    systemd
    libpulseaudio
    ffmpeg_6-full
    libva
    libdrm
    pciutils
    curl
    libunwind

    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly

    wayland
    wayland-protocols
    libxkbcommon
  ];

  # Don’t patch out FetchContent.
  # Instead, make it “offline” by providing source directories for each dependency.
  #
  # This is the idiomatic way to make FetchContent work in Nix builds,
  # and it directly addresses the CMP0170 errors you saw.
  cmakeFlags = [
    # "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    # "-DCMAKE_POLICY_DEFAULT_CMP0170=NEW"
    # "-DOPENSSL_ROOT_DIR=${openssl.dev}"
    "-DCMAKE_POLICY_VERSION_MINIMUM='3.5'"
    # strongly recommended for Nix builds:
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DFETCHCONTENT_UPDATES_DISCONNECTED=ON"


    # FetchContent source overrides (CMake supports FETCHCONTENT_SOURCE_DIR_<NAME>)
    "-DFETCHCONTENT_SOURCE_DIR_BOOST_JSON=${deps.boost_json}"
    "-DFETCHCONTENT_SOURCE_DIR_EVENTBUS=${deps.eventbus}"
    "-DFETCHCONTENT_SOURCE_DIR_IMMER=${deps.immer}"
    "-DFETCHCONTENT_SOURCE_DIR_INPUTTINO=${deps.inputtino}"
    "-DFETCHCONTENT_SOURCE_DIR_MDNS_CPP=${deps.mdns_cpp}"
    "-DFETCHCONTENT_SOURCE_DIR_FMTLIB=${deps.fmtlib}"
    "-DFETCHCONTENT_SOURCE_DIR_RANGE=${deps.range}"
    "-DFETCHCONTENT_SOURCE_DIR_ENET=${deps.enet}"
    "-DFETCHCONTENT_SOURCE_DIR_NANORS=${deps.nanors}"
    "-DFETCHCONTENT_SOURCE_DIR_PEGLIB=${deps.peglib}"
    "-DFETCHCONTENT_SOURCE_DIR_CPPTRACE=${deps.cpptrace}"
   "-DFETCHCONTENT_SOURCE_DIR_LIBDWARF=${deps.libdwarf_lite}"
    "-DFETCHCONTENT_SOURCE_DIR_SIMPLEWEBSERVER=${deps.simplewebserver}"
    "-DFETCHCONTENT_SOURCE_DIR_REFLECT-CPP=${deps.reflect_cpp}"
    "-DFETCHCONTENT_SOURCE_DIR_TOMLPLUSPLUS=${deps.tomlplusplus}"

    "-DBUILD_SHARED_LIBS=ON"

    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_CXX_STANDARD=17"
    "-DCMAKE_CXX_EXTENSIONS=OFF"
    "-DBUILD_FAKE_UDEV_CLI=ON"
    "-DBUILD_TESTING=OFF"
    "-G Ninja"

  ];
  postPatch = ''
    # 1) Patch fake-udev: remove explicit -static (dynamic linking in Nix)
    # Use --replace-warn to avoid deprecated --replace warning.
    substituteInPlace src/fake-udev/CMakeLists.txt \
      --replace-warn "-static" ""

    # 2) Ensure the wolf executable gets installed
    cmakeFile="src/moonlight-server/CMakeLists.txt"
    if ! grep -q "install(TARGETS wolf" "$cmakeFile"; then
      printf '\n# Nix packaging: install the wolf executable\ninstall(TARGETS wolf\n  RUNTIME DESTINATION bin\n)\n' >> "$cmakeFile"
    fi
  '';

postInstall = ''
  mkdir -p $out/lib
  find "$cmakeBuildDir" -maxdepth 5 -type f -name "libwolf_*.so*" -exec cp -v {} $out/lib/ \; || true
'';
postFixup = ''
  patchelf --set-rpath "$out/lib" "$out/bin/wolf" || true
'';


  # installPhase = ''
  # cmake --install
  # '';

  meta = with lib; {
    description = "Wolf streaming server (Games on Whales)";
    homepage = "https://github.com/games-on-whales/wolf";
    license = licenses.mit;
    platforms = platforms.linux;
  };
})
