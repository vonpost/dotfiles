# MOTHER and microVM operations

Run `infra` from the Nix checkout. `infra --help` describes the full CLI.
Updates and deployments are separate operations:

```sh
infra update                 # Fleet: nixpkgs, bleeding, quadlet-nix
infra update mother          # Only nixpkgs-mother
infra update shared          # microvm and sops-nix: affect host AND guests
infra check                  # Evaluation only; local and remote builds disabled
infra check --build          # Full builds, using configured build resources
```

Keep package updates separate from structural refactors. Review lock changes
before deploying. `infra check` can use cached IFD outputs, but fails if
evaluation needs an uncached source build. Materialize such prerequisites in
a separately planned build. Wolf currently has two source prerequisites.

## Deployment source and activation

```sh
infra deploy NIKKI --keep-deadman # Canary; retain rollback during app checks
infra deploy UCHI            # One application VM
infra deploy vms             # Application VMs only; excludes DARE and MAMORU
infra deploy DARE            # DNS: deploys alone, rollback enabled by default
infra deploy MAMORU          # Router: deploys alone; manual approval required
infra deploy mother          # Host: deploys alone; manual approval required
```

For an initial refactor rollout, use individual targets in the order documented
in `../plans/infra-simplification.md`; the bulk command is not a canary workflow.
An agent must obtain the user's approval before activating MOTHER or MAMORU.
The CLI also prompts on a terminal, but noninteractive use does not prompt.

The CLI archives only the Nix directory and its pinned flake inputs into
MOTHER's Nix store. It uses a `path:` source so new files are included and
unrelated dotfiles submodules are not fetched or synchronized. Uncommitted
changes are included and reported. It builds from that immutable source,
roots the candidate, and activates the exact resulting system or VM runner.
The host checkout at `/root/dotfiles` is no longer synchronized by deployment.

After a healthy VM activation, `/var/lib/microvms/VM/flake` records the archived
source for subsequent manual `microvm` operations. The declarative
`updateFlake` in `flake.nix` remains the bootstrap checkout reference for newly
installed VMs; use `infra deploy` to select a newer archived source.

## Recovery and validation

MOTHER, MAMORU and DARE default to a 30-minute deadman timer. `--deadman=MIN`
enables it for other VMs or changes the window; `--no-deadman` disables it.
An existing active rollback prevents another deployment from replacing it.
Do not run overlapping deployments: orchestration does not provide a global
lock between separate CLI processes.

The candidate builds before the timer is armed. The previous running
generation/runner is rooted before activation. The CLI requires the exact
candidate generation over a fresh SSH connection and, for VMs, the exact
booted runner. MAMORU is probed over vsock through MOTHER. Build failures do
not activate anything; activation or health failures leave rollback armed.
Automatic disarming preserves the old root if stopping recovery fails.

These generation checks are necessary but do not test application health,
DNS, external ingress or storage persistence. Verify those explicitly during
rollout. `--keep-deadman` enables rollback and leaves it armed after generation
checks so these additional checks remain protected. A connection through a
LAN/VPN path does not prove WAN ingress.
The existing MOTHER two-stage rollback/rescue behavior is retained.

```sh
infra status                # Pins, dirty files, timers and VM status
infra disarm                # Explicit cancellation; retains rollback roots
```

Only cancel recovery once the intended services and recovery paths are
verified. `infra disarm` stops timers; it does not stop a rollback service that
has already fired. Inspect active `infra-deadman-*` units before recovery work.

`infra update terra` and `infra deploy terra` continue to use the separate
laptop flake. No infrastructure milestone changes its source layout.
