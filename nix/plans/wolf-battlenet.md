# Battle.net / WoW on Wolf

Dedicated `WolfBattleNet` runner on OKAMI, using the existing shared stub and
a small NixOS closure. Sway/Xwayland follows the working Steam session;
nested gamescope previously failed to present frames on this stack.

Compatibility takes priority over closure size:

- Official **GE-Proton11-12** upstream x86_64 binary release, checksum pinned.
  Preserve its bundled DXVK, vkd3d-proton, media support and protonfixes.
  Do not patch its ELF files to use Nix libraries or mix in system Wine DLLs.
- **UMU 1.4.4**, with nixpkgs' multilib FHS wrapper, runs GE in its intended
  Steam Linux Runtime. Steam itself is not installed or started by this app.
  UMU downloads its required runtime on first launch and maintains it in the
  persistent home. The runtime is managed by UMU, not pinned by this closure.
- Reuse the existing NVIDIA driver bundle at `/run/nvidia-driver`, including
  its 32-bit libraries and the shared `/run/opengl-driver{,-32}` setup.
- Xwayland initially; native Wine Wayland needs separate validation.

## First launch

After deploying OKAMI, select **Battle.net / WoW** in Moonlight. Initial
startup needs network access and time to download the Steam Linux Runtime.
The script prepares the prefix with GE's bundled Winetricks, installs Arial,
and seeds Battle.net launcher preferences before opening Blizzard's installer
when Battle.net is absent. Sign in and choose the Classic/Forever client in
Battle.net.

Launcher defaults follow the Lutris WoW recipe: hardware acceleration,
launcher sounds and streaming are disabled, background game discovery is
enabled, and launch-window behavior is set to `2`. Existing preferences and
unrelated settings are preserved. Setup is marked complete inside the prefix
only after it succeeds, so failed setup retries and replacing a prefix reruns
it. Regular launches do not reinstall fonts or reset preferences. Battle.net
and WoW continue to update themselves normally.

**Choose `G:\World of Warcraft` as the game installation directory.** G:
maps to `/home/retro/Games`, outside the Wine prefix. Select the game's
borderless fullscreen mode. Try DX11 first for Classic, and validate the
available renderers for Forever; the runner includes both DX11 and DX12.

Wine's folder picker can ignore Open when only a drive has been browsed and
the bottom File name field is blank. Enter `G:\` in that field and click
Open; this was verified in the live session. Battle.net then creates the
game installation directory itself.

Persistent state (all under Wolf's existing per-app home mount):

| Container path | Contents |
| --- | --- |
| `~/.local/share/battlenet/prefix` | Battle.net, authentication, Wine registry |
| `~/Games/World of Warcraft` | Game data, `Interface`, `WTF`, screenshots |
| `~/.cache/wow` | NVIDIA graphics cache |
| `~/.local/share/umu` | UMU's downloaded runtime |
| `~/.config/WowUpCf` | WoWUp preferences and addon database |

Runner name `WolfBattleNet` is the storage identity; keep it stable. It has
its own profile and must never use the `WolfSteam` runner name. UMU uses
`waitforexitandrun` so closing Battle.net while WoW runs should not end the
stream. When UMU finishes, the session ends unless WoWUp is still open;
then it switches to WoWUp and waits for it to close before powering off.
Ctrl+Shift+9 also exits the whole session. Application errors are shown
in a dialog.

## Addon management

Battle.net launches directly. Native Linux **WoWUp with CurseForge 2.25.4**
stays closed until requested and can run alongside WoW without quitting it.
It uses a separate workspace so fullscreen WoW does not cover its window.

| Shortcut | Action |
| --- | --- |
| **Ctrl+Shift+6** | Open WoWUp, or return to it if already running |
| **Ctrl+Shift+7** | Switch back to WoW / Battle.net |
| **Ctrl+Shift+8** | Gracefully close WoWUp and return to the game |
| **Ctrl+Shift+9** | End the whole session |

These shortcuts avoid the client's XMonad bindings on Super (the Windows
key), including Super+A and Super+G, and Moonlight's Ctrl+Alt+Shift shortcuts.
Use the number row while holding Ctrl and Shift.

Closing WoWUp's window also returns to the game. The launchers retain
separate locks to prevent duplicate instances of each app; they can run
at the same time.

On first use, complete WoWUp's permissions setup, then open
**Options → WoW Clients → Add New** and select
the appropriate game's `.exe` inside `/home/retro/Games/World of Warcraft`.
Choose the actual client subdirectory (for example `_retail_` or
`_classic_era_`), not the Wine prefix or the top-level `Games` directory.
If you previously installed WoW elsewhere, select that installation instead.
The native manager sees the same files as Battle.net's `G:` drive.

The wrapper disables WoWUp's minimize-on-close, start-minimized and
start-with-system settings on each launch; this session has no system tray.
Other preferences and addon data are preserved. Leave those three settings
disabled so the close button quits WoWUp and returns to the game. WoWUp
itself is packaged in the Nix store: update its version and checksum in
`wolf-nix/packages/images/wowup-cf.nix`, then rebuild. Addons update normally
through WoWUp and persist alongside the game.

**Ctrl+Shift+8** also works from WoWUp's first-run permissions screen.

## Validation and updates

Check the Nix closure and shell checks before deployment, then verify on
OKAMI: installer/login, game download and updates, entering the world,
Vulkan rendering on NVIDIA, keyboard/mouse capture, audio, disconnect and
reconnect, and quitting Battle.net while the game is running. Inspect the
container's `wolf-battlenet-session` journal for bootstrap/UMU errors. On
failure, use `UMU_LOG=1 PROTON_LOG=1` when invoking `wolf-battlenet` inside the
session for detailed logs. WoW Classic/Forever compatibility is not proven
until the actual clients pass this validation.

Run `python3 -m unittest discover -s tests/wolf` for setup preservation,
on-demand startup, independent launcher locks and session shutdown checks.
Also verify the stream workflow on OKAMI: launch WoW, open WoWUp with
Ctrl+Shift+6, switch back with Ctrl+Shift+7, return to WoWUp with
Ctrl+Shift+6, and close it with Ctrl+Shift+8 while the game stays running.
Confirm the selected client and addon list survive a new stream, and that
quitting the game and Battle.net while WoWUp is open leaves time to finish
managing addons.

Update GE by changing the version and release archive checksum together in
`wolf-nix/packages/images/battlenet.nix`. Update UMU's version, source hash
and cargo vendor hash together. Neither runner silently follows `latest`.
Back up the prefix before testing a newer runner: reverting a Nix generation
restores binaries, but does not undo prefix changes made by newer Proton.
Keep game data and addon settings during prefix repair.

Upstream references:

- https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton11-12
- https://github.com/GloriousEggroll/proton-ge-custom#readme
- https://github.com/Open-Wine-Components/umu-launcher
- https://lutris.net/games/install/36240/view
- https://github.com/WowUp/WowUp.CF/releases/tag/v2.25.4
- https://wowup.io/guide/options/application
