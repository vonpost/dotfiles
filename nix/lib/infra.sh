set -euo pipefail

default_host="root@mother.lan"
default_remote_root="/root/dotfiles"

usage() {
  cat <<'EOF'
infra — manage the MOTHER/microVM infrastructure

Update pins (edits flake.lock locally; commit, then deploy):
  infra update              fleet inputs: nixpkgs bleeding quadlet-nix
  infra update mother       MOTHER inputs: nixpkgs-mother sops-nix microvm
  infra update terra        laptop flake, all inputs
  infra update INPUT...     specific root-flake inputs, e.g. infra update bleeding

Check (local, nothing deployed):
  infra check               evaluate all systems (nix flake check --no-build)
  infra check --build       also build them

Deploy (syncs repo to MOTHER first):
  infra deploy VM...        one or more VMs via microvm -Ru (case-insensitive)
  infra deploy vms          every VM
  infra deploy mother       nixos-rebuild switch on MOTHER (shows pin age first)
  infra deploy terra        nixos-rebuild switch on this machine

  Deadman's switch: MOTHER is offsite, so deploys to it and to MAMORU (which
  carries the WAN path) arm an automatic rollback BEFORE activating. If the
  deploy is not confirmed over a fresh connection within the window, the
  previous system is restored. Default: on for mother and MAMORU, off
  elsewhere.
    --deadman[=MIN]         force deadman on (window in minutes, default 30)
    --no-deadman            force deadman off

  infra disarm              cancel any armed deadman timers on MOTHER

Info:
  infra list                VMs defined by the flake
  infra status              local repo/pin state, armed deadmen, VM status

Options / environment:
  --host HOST         MOTHER ssh destination   (INFRA_HOST, default root@mother.lan)
  --root PATH         local nix flake dir      (DOTFILES_NIX_ROOT, auto-detected)
  --remote-root PATH  dotfiles path on MOTHER  (INFRA_REMOTE_ROOT, default /root/dotfiles)

Runs everything locally when invoked on MOTHER itself.
EOF
}

die() {
  printf 'infra: %s\n' "$*" >&2
  exit 1
}

detect_root() {
  if [ -n "${DOTFILES_NIX_ROOT:-}" ]; then
    printf '%s\n' "$DOTFILES_NIX_ROOT"
    return
  fi

  search="$(pwd -P)"
  while [ "$search" != "/" ]; do
    if [ -f "$search/nix/flake.nix" ] && [ -d "$search/nix/config/infra" ]; then
      printf '%s\n' "$search/nix"
      return
    fi
    if [ -f "$search/flake.nix" ] && [ -d "$search/config/infra" ]; then
      printf '%s\n' "$search"
      return
    fi
    search="$(dirname "$search")"
  done

  if [ -n "${HOME:-}" ] && [ -f "$HOME/dotfiles/nix/flake.nix" ]; then
    printf '%s\n' "$HOME/dotfiles/nix"
  else
    printf '%s\n' "/root/dotfiles/nix"
  fi
}

host="${INFRA_HOST:-$default_host}"
remote_root="${INFRA_REMOTE_ROOT:-$default_remote_root}"
root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || die "--host requires a value"
      host="$2"
      shift 2
      ;;
    --root)
      [ "$#" -ge 2 ] || die "--root requires a path"
      root="$2"
      shift 2
      ;;
    --remote-root)
      [ "$#" -ge 2 ] || die "--remote-root requires a path"
      remote_root="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[ -z "$root" ] && root="$(detect_root)"
[ -f "$root/flake.nix" ] || die "flake not found at $root"
repo_root="$(dirname "$root")"
remote_root="${remote_root%/}"

on_mother=0
[ "$(uname -n)" = "MOTHER" ] && on_mother=1

nixcmd() {
  nix --extra-experimental-features "nix-command flakes" "$@"
}

# ControlPath=none: every call is a genuinely fresh connection. A disarm that
# rode an ssh session established before the switch would prove nothing about
# whether we can still get back in.
remote() {
  if [ "$on_mother" -eq 1 ]; then
    "$@"
    return
  fi
  quoted=""
  for arg in "$@"; do
    quoted="${quoted} $(printf '%q' "$arg")"
  done
  # shellcheck disable=SC2029
  ssh -o ControlPath=none "$host" "${quoted# }"
}

sync_repo() {
  [ "$on_mother" -eq 1 ] && return 0
  printf 'Syncing %s -> %s:%s\n' "$repo_root/" "$host" "$remote_root/"
  # --chown, not --no-owner: rsync applies options in order, so a later -a
  # would re-enable the -o/-g that --no-owner/--no-group disabled. Forcing
  # root:root keeps libgit2's repo-ownership check happy for root on MOTHER.
  rsync -a --chown=root:root "$repo_root/" "$host:$remote_root/"
}

confirm() {
  [ -t 0 ] || return 0
  read -r -p "$1 [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) die "aborted" ;;
  esac
}

guard_dirty() {
  dirty="$(git -C "$root" status --porcelain -- . 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    printf 'warning: uncommitted changes under %s — nix builds the dirty tree, so these WILL deploy:\n%s\n' "$root" "$dirty"
    confirm "Deploy uncommitted state?"
  fi
}

