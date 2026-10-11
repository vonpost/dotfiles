set -euo pipefail

default_host="root@mother.lan"

usage() {
  cat <<'EOF'
infra — manage the MOTHER/microVM infrastructure

Update pins (edits flake.lock locally; commit, then deploy):
  infra update              fleet inputs: nixpkgs bleeding quadlet-nix
  infra update mother       MOTHER nixpkgs only: nixpkgs-mother
  infra update shared       shared inputs (affect host AND VMs): sops-nix microvm
  infra update terra        laptop flake, all inputs
  infra update INPUT...     specific root-flake inputs, e.g. infra update bleeding

Check (local, nothing deployed):
  infra check               evaluate all systems (nix flake check --no-build)
  infra check --build       also build them

Deploy (archives only the Nix source and its pinned inputs to MOTHER):
  infra deploy VM...        one or more VMs from the archived source (case-insensitive)
  infra deploy vms          application VMs; deploy DARE and MAMORU separately
  infra deploy mother       activate the exact prebuilt MOTHER closure (shows pin age first)
  infra deploy terra        nixos-rebuild switch on this machine

  Deadman's switch: MOTHER is offsite, so deploys to it and to MAMORU (which
  carries the WAN path) arm an automatic rollback BEFORE activating. If the
  deploy is not confirmed over a fresh connection within the window, the
  previous system is restored. Default: on for mother, MAMORU and DARE, off
  elsewhere.
    --deadman[=MIN]         force deadman on (window in minutes, default 30)
    --keep-deadman         enable rollback and leave it armed for manual health checks
    --no-deadman            force deadman off

  infra disarm              cancel any armed deadman timers on MOTHER

Info:
  infra list                VMs defined by the flake
  infra status              local repo/pin state, armed deadmen, VM status

Options / environment:
  --host HOST         MOTHER ssh destination   (INFRA_HOST, default root@mother.lan)
  --root PATH         local nix flake dir      (DOTFILES_NIX_ROOT, auto-detected)

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
root="$(cd "$root" && pwd -P)"
local_ref="path:$root"

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

archive_source() {
  archive_args=( --json --no-write-lock-file )
  if [ "$on_mother" -ne 1 ]; then
    archive_args+=( --to "ssh-ng://$host" )
  fi
  archive="$(nixcmd flake archive "${archive_args[@]}" "$local_ref")"
  source_path="$(printf '%s' "$archive" | jq -er .path)"
  validate_store_path "$source_path"
  source_ref="path:$source_path"
  printf 'Pinned deployment source: %s\n' "$source_ref"
  remote ln -sfn "$source_path" /nix/var/nix/gcroots/infra-source-staged
}

validate_store_path() {
  [[ "$1" =~ ^/nix/store/[a-z0-9]{32}-[a-zA-Z0-9+._?=-]+$ ]] || die "invalid store path: $1"
}

build_candidate() {
  target_name="$1"
  attribute="$2"
  candidate="$(remote nix --extra-experimental-features "nix-command flakes" build \
    --no-write-lock-file --print-out-paths \
    --out-link "/nix/var/nix/gcroots/infra-candidate-$target_name" \
    "$source_ref#nixosConfigurations.$target_name.config.$attribute")"
  validate_store_path "$candidate"
  printf 'Candidate for %s: %s\n' "$target_name" "$candidate"
}

record_vm_source() {
  remote ln -sfn "$source_path" "/nix/var/nix/gcroots/infra-source-$vm"
  # These positional parameters belong to the remote sh invocation.
  # shellcheck disable=SC2016
  remote /bin/sh -c 'printf "%s\n" "$2" > "$1"' sh \
    "/var/lib/microvms/$vm/flake" "$source_ref"
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
    # The archived path source includes these files, including new files.
  fi
}

pin_info() {
  jq -r --arg n "$1" \
    '.nodes[$n].locked | "\(.rev[0:12]) (\(.lastModified | gmtime | strftime("%Y-%m-%d")))"' \
    "$root/flake.lock"
}

vm_names() {
  names="$(nixcmd eval --json "$local_ref#nixosConfigurations" --apply builtins.attrNames \
    | jq -r '.[] | select(. != "MOTHER")' | sort)"
  [ -n "$names" ] || die "could not enumerate VMs from $root (flake eval failed?)"
  printf '%s\n' "$names"
}

