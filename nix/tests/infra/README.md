# Infrastructure checks

These checks evaluate the real NixOS modules without activating a system. Use a
`path:` flake reference for local checks so unrelated dotfiles Git submodules
are not fetched. Include untracked new Nix files when reviewing the change;
ordinary Git flake references do not include them until tracked.

## Configuration contracts

From the Nix directory:

```sh
nix --extra-experimental-features 'nix-command flakes' eval \
  --offline --no-write-lock-file \
  --option allow-import-from-derivation false --option builders '' \
  --json "path:$(pwd)#checks.x86_64-linux" \
  --apply 'checks: builtins.mapAttrs (_: check: check.drvPath) (builtins.intersectAttrs {
    infra-state=null; infra-inventory=null; infra-roles=null;
    infra-observability=null; infra-network=null;
  } checks)'
```

Evaluation forces 40 contracts across five suites; their returned derivations
only write success markers. The nine state checks cover share count/order,
host/guest bind agreement, service assignment and state-path overrides,
independent UID/GID overrides, tmpfiles ownership, stateless guests, the legacy
staging option alias, and moving/removing SABnzbd assignments through modules.

The other suites cover inventory identity/resources/autostart; worker/server
roles and credential assignment; dashboards and journal collection; primary
network ordering, endpoint overrides and generated network policy.

The fixtures extend actual configurations. They are never deployment targets.

## Deployment and packet tests

```sh
python3 tests/infra/test_deploy.py -v
nix --extra-experimental-features 'nix-command flakes' build \
  --no-link --option builders '' "path:$(pwd)#checks.x86_64-linux.infra-deploy" \
  "path:$(pwd)#packages.x86_64-linux.infra"
```

The 16 deployment tests run the real shell script with inert Nix/SSH commands.
They cover exact candidate activation, source archiving, validation before
transfer, failures before/after arming, preserving recovery, vsock health
checks, separating DNS/router rollout and scoped pin updates. The package
build additionally runs ShellCheck. These are orchestration tests; they do not
constitute a real reboot or timed rollback drill.

The packet test loads the actual generated MAMORU rules into a disposable
rootless network namespace and connects synthetic clients over veth bridges:

```sh
nix --extra-experimental-features 'nix-command flakes' eval \
  --offline --no-write-lock-file --option allow-import-from-derivation false \
  --option builders '' --raw \
  "path:$(pwd)#nixosConfigurations.MAMORU.config.networking.nftables.ruleset" \
  > /tmp/mamoru.nft
python3 tests/infra/test_packets.py /tmp/mamoru.nft
```

It needs `ip`, `nft`, `unshare`, `nsenter` and Python, plus a Linux kernel that
allows user/network namespaces. The test always isolates itself before
configuring interfaces or loading firewall rules. Fifteen cases cover routed
allow/deny, same-segment access, management, TCP/UDP DNS, WAN DNAT, denied WAN
SSH, permitted/denied DMZ egress and IPv6 egress/inter-segment policy.
Guest firewalls, actual DNS responses and physical WAN routing remain separate
runtime checks. This test
runs outside the Nix build sandbox, whose namespace policy varies by host.

## Before/after comparison

Before editing, capture an immutable source snapshot with the existing lock:

```sh
baseline_source=$(nix --extra-experimental-features 'nix-command flakes' \
  flake metadata --offline --no-write-lock-file --json "path:$(pwd)" | jq -r .path)
```

Evaluate the same projection against that source and the candidate. Run these
sequentially to avoid contention on Nix's evaluation cache:

```sh
nix --extra-experimental-features 'nix-command flakes' eval \
  --offline --no-write-lock-file \
  --option allow-import-from-derivation false --option builders '' \
  --json "path:$baseline_source#nixosConfigurations" \
  --apply "$(cat tests/infra/snapshot.nix)" > /tmp/infra-before.json

nix --extra-experimental-features 'nix-command flakes' eval \
  --offline --no-write-lock-file \
  --option allow-import-from-derivation false --option builders '' \
  --json "path:$(pwd)#nixosConfigurations" \
  --apply "$(cat tests/infra/snapshot.nix)" > /tmp/infra-after.json

diff -u <(jq -S . /tmp/infra-before.json) <(jq -S . /tmp/infra-after.json)
```

Keep the baseline source available until the comparison finishes; a store
snapshot can be garbage collected. Keep output files outside the source tree.

The projection covers all eight systems' filesystems, mount dependencies,
tmpfiles rules, user/group IDs, share order, interfaces, rendered networkd
units, selected service settings, firewall/NAT, and kernel parameters/sysctls.
It deliberately excludes VM installer service settings and Wolf service
settings, which force package builds even when selecting identity fields.
OKAMI's mounts, shares, users and networking are still included.

## Limits

Identical snapshots do not establish full closure equality or runtime safety.
Evaluate/build complete system closures and follow the rollout gates in
`plans/infra-simplification.md` before activation.

`--offline` and `--no-build` alone do not prevent builds required during
evaluation (import-from-derivation). The explicit IFD restriction above makes
that failure visible instead of starting builds. The empty builders setting
also prevents these local checks from using the configured remote builder.
Full closure validation may need IFD enabled in a separate, planned build.

Do not use `--offline` for a full build unless the entire closure is already
available: it disables substitution and can trigger extensive source builds.
Inspect `nix build --dry-run --option builders '' ...` first, then use caches
and a bounded local job count for the planned build.
