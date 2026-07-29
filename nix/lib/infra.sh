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

Deploy (syncs repo to MOTHER first; builds from committed HEAD):
  infra deploy VM...        one or more VMs via microvm -Ru (case-insensitive)
  infra deploy vms          every VM
  infra deploy mother       nixos-rebuild switch on MOTHER (shows pin age first)
  infra deploy terra        nixos-rebuild switch on this machine

Info:
  infra list                VMs defined by the flake
  infra status              local repo/pin state + VM status on MOTHER

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
  ssh "$host" "${quoted# }"
}

sync_repo() {
  [ "$on_mother" -eq 1 ] && return 0
  printf 'Syncing %s -> %s:%s\n' "$repo_root/" "$host" "$remote_root/"
  rsync --no-owner --no-group -a "$repo_root/" "$host:$remote_root/"
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
  remote nixos-rebuild switch --flake "$remote_root/nix#MOTHER"
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
  remote microvm -Ru "$vm"
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
    [ "$#" -ge 1 ] || die "deploy requires a target; see: infra --help"

    if [ "$1" = "terra" ]; then
      [ "$#" -eq 1 ] || die "terra deploys alone"
      deploy_terra
      exit 0
    fi

    guard_dirty
    sync_repo

    for target in "$@"; do
      case "$target" in
        mother)
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
    printf '\n== VMs on MOTHER\n'
    remote microvm -l
    ;;

  *)
    die "unknown command: $command"
    ;;
esac