pin_info() {
  jq -r --arg n "$1" \
    '.nodes[$n].locked | "\(.rev[0:12]) (\(.lastModified | gmtime | strftime("%Y-%m-%d")))"' \
    "$root/flake.lock"
}

vm_list=""
vm_names() {
  if [ -z "$vm_list" ]; then
    vm_list="$(nixcmd eval --json "$root#nixosConfigurations" --apply builtins.attrNames \
      | jq -r '.[] | select(. != "MOTHER")' | sort)"
  fi
  printf '%s\n' "$vm_list"
}

deploy_mother() {
  printf 'MOTHER pin:  nixpkgs-mother %s\n' "$(pin_info nixpkgs-mother)"
  printf 'fleet pin:   nixpkgs        %s\n' "$(pin_info nixpkgs)"
  confirm "Rebuild and switch MOTHER?"

  if [ "$use_deadman" = "on" ]; then
    # Build first so the armed window covers only eval + activation, and so a
    # build failure never leaves a timer running against an undeployed system.
    printf 'Pre-building MOTHER closure...\n'
    remote nix --extra-experimental-features "nix-command flakes" build --no-link \
      "$remote_root/nix#nixosConfigurations.MOTHER.config.system.build.toplevel"
    old_sys="$(remote readlink -f /run/current-system)"
    # Stage 1: restore the previous generation. Stage 2 (scheduled only if
    # stage 1 fires): if rollback did not restore reachability — network
    # *state* does not always follow config — reboot into the restored
    # generation to rebuild it from scratch.
    deadman_arm MOTHER "$deadman_min" \
      "nix-env -p /nix/var/nix/profiles/system --set $old_sys && $old_sys/bin/switch-to-configuration switch; systemd-run --unit=infra-deadman-MOTHER-stage2 --on-active=10min systemctl start infra-net-rescue.service"
  fi

  remote nixos-rebuild switch --flake "$remote_root/nix#MOTHER"

  if [ "$use_deadman" = "on" ]; then
    printf 'Health check over a fresh connection...\n'
    new_sys="$(remote readlink -f /run/current-system)"
    state="$(remote systemctl is-system-running || true)"
    printf 'MOTHER state: %s (%s)\n' "$state" "$new_sys"
    case "$state" in
      running|degraded) ;;
      *) die "health check failed (state=$state); leaving deadman armed to roll back" ;;
    esac
    deadman_disarm MOTHER
  fi
}

# Deadman's switch: a transient systemd timer on MOTHER, armed AFTER the new
# system is built but BEFORE it is activated, carrying a fully-baked rollback
# command (no lookups at fire time). Disarming requires a fresh connection.
deadman_arm() {
  unit="infra-deadman-$1"
  minutes="$2"
  rollback_cmd="$3"
  remote systemctl stop "$unit.timer" 2>/dev/null || true
  remote systemctl reset-failed "$unit.service" 2>/dev/null || true
  remote systemd-run --unit="$unit" --on-active="${minutes}min" /bin/sh -c "$rollback_cmd"
  printf 'Deadman armed: %s rolls back in %s min unless disarmed.\n' "$1" "$minutes"
}

deadman_disarm() {
  unit="infra-deadman-$1"
  remote systemctl stop "$unit.timer" "$unit-stage2.timer" 2>/dev/null || true
  remote systemctl reset-failed "$unit.service" "$unit-stage2.service" 2>/dev/null || true
  printf 'Deadman disarmed for %s.\n' "$1"
}

deadman_default_for() {
  case "$1" in
    MOTHER|MAMORU) printf 'on' ;;
    *) printf 'off' ;;
  esac
}

# The laptop flake needs the nix/secrets submodule (self.submodules = true),
# and bare subdir paths trip over flake resolution with that setting; the
# explicit git+file?dir form resolves correctly.
terra_flakeref() {
  printf 'git+file://%s?dir=%s/laptop' "$repo_root" "$(basename "$root")"
}

deploy_terra() {
  if [ "$(id -u)" -eq 0 ]; then
    nixos-rebuild switch --flake "$(terra_flakeref)#TERRA"
  else
    sudo nixos-rebuild switch --flake "$(terra_flakeref)#TERRA"
  fi
}

