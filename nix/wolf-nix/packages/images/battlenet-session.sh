# Battle.net starts normally; the Sway shortcut opens WoWUp only on demand.
set -euo pipefail
trap 'swaymsg exit || true' EXIT

status=0
wolf-battlenet "$@" || status=$?
if [ "$status" -ne 0 ]; then
  zenity --error --title="Battle.net" \
    --text="Battle.net exited with an error (code $status). Details are in the wolf-battlenet-session journal." || true
fi

# UMU has waited for Battle.net and WoW. If the addon manager is still open,
# let the user finish before ending the stream, rather than interrupting it.
state_dir="$HOME/.local/share/battlenet"
mkdir -p "$state_dir"
exec 8>"$state_dir/wowup.lock"
flock 8
