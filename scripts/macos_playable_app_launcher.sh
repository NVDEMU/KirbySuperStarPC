#!/bin/sh
set -u
show_error() {
  /usr/bin/osascript -e 'display dialog "Kirby Super Star Recomp (Manual Build) could not start. See Library/Logs/Kirby Super Star Recomp Manual/launcher.log under your home folder for details." buttons {"OK"} default button "OK" with icon stop' >/dev/null 2>&1 || true
}
[ -n "$HOME" ] || { show_error; exit 1; }
LOG_DIR="$HOME/Library/Logs/Kirby Super Star Recomp Manual"
mkdir -p "$LOG_DIR" || { show_error; exit 1; }
exec >>"$LOG_DIR/launcher.log" 2>&1
echo
echo "===== Kirby Super Star Recomp (Manual Build): $(date) ====="
fail() { echo "ERROR: $*" >&2; show_error; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || fail "Could not locate app Resources."
PACK_BUILD="$SCRIPT_DIR/playable-pack/build"
PACK_EXE="$PACK_BUILD/KirbySuperStarSNESRecomp"
DATA="$HOME/Library/Application Support/NVDEMU/Kirby Super Star Recomp Manual"
LEGACY="$HOME/Library/Application Support/NVDEMU/Kirby Super Star Recomp"
DATA_BUILD="$DATA/build"
[ -x "$PACK_EXE" ] || fail "The app bundle does not contain a runnable manual-build executable."
mkdir -p "$DATA_BUILD" || fail "Could not create the writable game folder."

# Launch the already-built game directly. Preserve settings/saves/mod state.
/usr/bin/rsync -a --no-times \
  --exclude='/CMakeCache.txt' --exclude='/CMakeFiles/***' --exclude='/_deps/***' \
  --exclude='/.ninja_deps' --exclude='/.ninja_log' --exclude='/build.ninja' \
  --exclude='/rules.ninja' --exclude='/cmake_install.cmake' --exclude='/Makefile' \
  --exclude='*.o' --exclude='*.a' --exclude='*.sfc' --exclude='*.smc' \
  --exclude='*.fig' --exclude='*.srm' --exclude='*.sav' --exclude='/rom.cfg' \
  --exclude='/config.ini' --exclude='/keybinds.ini' --exclude='/input.ini' \
  --exclude='/controller.ini' --exclude='/launcher-window.ini' \
  --exclude='/settings.toml' --exclude='/game_options.toml' --exclude='/saves/***' \
  --exclude='/mods/state.toml' --exclude='/mods/custom/***' --exclude='/mods/installed/***' \
  "$PACK_BUILD/" "$DATA_BUILD/" || fail "Could not copy the app runtime into Application Support."

for name in rom.cfg config.ini keybinds.ini input.ini controller.ini launcher-window.ini settings.toml game_options.toml; do
  if [ ! -f "$DATA_BUILD/$name" ]; then
    if [ -f "$LEGACY/build/$name" ]; then
      cp -p "$LEGACY/build/$name" "$DATA_BUILD/$name" || fail "Could not preserve $name."
    elif [ -f "$LEGACY/$name" ]; then
      cp -p "$LEGACY/$name" "$DATA_BUILD/$name" || fail "Could not preserve $name."
    fi
  fi
done

for save_dir in "$LEGACY/build/saves" "$LEGACY/saves"; do
  if [ -d "$save_dir" ]; then
    mkdir -p "$DATA_BUILD/saves" || fail "Could not create the saves folder."
    /usr/bin/rsync -a --ignore-existing "$save_dir/" "$DATA_BUILD/saves/" || fail "Could not migrate existing saves."
  fi
done
for mod_root in "$LEGACY/build/mods" "$LEGACY/mods"; do
  if [ -d "$mod_root" ]; then
    mkdir -p "$DATA_BUILD/mods" || fail "Could not create the mods folder."
    if [ ! -f "$DATA_BUILD/mods/state.toml" ] && [ -f "$mod_root/state.toml" ]; then
      cp -p "$mod_root/state.toml" "$DATA_BUILD/mods/state.toml" || fail "Could not preserve mod settings."
    fi
    for mod_dir in custom installed; do
      if [ -d "$mod_root/$mod_dir" ]; then
        mkdir -p "$DATA_BUILD/mods/$mod_dir" || fail "Could not create mod folder $mod_dir."
        /usr/bin/rsync -a --ignore-existing "$mod_root/$mod_dir/" "$DATA_BUILD/mods/$mod_dir/" || fail "Could not migrate $mod_dir mods."
      fi
    done
  fi
done
chmod u+x "$DATA_BUILD/KirbySuperStarSNESRecomp" || fail "Could not mark the game executable."
cd "$DATA_BUILD" || fail "Could not enter the game runtime folder."
unset SNESRECOMP_FORCE_SETUP SNESRECOMP_NO_HANDOFF SNESRECOMP_PROJECT_ROOT SNESRECOMP_BUILD_DIR
echo "Launching the existing manual build: $DATA_BUILD/KirbySuperStarSNESRecomp"
exec "$DATA_BUILD/KirbySuperStarSNESRecomp" "$@"
