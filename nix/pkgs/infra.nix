{ coreutils
, git
, jq
, nix
, openssh
, rsync
, writeShellApplication
}:

writeShellApplication {
  name = "infra";

  runtimeInputs = [
    coreutils
    git
    jq
    nix
    openssh
    rsync
  ];

  text = builtins.readFile ../lib/infra.sh;
}
