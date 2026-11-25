set -euo pipefail

state_dir="$HOME/.local/share/battlenet"
mkdir -p "$state_dir" "$HOME/Games"
# WoWUp may run alongside the game. Serialize only its own startup/settings
# writes. Alt+Tab handles switching to an open instance.
exec 9>"$state_dir/wowup.lock"
if ! flock -n 9; then
  exit 0
fi
report_error() {
  local status=$?
  zenity --error --title="WoWUp" \
    --text="WoWUp could not run. Details are in the wolf-battlenet-session journal." || true
  exit "$status"
}
trap report_error ERR
# Electron uses the release's productName (WowUpCf) for its user-data path.
python3 "$WOLF_WOWUP_SETTINGS" "${XDG_CONFIG_HOME:-$HOME/.config}/WowUpCf/preferences.json"
# Use the same Xwayland path as the game. Keep the parent shell alive
# holding the lock across the AppImage FHS wrapper's bwrap invocation.
wowup-cf --ozone-platform=x11 "$@"
