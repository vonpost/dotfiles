{ coreutils
, nix
, openssh
, rsync
, writeShellApplication
}:

writeShellApplication {
  name = "infra-flake-update";

  runtimeInputs = [
    coreutils
    nix
    openssh
    rsync
  ];

  text = builtins.readFile ../lib/infra-flake-update.sh;
}
