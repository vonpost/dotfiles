# Infrastructure checks

Log-digest behavior and safety tests run offline, without contacting the fleet:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/infra -p 'test_log_digest*.py' -v
```

They are also exposed as `checks.x86_64-linux.infra-log-digest`. The observability
suite includes the overnight schedules, GPU window dependencies and all three
agent sandbox contracts. Python cases cover malformed model plans, backend syntax
errors and correction, CPU-only execution, trigger transitions, quotas and durable
evidence. See [overnight operation](../../plans/log-digest-overnight.md).

The evidence, notebook, investigation and reporting suites additionally cover
FFmpeg command noise, incomplete collection, material volume changes, historical
report continuity, calibrated urgency/recovery, query quoting and duplicate tasks.
The comparison and hypothesis-test suites cover adjacent-window normalization,
predictions saved before reads, numerical verdicts, bounded case history, interrupted
tests, historical query timestamps and useful results surviving failed synthesis.
Use discovery as above so these separate regression files also run locally.

Keep binary-cache access enabled when building the packaged checks. Carrying
`--offline` from an evaluation command into `nix build` can force a full compiler
bootstrap when the build environment is not already in the local store.

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
    infra-state=null; infra-cache-shares=null; infra-inventory=null; infra-roles=null;
    infra-observability=null; infra-network=null;
  } checks)'
```

Evaluation forces the contracts across six suites; their returned derivations
only write success markers. The nine state checks cover share count/order,
host/guest bind agreement, service assignment and state-path overrides,
independent UID/GID overrides, tmpfiles ownership, stateless guests, the legacy
staging option alias, and moving/removing SABnzbd assignments through modules.

The other suites cover inventory identity/resources/autostart; worker/server
roles and credential assignment; dashboards and journal collection; primary
network ordering, endpoint overrides and generated network policy.

The fixtures extend actual configurations. They are never deployment targets.

## Transcode share regression

The ten `infra-cache-shares` contracts check the dedicated uncached exports,
cached database storage, mount ordering, host provisioning, service/path/owner
overrides, and moving the Jellyfin role to another VM.

The runtime check boots a disposable VM with the real SOTO mount definitions
and four independent VirtioFS connections to scratch data. It first reproduces
stale zero-byte metadata with the original state share's cache policy, then verifies
immediate visibility through the two uncached connections, SQLite WAL on the
cached database mount, and real FFmpeg fMP4 initialization at segment readiness.

```sh
nix --extra-experimental-features 'nix-command flakes' build \
  --no-link --no-write-lock-file --option builders '' --max-jobs 2 --cores 2 \
  "path:$(pwd)#checks.x86_64-linux.infra-cache-shares-runtime"
```

This uses local resources and supports QEMU TCG when KVM is unavailable. It does
not contact MOTHER or test the production GPU, HTTP server, or affected browser.

## Deployment and packet tests

```sh
python3 tests/infra/test_deploy.py -v
nix --extra-experimental-features 'nix-command flakes' build \
  --no-link --option builders '' "path:$(pwd)#checks.x86_64-linux.infra-deploy" \
  "path:$(pwd)#packages.x86_64-linux.infra"
```

The 18 deployment tests run the real shell script with inert Nix/SSH commands.
They cover exact candidate activation, source archiving, validation before
transfer, failures before/after arming, preserving recovery, vsock health
checks, separating DNS/router rollout, scoped pin updates, and fetching laptop
inputs as the calling user while elevating only activation. The package
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

## Laptop checks

The fleet flake does not include TERRA. Changes to shared modules or laptop
deployment must also evaluate the separate laptop configuration. In particular,
`secrets/TERRA_wg_settings.nix` imports `common/wg_client_systemd.nix`; an import
search that excludes submodules cannot establish that a shared module is unused.

Run as the normal user, whose SSH credentials can fetch the private submodule:

```sh
nix --extra-experimental-features 'nix-command flakes' eval \
  --raw --no-write-lock-file --option builders '' \
  --option allow-import-from-derivation false \
  "git+file://$(git rev-parse --show-toplevel)?dir=nix/laptop#nixosConfigurations.TERRA.config.system.build.toplevel.drvPath"
```

This evaluates the complete configuration without building or activating it.
`infra deploy terra` similarly keeps fetching and building as the caller, using
`nixos-rebuild --sudo` for the privileged activation steps.

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
