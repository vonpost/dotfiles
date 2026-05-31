# MOTHER

## Flake updates

Use `infra-flake-update` to keep root/MOTHER updates separate from VM updates.

```sh
infra-flake-update mother
infra-flake-update -R mother
infra-flake-update --remote root@mother.lan -R mother
infra-flake-update terra
infra-flake-update -R terra
infra-flake-update vm DARE
infra-flake-update -R vm DARE
infra-flake-update --remote root@mother.lan -R vm DARE
infra-flake-update vm DARE bleeding
infra-flake-update list
```

`mother` updates only the root inputs used by MOTHER by default. `vm <name>`
updates that VM's standalone flake and then refreshes only the matching VM input
in the root lock, preserving declarative fresh installs without updating every VM.
`terra` updates the standalone laptop flake. Pass `-R` to apply the update
immediately: `nixos-rebuild switch` for MOTHER or TERRA, or `microvm -Ru <name>`
for a VM.
Pass `--remote root@mother.lan` from TERRA to rsync the local checkout to
MOTHER after the lock update; with `-R`, the apply step runs on MOTHER.
