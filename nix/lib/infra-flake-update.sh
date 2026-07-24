set -euo pipefail

default_root="/root/dotfiles/nix"

usage() {
  cat <<'EOF'
Usage:
  infra-flake-update [-R] [--remote HOST] [--root PATH] mother [INPUT...]
  infra-flake-update [-R] [--root PATH] terra [INPUT...]
  infra-flake-update [-R] [--remote HOST] [--root PATH] vm VM [INPUT...]
  infra-flake-update [--root PATH] list

Commands:
  mother       Update only root inputs used by MOTHER by default.
               Defaults: nixpkgs bleeding sops-nix microvm

  terra        Update the standalone TERRA laptop flake.

  vm VM        Update one standalone VM flake, then refresh only that VM input
               in the root flake lock so fresh MOTHER installs use the same pin.

  list         List VM flakes under the root flake.

Options:
  -R           Apply after updating. Runs nixos-rebuild switch for mother,
               or microvm -Ru VM for a VM.
  --remote HOST
               Sync the dotfiles checkout to HOST after local lock updates.
               With -R, apply MOTHER or VM changes on HOST instead of locally.
  --remote-root PATH
               Remote dotfiles checkout path. Defaults to /root/dotfiles.
  --delete     Pass --delete to rsync when syncing to --remote.
  --root PATH  Infra root flake directory. Defaults to DOTFILES_NIX_ROOT,
               a nearby dotfiles nix directory, $HOME/dotfiles/nix,
               then /root/dotfiles/nix.

Examples:
  infra-flake-update mother
  infra-flake-update --remote root@mother.lan -R mother
  infra-flake-update -R mother
  infra-flake-update terra
  infra-flake-update -R terra
  infra-flake-update mother nixpkgs microvm
  infra-flake-update vm DARE
  infra-flake-update --remote root@mother.lan -R vm DARE
  infra-flake-update -R vm DARE
  infra-flake-update vm DARE bleeding
EOF
}

die() {
  printf 'infra-flake-update: %s\n' "$*" >&2
  exit 1
}

detect_root() {
  if [ -n "${DOTFILES_NIX_ROOT:-}" ]; then
    printf '%s\n' "$DOTFILES_NIX_ROOT"
    return
  fi

  cwd="$(pwd -P)"
  search="$cwd"
  while [ "$search" != "/" ]; do
    if [ -f "$search/nix/flake.nix" ] && [ -d "$search/nix/vm" ] && [ -f "$search/nix/laptop/flake.nix" ]; then
      printf '%s\n' "$search/nix"
      return
    fi

    if [ -f "$search/flake.nix" ] && [ -d "$search/vm" ] && [ -f "$search/laptop/flake.nix" ]; then
      printf '%s\n' "$search"
      return
    fi

    search="$(dirname "$search")"
  done

  if [ -n "${HOME:-}" ] && [ -f "$HOME/dotfiles/nix/flake.nix" ]; then
    printf '%s\n' "$HOME/dotfiles/nix"
  else
    printf '%s\n' "$default_root"
  fi
}

root=""
rebuild=0
remote_host=""
remote_root="/root/dotfiles"
rsync_delete=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R)
      rebuild=1
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || die "--root requires a path"
      root="$2"
      shift 2
      ;;
    --remote)
      [ "$#" -ge 2 ] || die "--remote requires a host"
      remote_host="$2"
      shift 2
      ;;
    --remote-root)
      [ "$#" -ge 2 ] || die "--remote-root requires a path"
      remote_root="$2"
      shift 2
      ;;
    --delete)
      rsync_delete=1
      shift
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

parse_input_args() {
  parsed_inputs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -R)
        rebuild=1
        ;;
      *)
        parsed_inputs+=( "$1" )
        ;;
    esac
    shift
  done
}

shell_quote() {
  printf "%q" "$1"
}

if [ -z "$root" ]; then
  root="$(detect_root)"
fi

[ -f "$root/flake.nix" ] || die "root flake not found at $root"

repo_root="$(dirname "$root")"
remote_root="${remote_root%/}"
remote_nix_root="$remote_root/nix"

nix_flake_update() {
  nix --extra-experimental-features "nix-command flakes" flake update "$@"
}

