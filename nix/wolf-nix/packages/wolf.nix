{ lib, pkgs, maxBuildJobs ? 6, ...}:
with lib;
let
  buildJobs = max 1 maxBuildJobs;

  # Your target Wolf commit
  wolfRev = "ea4a75d59deb9171dde3d21d6beb2785cb69585";
  wolfHash = "sha256-KgBkxL7mIs8TBL3hbkq8tMFRgfo1dDcequ1AE6I2UKQ=";
  interpipeRev = "953db14b1fb97ac1865b95222a2688717a88867d";
  interpipeHash = "sha256-R6M2hH9kzMxPyaEqaWLYfLqlS00aRNhGM8mFj5oBZpI=";
  waylandDisplayRev = "328fbf66c23cdafe5053f0803267e75aef9f7841";
  waylandDisplayHash = "sha256-59gObVHuCsoUlRjVh56je9O5vIgyMVuOuA8YYIUMUW8=";

  # Copying the “deps as sources” idea from the dev-nix flake.
  # These hashes come from that branch’s flake.nix, so they should be correct
  # for those dependency versions. If master changed a dependency/version,
  # CMake will tell you which extra one needs adding.

  fake-udev = pkgs.stdenv.mkDerivation rec {
    pname = "fake-udev";
    version = "1.0";

    src = pkgs.fetchFromGitHub {
      owner = "games-on-whales";
      repo = "wolf";
      rev = wolfRev;
      hash = wolfHash;
      fetchSubmodules = true;
    };
    sourceRoot = "${src.name}/src/fake-udev";

    nativeBuildInputs = with pkgs; [ cmake pkg-config ninja autoPatchelfHook ];

    buildInputs = with pkgs; [ glibc.static ];

    cmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
      "-DCMAKE_CXX_STANDARD=17"
      "-DCMAKE_CXX_EXTENSIONS=OFF"
      "-DBUILD_FAKE_UDEV_CLI=ON"
      "-G Ninja"
    ];

    postPatch = ''
    echo "cmake_minimum_required(VERSION 3.13...3.24)" > newCMake
    cat CMakeLists.txt >> newCMake
    mv newCMake CMakeLists.txt
    '';
    buildPhase = "ninja -j${toString buildJobs} fake-udev";
    installPhase = ''
      mkdir -p $out/bin
      cp ./fake-udev $out/bin/fake-udev
    '';
  };

  gst-interpipe = pkgs.stdenv.mkDerivation rec {
    pname = "gst-interpipe";
    version = "1.1.10-gow-${builtins.substring 0 7 interpipeRev}";

    src = pkgs.fetchFromGitHub {
      owner = "games-on-whales";
      repo = "gst-interpipe";
      rev = interpipeRev;
      hash = interpipeHash;
    };

    nativeBuildInputs = with pkgs; [
      meson
      ninja
      pkg-config
    ];

    buildInputs = with pkgs; [
      glib
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
    ];

    mesonFlags = [
      "-Dtests=disabled"
      "-Denable-gtk-doc=false"
    ];
  };

  gst-wayland-display = pkgs.rustPlatform.buildRustPackage rec {
    pname = "gst-wayland-display";
    version = "0.4.0-${builtins.substring 0 7 waylandDisplayRev}";

    src = pkgs.fetchFromGitHub {
      owner = "games-on-whales";
      repo = "gst-wayland-display";
      rev = waylandDisplayRev;
      hash = waylandDisplayHash;
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      allowBuiltinFetchGit = true;
    };

    postPatch = ''
      # Upstream's `cuda` feature currently does not enable the matching core feature.
      substituteInPlace gst-plugin-wayland-display/Cargo.toml \
        --replace-fail 'cuda = []' 'cuda = ["wayland-display-core/cuda"]'
    '';

    nativeBuildInputs = with pkgs; [
      pkg-config
      wayland-scanner
      rustPlatform.bindgenHook
    ];

    buildInputs = with pkgs; [
      glib
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-bad
      wayland
      wayland-protocols
      libdrm
      libgbm
      libinput
      libxkbcommon
      libglvnd
      udev
    ];

    cargoBuildFlags = [
      "-p"
      "gst-plugin-wayland-display"
      "--features"
      "cuda"
    ];

    CARGO_BUILD_JOBS = toString buildJobs;
    doCheck = false;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/gstreamer-1.0
      plugin_so="$(find target -type f -name 'libgstwaylanddisplaysrc.so' | head -n1)"
      if [ -z "$plugin_so" ]; then
        echo "ERROR: libgstwaylanddisplaysrc.so not found in target/"
        find target -maxdepth 4 -type f -name '*.so*' -print || true
        exit 1
      fi
      cp -v "$plugin_so" $out/lib/gstreamer-1.0/
      # Keep compatibility in case extra wayland-display shared libs are emitted.
      find target -type f -name 'lib*waylanddisplay*.so*' -exec cp -v {} $out/lib/ \; || true
      runHook postInstall
    '';
  };
  deps = with pkgs; {

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
      rev = "11.1.4";
      hash = "sha256-sUbxlYi/Aupaox3JjWFqXIjcaQa0LFjclQAOleT+FRA=";
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
      rev = "44c85e16279553d9c052e572bcbfcd745fb74abf";
      hash = "sha256-lXCZhpy1FgFsUOcdd9fS9HpPZGKW/FTKaKfOOn5J/5g=";
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
      # rev = "e29d43e8ad80d8f22518c69f495ac690a8174393";
      rev = "v0.21.0";
      hash = "sha256-9D16AoQlb6xHFEpNEMMYHbcW3AUFF7BxPliSkGE7YJU=";
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
      rev = "546895a9";
      hash = "sha256-sIuZUqpK8eiPs1wIlE8hJgtynEoYpLxMaWxQGviifME=";
    };
  };