deploy_mother() {
  ensure_no_deadman MOTHER
  printf 'MOTHER pin:  nixpkgs-mother %s\n' "$(pin_info nixpkgs-mother)"
  printf 'fleet pin:   nixpkgs        %s\n' "$(pin_info nixpkgs)"
  build_candidate MOTHER system.build.toplevel
  old_sys="$(remote readlink -f /run/current-system)"
  validate_store_path "$old_sys"
  if [ "$candidate" = "$old_sys" ]; then
    printf 'MOTHER already runs this candidate; no activation needed.\n'
    return
  fi
  confirm "Activate this MOTHER candidate?"

  if [ "$use_deadman" = "on" ]; then
    remote ln -sfn "$old_sys" /nix/var/nix/gcroots/infra-deadman-MOTHER
    # Preserve the existing two-stage recovery: restore the old generation,
    # then ask the rescue service to reboot only if reachability stays broken.
    deadman_arm MOTHER "$deadman_min" \
      "nix-env -p /nix/var/nix/profiles/system --set '$old_sys' && '$old_sys/bin/switch-to-configuration' switch; systemd-run --unit=infra-deadman-MOTHER-stage2 --on-active=10min systemctl start infra-net-rescue.service"
  fi

  remote nix-env -p /nix/var/nix/profiles/system --set "$candidate"
  remote "$candidate/bin/switch-to-configuration" switch

  printf 'Health check over a fresh connection...\n'
  new_sys="$(remote readlink -f /run/current-system)"
  [ "$new_sys" = "$candidate" ] || die "MOTHER is not running the candidate; leaving rollback armed"
  state="$(remote systemctl is-system-running || true)"
  printf 'MOTHER state: %s (%s)\n' "$state" "$new_sys"
  case "$state" in
    running|degraded) ;;
    *) die "health check failed (state=$state); leaving rollback armed" ;;
  esac
  if [ "$use_deadman" = "on" ]; then
    finish_deadman MOTHER
  fi
}

# Deadman's switch: a transient systemd timer on MOTHER, armed AFTER the new
# system is built but BEFORE it is activated, carrying a fully-baked rollback
# command (no lookups at fire time). Disarming requires a fresh connection.
ensure_no_deadman() {
  for suffix in timer service stage2.timer stage2.service; do
    case "$suffix" in
      stage2.*) recovery_unit="infra-deadman-$1-$suffix" ;;
      *) recovery_unit="infra-deadman-$1.$suffix" ;;
    esac
    active="$(remote systemctl show "$recovery_unit" --property=ActiveState --value)"
    case "$active" in
      active|activating) die "rollback already active for $1; refusing to replace it" ;;
    esac
  done
}

deadman_arm() {
  unit="infra-deadman-$1"
  minutes="$2"
  rollback_cmd="$3"
  ensure_no_deadman "$1"
  remote systemctl reset-failed "$unit.service" 2>/dev/null || true
  remote systemd-run --unit="$unit" --on-active="${minutes}min" /bin/sh -c "$rollback_cmd"
  remote systemctl is-active --quiet "$unit.timer"
  printf 'Deadman armed: %s rolls back in %s min unless disarmed.\n' "$1" "$minutes"
}

deadman_disarm() {
  unit="infra-deadman-$1"
  remote systemctl stop "$unit.timer"
  active="$(remote systemctl show "$unit-stage2.timer" --property=ActiveState --value)"
  case "$active" in
    active|activating) remote systemctl stop "$unit-stage2.timer" ;;
  esac
  # A timer may have fired while health was checked. Never remove the old
  # generation's root while a rollback service is still running.
  ensure_no_deadman "$1"
  remote systemctl reset-failed "$unit.service" "$unit-stage2.service" 2>/dev/null || true
  printf 'Deadman disarmed for %s.\n' "$1"
}

deadman_default_for() {
  case "$1" in
    MOTHER|MAMORU|DARE) printf 'on' ;;
    *) printf 'off' ;;
  esac
}

finish_deadman() {
  if [ "$keep_deadman" -eq 1 ]; then
    printf 'Generation verified; rollback for %s remains armed for application/network checks.\n' "$1"
  else
    deadman_disarm "$1"
    remote rm -f "/nix/var/nix/gcroots/infra-deadman-$1"
  fi
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
    # Fetch private submodules with the caller's SSH credentials and Nix cache.
    # nixos-rebuild elevates only the profile update and activation commands.
    nixos-rebuild switch --sudo --flake "$(terra_flakeref)#TERRA"
  fi
}

