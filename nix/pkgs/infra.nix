{ coreutils
, git
, jq
, nix
, openssh
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
  ];

  text = builtins.readFile ../lib/infra.sh;
}