in
pkgs.stdenv.mkDerivation (finalAttrs: rec {
  pname = "wolf";
  version = "1.0-${wolfRev}";
  runtimeLibraryPath = lib.makeLibraryPath ([ pkgs.stdenv.cc.cc ] ++ buildInputs);

  src = pkgs.fetchFromGitHub {
    owner = "games-on-whales";
    repo = "wolf";
    rev = wolfRev;
    hash = wolfHash;
    fetchSubmodules = true;
  };

  nativeBuildInputs = with pkgs; [
    cmake
    pkg-config
    makeWrapper
    ninja
    wrapGAppsHook3
    patchelf
  ];

  buildInputs = with pkgs; [
    openssl
    boost
    icu
    glib
    libevdev
    systemd
    range-v3
    libpulseaudio
    zlib
    zstd
    libglvnd
    ffmpeg_6-full
    libva
    libdrm
    pciutils
    curl
    libunwind
    fake-udev

    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst-interpipe
    gst-wayland-display

    wayland
    wayland-protocols
    libxkbcommon
  ];
  buildPhase = ''
    runHook preBuild
    TERM=dumb ninja -j${toString buildJobs}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    TERM=dumb ninja -j${toString buildJobs} install
    runHook postInstall
  '';
  runtimeInputs = [ fake-udev ];

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
    "-DBUILD_FAKE_UDEV_CLI=OFF"
    "-DBUILD_TESTING=OFF"
    "-DBUILD_TESTING_STATIC=OFF"
    "-DBUILD_TESTING_SHARED=OFF"
    "-G Ninja"

  ];
  postPatch = ''
    serialCfg="src/moonlight-server/state/serialised_config.hpp"
    if ! grep -q '#include <unistd.h>' "$serialCfg"; then
      sed -i '/#include <rfl.hpp>/a #include <unistd.h>' "$serialCfg"
    fi
    substituteInPlace "$serialCfg" \
      --replace-fail 'uint run_uid = 1000;' 'uint run_uid = static_cast<uint>(::getuid());' \
      --replace-fail 'uint run_gid = 1000;' 'uint run_gid = static_cast<uint>(::getgid());'

    # Upstream typo: UpdateClientSettings uses run_gid for both run_uid and run_gid.
    # This breaks explicit UID settings via API/UI.
    substituteInPlace src/moonlight-server/api/endpoints.cpp \
      --replace-fail '.run_uid = new_settings.run_gid.value_or(current_settings.run_uid),' '.run_uid = new_settings.run_uid.value_or(current_settings.run_uid),'

    # 2) Ensure the wolf executable gets installed
    cmakeFile="src/moonlight-server/CMakeLists.txt"
    if ! grep -q "install(TARGETS wolf" "$cmakeFile"; then
      printf '\n# Nix packaging: install the wolf executable\ninstall(TARGETS wolf\n  RUNTIME DESTINATION bin\n)\n' >> "$cmakeFile"
    fi
  '';

  postInstall = ''
    cp -v ${fake-udev}/bin/fake-udev $out/bin/fake-udev
    mkdir -p $out/lib
    mkdir -p $out/lib/gstreamer-1.0
    # Do not preserve source directory permissions from /nix/store (often 0555), or
    # $out/lib/gstreamer-1.0 can become read-only before later copy steps.
    find ${gst-interpipe}/lib/gstreamer-1.0 -mindepth 1 -maxdepth 1 \
      -exec cp -dv --no-preserve=mode,ownership {} $out/lib/gstreamer-1.0/ \;
    find ${gst-wayland-display}/lib/gstreamer-1.0 -mindepth 1 -maxdepth 1 \
      -exec cp -dv --no-preserve=mode,ownership {} $out/lib/gstreamer-1.0/ \;
    find ${gst-wayland-display}/lib -maxdepth 1 -type f -name '*.so*' \
      -exec cp -v --no-preserve=mode,ownership {} $out/lib/ \; || true
    # Wolf's CMake files don't install all runtime .so files; copy build-produced ones.
    find . \( -type f -o -type l \) -name '*.so*' | while IFS= read -r so; do
      cp -av "$so" "$out/lib/"
    done
  '';
  preFixup = ''
    fix_rpath() {
      local elf="$1"
      if patchelf --print-rpath "$elf" >/dev/null 2>&1; then
        patchelf --set-rpath "$out/lib:${runtimeLibraryPath}" "$elf"
      fi
    }

    [ -d "$out/bin" ] && find "$out/bin" -type f | while IFS= read -r f; do
      fix_rpath "$f"
    done
    [ -d "$out/lib" ] && find "$out/lib" -type f | while IFS= read -r f; do
      fix_rpath "$f"
    done
  '';
  postFixup = ''
    fix_rpath_post() {
      local elf="$1"
      if patchelf --print-rpath "$elf" >/dev/null 2>&1; then
        patchelf --set-rpath "$out/lib:${runtimeLibraryPath}" "$elf"
      fi
    }

    [ -d "$out/bin" ] && find "$out/bin" -type f | while IFS= read -r f; do
      fix_rpath_post "$f"
    done
  '';

  # buildPhase = "ninja wolf";
  # installPhase = ''
  #   mkdir -p $out/bin
  #   cp ./src/moonlight-server/wolf $out/bin/wolf
  # '';


  meta = with lib; {
    description = "Wolf streaming server (Games on Whales)";
    homepage = "https://github.com/games-on-whales/wolf";
    license = licenses.mit;
    platforms = platforms.linux;
  };
})