deploy_vm() {
  vm="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  printf '%s\n' "$known_vms" | grep -qx "$vm" || die "unknown VM '$1'; run: infra list"
  ensure_no_deadman "$vm"

  vm_deadman="$deadman_mode"
  [ "$vm_deadman" = "auto" ] && vm_deadman="$(deadman_default_for "$vm")"

  old_runner="$(remote readlink -f "/var/lib/microvms/$vm/booted")"
  validate_store_path "$old_runner"
  build_candidate "$vm" microvm.declaredRunner
  if [ "$candidate" = "$old_runner" ]; then
    printf '%s already runs this candidate; no restart needed.\n' "$vm"
    record_vm_source
    return
  fi
  expected_system="$(remote readlink -f "$candidate/share/microvm/system")"
  validate_store_path "$expected_system"
  [ "$vm" != "MAMORU" ] || confirm "Activate this MAMORU candidate?"
  if [ "$vm_deadman" = "on" ]; then
    remote ln -sfn "$old_runner" "/nix/var/nix/gcroots/infra-deadman-$vm"
    deadman_arm "$vm" "$deadman_min" \
      "ln -sfn '$old_runner' /var/lib/microvms/$vm/current && systemctl restart microvm@$vm.service && rm -f /nix/var/nix/gcroots/infra-deadman-$vm"
  fi
  remote ln -sfn "$candidate" "/var/lib/microvms/$vm/current"
  remote systemctl restart "microvm@$vm.service"

  if [ "$vm" = "MAMORU" ]; then
    # MAMORU intentionally has no network access from anywhere; it is only
    # reachable from MOTHER over vsock. Probing through `remote` also proves
    # the laptop->MOTHER path — the WAN route this deadman protects — and the
    # vsock leg proves the VM booted. Host key checks are pointless on a
    # hypervisor-local vsock channel and would break on key rotation.
    cid="$(nixcmd eval "$source_ref#nixosConfigurations.$vm.config.microvm.vsock.cid")"
    probe_desc="vsock/$cid via MOTHER"
    probe() {
      remote ssh -o ControlPath=none -o ConnectTimeout=10 -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "vsock/$cid" readlink -f /run/current-system
    }
  else
    vm_host="root@$(printf '%s' "$vm" | tr '[:upper:]' '[:lower:]').lan"
    probe_desc="$vm_host"
    probe() {
      ssh -o ControlPath=none -o ConnectTimeout=10 -o BatchMode=yes "$vm_host" readlink -f /run/current-system
    }
  fi
  printf 'Health check: waiting for %s...\n' "$probe_desc"
  healthy=0
  for _ in 1 2 3 4 5 6 7 8; do
    if observed_system="$(probe 2>/dev/null)" && [ "$observed_system" = "$expected_system" ]; then
      healthy=1
      break
    fi
    sleep 10
  done
  [ "$healthy" -eq 1 ] || die "cannot reach $probe_desc; leaving deadman armed to roll back $vm"
  booted="$(remote readlink -f "/var/lib/microvms/$vm/booted")"
  [ "$booted" = "$candidate" ] || die "$vm did not boot the candidate; leaving rollback armed"
  record_vm_source
  if [ "$vm_deadman" = "on" ]; then
    finish_deadman "$vm"
  fi
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
        nixcmd flake update --flake "$local_ref" "${inputs[@]}"
        ;;
      mother)
        shift
        inputs=( "$@" )
        [ "${#inputs[@]}" -gt 0 ] || inputs=( nixpkgs-mother )
        printf 'Updating MOTHER inputs: %s\n' "${inputs[*]}"
        nixcmd flake update --flake "$local_ref" "${inputs[@]}"
        ;;
      shared)
        shift
        inputs=( "$@" )
        [ "${#inputs[@]}" -gt 0 ] || inputs=( sops-nix microvm )
        printf 'Updating shared host/VM inputs: %s\n' "${inputs[*]}"
        nixcmd flake update --flake "$local_ref" "${inputs[@]}"
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
        nixcmd flake update --flake "$local_ref" "$@"
        ;;
    esac
    ;;

  check)
    if [ "${1:-}" = "--build" ]; then
      nixcmd flake check "$local_ref"
    else
      # Cached IFD outputs may be read, but neither local nor remote source
      # builds may start during an evaluation-only check.
      nixcmd flake check --no-build --option max-jobs 0 --option builders "" "$local_ref"
    fi
    ;;

  deploy)
    deadman_mode="auto"
    deadman_min=30
    keep_deadman=0
    targets=()
    for arg in "$@"; do
      case "$arg" in
        --deadman) deadman_mode="on" ;;
        --deadman=*) deadman_mode="on"; deadman_min="${arg#*=}" ;;
        --keep-deadman) keep_deadman=1 ;;
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

    [[ "$deadman_min" =~ ^[1-9][0-9]*$ ]] || die "deadman minutes must be a positive integer"
    if [ "$keep_deadman" -eq 1 ]; then
      [ "$deadman_mode" != "off" ] || die "--keep-deadman conflicts with --no-deadman"
      deadman_mode="on"
    fi
    known_vms="$(vm_names)"
    # Validate everything before archiving or touching the host. Critical
    # targets deploy alone so their recovery checks cannot be batched away.
    for target in "${targets[@]}"; do
      upper="$(printf '%s' "$target" | tr '[:lower:]' '[:upper:]')"
      case "$upper" in
        MOTHER|MAMORU|DARE)
          [ "${#targets[@]}" -eq 1 ] || die "MOTHER, MAMORU and DARE must each deploy alone"
          ;;
        VMS) ;;
        *) printf '%s\n' "$known_vms" | grep -qx "$upper" || die "unknown VM '$target'" ;;
      esac
    done
    guard_dirty
    archive_source

    for target in "${targets[@]}"; do
      case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
        mother)
          use_deadman="$deadman_mode"
          [ "$use_deadman" = "auto" ] && use_deadman="$(deadman_default_for MOTHER)"
          deploy_mother
          ;;
        vms)
          # A while-read loop would lose everything after the first VM: the
          # ssh under deploy_vm inherits the loop's stdin and drains it.
          for vm in $known_vms; do
            case "$vm" in MAMORU|DARE) continue ;; esac
            deploy_vm "$vm"
          done
          ;;
        *)
          deploy_vm "$target"
          ;;
      esac
    done
    ;;

  disarm)
    remote systemctl stop 'infra-deadman-*.timer'
    printf 'Deadman timers stopped; rollback roots retained for recovery.\n'
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