sync_remote() {
  [ -n "$remote_host" ] || return 0

  rsync_args=( --no-owner --no-group -a )
  if [ "$rsync_delete" -eq 1 ]; then
    rsync_args+=( --delete )
  fi

  printf 'Syncing %s to %s:%s\n' "$repo_root/" "$remote_host" "$remote_root/"
  rsync "${rsync_args[@]}" "$repo_root/" "$remote_host:$remote_root/"
}

remote_run() {
  [ "$#" -gt 0 ] || die "remote_run requires a command"

  quoted_command=""
  for arg in "$@"; do
    quoted_command="${quoted_command} $(shell_quote "$arg")"
  done

  # shellcheck disable=SC2029
  ssh "$remote_host" "${quoted_command# }"
}

run_mother_rebuild() {
  if [ -n "$remote_host" ]; then
    printf 'Running nixos-rebuild switch for MOTHER on %s\n' "$remote_host"
    remote_run nixos-rebuild switch --flake "$remote_nix_root#MOTHER"
  else
    printf 'Running nixos-rebuild switch for MOTHER\n'
    nixos-rebuild switch --flake "$root#MOTHER"
  fi
}

run_vm_rebuild() {
  vm="$1"

  if [ -n "$remote_host" ]; then
    printf 'Running microvm -Ru %s on %s\n' "$vm" "$remote_host"
    remote_run microvm -Ru "$vm"
  else
    printf 'Running microvm -Ru %s\n' "$vm"
    microvm -Ru "$vm"
  fi
}

vm_names() {
  for flake in "$root"/vm/*/flake.nix; do
    [ -e "$flake" ] || continue
    basename "$(dirname "$flake")"
  done | sort
}

command="${1:-}"
[ -n "$command" ] || {
  usage
  exit 1
}
shift

case "$command" in
  mother)
    parse_input_args "$@"
    if [ "${#parsed_inputs[@]}" -gt 0 ]; then
      inputs=( "${parsed_inputs[@]}" )
    else
      inputs=( nixpkgs bleeding sops-nix microvm )
    fi

    printf 'Updating root flake inputs for MOTHER: %s\n' "${inputs[*]}"
    nix_flake_update --flake "$root" "${inputs[@]}"
    sync_remote

    if [ "$rebuild" -eq 1 ]; then
      run_mother_rebuild
    fi
    ;;

  terra)
    [ -z "$remote_host" ] || die "remote mode is only supported for mother and vm commands"

    parse_input_args "$@"
    terra_dir="$root/laptop"
    [ -f "$terra_dir/flake.nix" ] || die "TERRA flake not found at $terra_dir"

    if [ "${#parsed_inputs[@]}" -gt 0 ]; then
      inputs=( "${parsed_inputs[@]}" )
      printf 'Updating TERRA flake inputs: %s\n' "${inputs[*]}"
      nix_flake_update --flake "$terra_dir" "${inputs[@]}"
    else
      printf 'Updating TERRA flake inputs: all\n'
      nix_flake_update --flake "$terra_dir"
    fi

    if [ "$rebuild" -eq 1 ]; then
      printf 'Running nixos-rebuild switch for TERRA\n'
      nixos-rebuild switch --flake "$terra_dir#TERRA"
    fi
    ;;

  vm)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -R)
          rebuild=1
          shift
          ;;
        *)
          break
          ;;
      esac
    done

    [ "$#" -ge 1 ] || die "vm requires a VM name"
    vm="$1"
    shift

    vm_dir="$root/vm/$vm"
    [ -f "$vm_dir/flake.nix" ] || die "unknown VM '$vm'; run: infra-flake-update list"

    parse_input_args "$@"
    if [ "${#parsed_inputs[@]}" -gt 0 ]; then
      inputs=( "${parsed_inputs[@]}" )
      printf 'Updating VM flake %s inputs: %s\n' "$vm" "${inputs[*]}"
      nix_flake_update --flake "$vm_dir" "${inputs[@]}"
    else
      printf 'Updating VM flake %s inputs: all\n' "$vm"
      nix_flake_update --flake "$vm_dir"
    fi

    printf 'Refreshing root flake pin for VM %s\n' "$vm"
    nix_flake_update --flake "$root" "$vm"
    sync_remote

    if [ "$rebuild" -eq 1 ]; then
      run_vm_rebuild "$vm"
    fi
    ;;

  list)
    vm_names
    ;;

  *)
    die "unknown command: $command"
    ;;
esac
