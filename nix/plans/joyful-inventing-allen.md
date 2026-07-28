# Single-flake migration — deployment rollout

## Context

The repo has been migrated from 8 flakes (root + 7 per-VM under `nix/vm/`) to a
single root flake. Motivations: eliminate the dual dependency-resolution paths
(root-lock vs per-VM-lock builds of the same VM), unify update history in one
`flake.lock`, delete 7 boilerplate flakes, and enable store sharing across VMs.
The two reasons the split existed are preserved by other means:

- **Rebuild a VM without rebuilding MOTHER** — `microvm -Ru NAME` builds from
  the updateFlake ref (`git+file:///root/dotfiles?dir=nix`), independent of
  MOTHER's system generation.
- **MOTHER lockout protection** — MOTHER builds from a dedicated
  `nixpkgs-mother` input in the same lock, currently pinned to the exact rev
  MOTHER runs today (`a799d3e`, 2026-06-06). Fleet updates (`infra-flake-update
  fleet`) can never move it; only `infra-flake-update mother` does.

## Already done locally (uncommitted, in working tree)

- `nix/flake.nix` — rewritten: all 7 VMs via `genAttrs`/`mkVm`, OKAMI's quirks
  (quadlet-nix, wolf-service module, cuda cachix `nixConfig`) carried over,
  `nixpkgs-mother` for MOTHER, `checks` output for all 8 systems.
- `nix/vm/` — deleted (staged with `git rm`).
- `nix/flake.lock` — regenerated: 7 VM input trees removed, `quadlet-nix` and
  `nixpkgs-mother` added (`nixpkgs-mother` locked at `a799d3e`, tracking
  `nixos-unstable` for future updates).
- `nix/lib/infra-flake-update.sh` — `mother` now updates `nixpkgs-mother
  sops-nix microvm`; new `fleet` command updates `nixpkgs bleeding quadlet-nix`;
  `vm NAME` is deploy-only; `list` reads VM names from the flake.
- (Earlier, same session) `nix/lib/vm-service-state.nix` — `UMask=0027` for
  media-writing services.

Validated: all 8 `nixosConfigurations` evaluate (`system.build.toplevel`
drvPaths). MOTHER's own stack is version-identical (same nixpkgs rev); its
toplevel drv differs only because the embedded VM runners now build from the
fleet pin.

## Rollout steps

1. **Review + commit + push** the working tree (user reviews diff first).
2. **Sync to MOTHER** — existing flow: `rsync` of the dotfiles checkout (or
   `infra-flake-update --remote root@mother.lan mother` with no input changes —
   it syncs). Commit must be in the checkout MOTHER builds from, since
   `git+file` builds from HEAD, not the dirty tree.
3. **Rebuild MOTHER**: `nixos-rebuild switch --flake /root/dotfiles/nix#MOTHER`.
   Low risk (same nixpkgs rev for MOTHER's own stack) but will *build* all 7 VM
   runners at the fleet pin — expect a long build, incl. OKAMI's
   nvidia/CUDA closure (cachix configured). Run when convenient.
4. **One-time fix of stored update refs** on MOTHER (declarative creation only
   writes these on first creation; the old refs point at deleted
   `?dir=nix/vm/<NAME>` paths and would fail loudly, not silently):
   ```
   for vm in UCHI SOTO KAIZOKU DARE OKAMI MAMORU NIKKI; do
     echo "git+file:///root/dotfiles?dir=nix" > /var/lib/microvms/$vm/flake
   done
   ```
5. **Rolling redeploy**, least-critical first as canary; each is a full rebuild
   since the nixpkgs pin changed: `microvm -Ru NIKKI` (observability, safe
   canary) → `UCHI` → `SOTO` → `KAIZOKU` → `OKAMI` → then the network-critical
   pair `DARE` (DNS) and `MAMORU` (firewall) last, one at a time.

## Verification

- After step 3: `microvm -l` on MOTHER lists all VMs; existing VMs still
  running untouched.
- After step 4/5 canary: `microvm -Ru NIKKI` builds from the new ref; NIKKI
  boots, Grafana/Loki reachable, log digest still ingesting.
- After UCHI redeploy: `systemctl show sonarr -p UMask` → `0027`; next sonarr
  import lands `sonarr:media 640` with no "Unable to apply permissions"
  warnings (validates the earlier permission fix survived the migration).
- `nix flake check --no-build` in the repo passes (eval of all 8 systems).
- `infra-flake-update list` prints the 7 VM names.

## Out of scope / follow-ups

- OKAMI/wolf is ported as-is; folding wolf into the service catalog remains on
  the todo list.
- Refactor items 1–2 from the earlier review (typed-schema unification, shares
  model) are untouched.
- `laptop/` (TERRA) keeps its standalone flake deliberately.
