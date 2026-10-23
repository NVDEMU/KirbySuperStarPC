#!/bin/sh
set -u

show_error() {
  /usr/bin/osascript -e 'display dialog "Kirby Super Star Recomp could not start. See Library/Logs/Kirby Super Star Recomp/launcher.log under your home folder for details." buttons {"OK"} default button "OK" with icon stop' >/dev/null 2>&1 || true
}

if [ -z "$HOME" ]; then
  show_error
  exit 1
fi

LOG_DIR="$HOME/Library/Logs/Kirby Super Star Recomp"
if ! mkdir -p "$LOG_DIR"; then
  show_error
  exit 1
fi
LOG_FILE="$LOG_DIR/launcher.log"
exec >>"$LOG_FILE" 2>&1

echo
echo "===== Kirby Super Star Recomp launcher: $(date) ====="

fail() {
  echo "ERROR: $*" >&2
  show_error
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || fail "Could not locate app Resources."
APP_PACK="$SCRIPT_DIR/setup-pack"
DATA="$HOME/Library/Application Support/NVDEMU/Kirby Super Star Recomp"
PROVENANCE="$APP_PACK/update/BUILD_PROVENANCE.json"
MARKER="$DATA/.app-bundle-provenance.json"

[ -d "$APP_PACK" ] || fail "App resources do not contain setup-pack."
[ -f "$PROVENANCE" ] || fail "Setup pack is missing update/BUILD_PROVENANCE.json."
mkdir -p "$DATA" || fail "Could not create the writable setup folder."

if [ ! -f "$MARKER" ] || ! cmp -s "$MARKER" "$PROVENANCE"; then
  echo "Syncing current setup-pack files into: $DATA"
  # Update application files without overwriting the user's ROM path, settings,
  # saves, generated code, or custom/installed mod state.
  /usr/bin/rsync -a \
    --exclude='/rom.cfg' \
    --exclude='/config.ini' \
    --exclude='/keybinds.ini' \
    --exclude='/input.ini' \
    --exclude='/controller.ini' \
    --exclude='/settings.toml' \
    --exclude='/game_options.toml' \
    --exclude='/saves/***' \
    --exclude='/build/***' \
    --exclude='/src/gen/***' \
    --exclude='/recomp/funcs.h' \
    --exclude='/mods/state.toml' \
    --exclude='/mods/custom/***' \
    --exclude='/mods/installed/***' \
    "$APP_PACK/" "$DATA/" || fail "Could not install app resources into the writable setup folder."
  cp "$PROVENANCE" "$MARKER.tmp.$$" || fail "Could not write update marker."
  mv -f "$MARKER.tmp.$$" "$MARKER" || fail "Could not activate update marker."
fi

HOST="$DATA/KirbySuperStarSNESRecomp"
[ -f "$HOST" ] || fail "Setup-host executable is missing at $HOST."
chmod u+x "$HOST" || fail "Could not mark setup host executable."
ANALYZER="$DATA/snesrecomp/recompiler-rs/target/release/snesrecomp-analyze"
if [ -f "$ANALYZER" ]; then
  chmod u+x "$ANALYZER" || fail "Could not mark the bundled analyzer executable."
fi

cd "$DATA" || fail "Could not enter the writable setup folder."
echo "Launching setup host: $HOST"
"$HOST" "$@"
STATUS=$?
echo "Setup host exited with status $STATUS."
if [ "$STATUS" -ne 0 ]; then
  show_error
fi
exit "$STATUS"