deploy_vm() {
  vm="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  vm_names | grep -qx "$vm" || die "unknown VM '$1'; run: infra list"

  vm_deadman="$deadman_mode"
  [ "$vm_deadman" = "auto" ] && vm_deadman="$(deadman_default_for "$vm")"

  if [ "$vm_deadman" != "on" ]; then
    remote microvm -Ru "$vm"
    return
  fi

  # Build + swap the current symlink first (VM keeps running the old system),
  # then arm against the still-running old runner before restarting into the
  # new one. The gcroot keeps the rollback target safe from GC while armed.
  printf 'Building %s...\n' "$vm"
  remote microvm -u "$vm"
  old_runner="$(remote readlink -f "/var/lib/microvms/$vm/booted" 2>/dev/null || true)"
  [ -n "$old_runner" ] || die "cannot determine running system for $vm"
  remote ln -sfn "$old_runner" "/nix/var/nix/gcroots/infra-deadman-$vm"
  deadman_arm "$vm" "$deadman_min" \
    "ln -sfn $old_runner /var/lib/microvms/$vm/current && systemctl restart microvm@$vm.service; rm -f /nix/var/nix/gcroots/infra-deadman-$vm"
  remote systemctl restart "microvm@$vm.service"

  vm_host="root@$(printf '%s' "$vm" | tr '[:upper:]' '[:lower:]').lan"
  printf 'Health check: waiting for %s...\n' "$vm_host"
  healthy=0
  for _ in 1 2 3 4 5 6 7 8; do
    if ssh -o ControlPath=none -o ConnectTimeout=10 -o BatchMode=yes "$vm_host" true 2>/dev/null; then
      healthy=1
      break
    fi
    sleep 10
  done
  [ "$healthy" -eq 1 ] || die "cannot reach $vm_host; leaving deadman armed to roll back $vm"
  deadman_disarm "$vm"
  remote rm -f "/nix/var/nix/gcroots/infra-deadman-$vm"
}

command="${1:-}"
[ -n "$command" ] || {
  usage
  exit 1
}
shift

case "$command" in
  update)
    case "${1:-fleet}" in
      fleet)
        [ "$#" -gt 0 ] && shift
        inputs=( "$@" )
        [ "${#inputs[@]}" -gt 0 ] || inputs=( nixpkgs bleeding quadlet-nix )
        printf 'Updating fleet inputs: %s\n' "${inputs[*]}"
        nixcmd flake update --flake "$root" "${inputs[@]}"
        ;;
      mother)
        shift
        inputs=( "$@" )
        [ "${#inputs[@]}" -gt 0 ] || inputs=( nixpkgs-mother sops-nix microvm )
        printf 'Updating MOTHER inputs: %s\n' "${inputs[*]}"
        nixcmd flake update --flake "$root" "${inputs[@]}"
        ;;
      terra)
        shift
        if [ "$#" -gt 0 ]; then
          printf 'Updating TERRA inputs: %s\n' "$*"
          nixcmd flake update --flake "$(terra_flakeref)" "$@"
        else
          printf 'Updating TERRA inputs: all\n'
          nixcmd flake update --flake "$(terra_flakeref)"
        fi
        ;;
      *)
        printf 'Updating root inputs: %s\n' "$*"
        nixcmd flake update --flake "$root" "$@"
        ;;
    esac
    ;;

  check)
    if [ "${1:-}" = "--build" ]; then
      nixcmd flake check "$root"
    else
      nixcmd flake check --no-build "$root"
    fi
    ;;

  deploy)
    deadman_mode="auto"
    deadman_min=30
    targets=()
    for arg in "$@"; do
      case "$arg" in
        --deadman) deadman_mode="on" ;;
        --deadman=*) deadman_mode="on"; deadman_min="${arg#*=}" ;;
        --no-deadman) deadman_mode="off" ;;
        *) targets+=( "$arg" ) ;;
      esac
    done
    [ "${#targets[@]}" -ge 1 ] || die "deploy requires a target; see: infra --help"

    if [ "${targets[0]}" = "terra" ]; then
      [ "${#targets[@]}" -eq 1 ] || die "terra deploys alone"
      deploy_terra
      exit 0
    fi

    guard_dirty
    sync_repo

    for target in "${targets[@]}"; do
      case "$target" in
        mother)
          use_deadman="$deadman_mode"
          [ "$use_deadman" = "auto" ] && use_deadman="$(deadman_default_for MOTHER)"
          deploy_mother
          ;;
        vms)
          while IFS= read -r vm; do
            deploy_vm "$vm"
          done < <(vm_names)
          ;;
        *)
          deploy_vm "$target"
          ;;
      esac
    done
    ;;

  disarm)
    remote systemctl stop 'infra-deadman-*.timer' 2>/dev/null || true
    remote /bin/sh -c 'rm -f /nix/var/nix/gcroots/infra-deadman-*'
    printf 'All deadman timers stopped.\n'
    ;;

  list)
    vm_names
    ;;

  status)
    printf '== repo (%s)\n' "$repo_root"
    git -C "$repo_root" log --oneline -1
    dirty="$(git -C "$root" status --porcelain -- . 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
      printf 'uncommitted changes under nix/:\n%s\n' "$dirty"
    else
      printf 'nix/ tree clean\n'
    fi
    printf '\n== pins\n'
    printf 'nixpkgs        %s\n' "$(pin_info nixpkgs)"
    printf 'nixpkgs-mother %s\n' "$(pin_info nixpkgs-mother)"
    printf 'bleeding       %s\n' "$(pin_info bleeding)"
    printf '\n== deadman timers on MOTHER\n'
    remote systemctl list-timers 'infra-deadman-*' --no-pager --no-legend || true
    printf '\n== VMs on MOTHER\n'
    remote microvm -l
    ;;

  *)
    die "unknown command: $command"
    ;;
esac
