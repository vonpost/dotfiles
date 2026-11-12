# Called inside Sway so UMU inherits the nested compositor's DISPLAY.
set -euo pipefail

state_dir="$HOME/.local/share/battlenet"
mkdir -p "$state_dir" "$HOME/Games" "$HOME/.cache/wow"
# Only one UMU invocation may manage this prefix at a time.
exec 9>"$state_dir/session.lock"
flock -n 9 || { echo 'Battle.net is already running.' >&2; exit 1; }

export WINEPREFIX="$state_dir/prefix"
export PROTONPATH="$WOLF_BATTLENET_PROTON"
export GAMEID=umu-default
export STORE=battlenet
export PROTON_VERB=waitforexitandrun
# Use the tested Xwayland path. Native Wine Wayland is a separate experiment.
export PROTON_ENABLE_WAYLAND=0
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH="$HOME/.cache/wow"

mkdir -p "$WINEPREFIX/dosdevices"
# Install WoW to G:\World of Warcraft. Prefix repair then leaves game data alone.
if [ ! -e "$WINEPREFIX/dosdevices/g:" ] && [ ! -L "$WINEPREFIX/dosdevices/g:" ]; then
  ln -s "$HOME/Games" "$WINEPREFIX/dosdevices/g:"
fi

setup_marker="$WINEPREFIX/.wolf-battlenet-setup-v1"
if [ ! -f "$setup_marker" ]; then
  echo '[Battle.net] Preparing the prefix and installing Arial (first launch only).'
  # Use GE's bundled Winetricks inside the same UMU runtime as the game.
  # This also initializes new prefixes before seeding launcher preferences.
  umu-run winetricks arial
  python3 "$WOLF_BATTLENET_DEFAULTS" "$WINEPREFIX"
  # Keep this inside the prefix so rebuilding a prefix reruns setup. Failed
  # setup leaves no marker and is retried next time, without reinstalling WoW.
  touch "$setup_marker"
fi

battlenet="$WINEPREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
if [ -f "$battlenet" ]; then
  # Keep the parent shell alive holding the lock: bwrap can close extra FDs.
  umu-run "$battlenet" "$@"
  exit
fi

installer="$state_dir/Battle.net-Setup.exe"
# The installer self-updates; download only when Battle.net is absent.
curl --fail --location --retry 3 \
  'https://www.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live' \
  --output "$installer.part"
mv "$installer.part" "$installer"
umu-run "$installer" "$@"
