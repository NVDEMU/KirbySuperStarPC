#!/usr/bin/env bash
# Package an ALREADY-BUILT local Kirby Super Star executable into a playable
# macOS .app, DMG and app ZIP. This script does not generate C or compile.
# Run after a normal manual build has been verified to render correctly:
#   bash scripts/package_playable_macos_app.sh [build-dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "$#" -ge 1 ]]; then BUILD_ARG="$1"; else BUILD_ARG=build; fi
if [[ "$BUILD_ARG" = /* ]]; then
  BUILD_DIR="$(cd "$BUILD_ARG" 2>/dev/null && pwd -P)" || { echo "error: build directory does not exist: $BUILD_ARG" >&2; exit 1; }
else
  BUILD_DIR="$(cd "$ROOT/$BUILD_ARG" 2>/dev/null && pwd -P)" || { echo "error: build directory does not exist: $ROOT/$BUILD_ARG" >&2; exit 1; }
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: playable .app/.dmg packaging requires macOS (hdiutil, codesign, ditto)." >&2
  exit 1
fi
EXE="$BUILD_DIR/KirbySuperStarSNESRecomp"
CACHE="$BUILD_DIR/CMakeCache.txt"
if [[ ! -x "$EXE" ]]; then
  echo "error: playable executable not found or not executable: $EXE" >&2
  echo "Build it first with the normal manual CMake build; this script does not rebuild." >&2
  exit 1
fi
if [[ ! -f "$CACHE" ]]; then echo "error: missing $CACHE; refusing to package an unverified build directory." >&2; exit 1; fi
if grep -Eq '^SNESRECOMP_SETUP_HOST:BOOL=ON$' "$CACHE"; then
  echo "error: this is the setup-host build, not a playable manual build." >&2
  echo "Reconfigure and build normally without -DSNESRECOMP_SETUP_HOST=ON." >&2
  exit 1
fi
SOURCE_HOME="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CACHE" | head -n 1)"
if [[ -n "$SOURCE_HOME" && "$SOURCE_HOME" != "$ROOT" ]]; then
  echo "error: build cache belongs to another source folder: $SOURCE_HOME" >&2
  echo "Expected this repository: $ROOT" >&2
  exit 1
fi
if [[ ! -f "$ROOT/recomp/funcs.h" ]] || ! find "$ROOT/src/gen" -maxdepth 1 -type f -name '*.c' -print -quit 2>/dev/null | grep -q .; then
  echo "error: locally generated game code is missing." >&2
  echo "Run the manual ROM-to-C generation step and successful manual build first." >&2
  exit 1
fi
if ! file "$EXE" | grep -q 'Mach-O'; then
  echo "error: this executable is not a macOS Mach-O binary: $EXE" >&2
  file "$EXE" >&2 || true
  exit 1
fi
BUNDLE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ ! "$BUNDLE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}([+-][A-Za-z0-9.-]+)?$ ]]; then BUNDLE_VERSION=0.0.0; fi
ASSET_VERSION="${KIRBY_RELEASE_ASSET_VERSION:-manual}"
PLATFORM="${KIRBY_RELEASE_PLATFORM:-macos}"
DIST="$ROOT/dist"
mkdir -p "$DIST"
WORK="$(mktemp -d "/tmp/kirby-playable-app.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Kirby Super Star Recomp.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PACK_BUILD="$RESOURCES/playable-pack/build"
mkdir -p "$MACOS" "$PACK_BUILD"

# Stage only the built runtime: no CMake objects, ROMs, ROM path, saves or mods state.
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
  "$BUILD_DIR/" "$PACK_BUILD/"
[[ -x "$PACK_BUILD/KirbySuperStarSNESRecomp" ]] || { echo "error: staged app lacks the playable executable." >&2; exit 1; }
if find "$PACK_BUILD" -type f \( -iname '*.sfc' -o -iname '*.smc' -o -iname '*.fig' -o -iname '*.srm' -o -iname '*.sav' \) -print -quit | grep -q .; then
  echo "error: refusing to package ROM or save data in the app bundle." >&2; exit 1
fi
if [[ -e "$PACK_BUILD/rom.cfg" ]]; then echo "error: refusing to bundle machine-specific rom.cfg." >&2; exit 1; fi

cp "$ROOT/scripts/macos_playable_app_launcher.sh" "$RESOURCES/launcher.sh"
chmod 644 "$RESOURCES/launcher.sh"
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror "$ROOT/scripts/macos_app_launcher.c" -o "$MACOS/KirbySuperStarRecomp"
chmod 755 "$MACOS/KirbySuperStarRecomp"
/bin/sh -n "$RESOURCES/launcher.sh"
file "$MACOS/KirbySuperStarRecomp" | grep -q 'Mach-O' || { echo "error: CFBundleExecutable is not a native Mach-O binary." >&2; exit 1; }

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>KirbySuperStarRecomp</string>
  <key>CFBundleIdentifier</key><string>com.nvdemu.kirbysuperstarrecomp.manual</string>
  <key>CFBundleName</key><string>Kirby Super Star Recomp</string>
  <key>CFBundleDisplayName</key><string>Kirby Super Star Recomp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

FINAL_APP="$DIST/Kirby Super Star Recomp (Manual Build).app"
rm -rf "$FINAL_APP"
cp -a "$APP" "$FINAL_APP"
DMG_ROOT="$WORK/dmg-root"
mkdir -p "$DMG_ROOT"
cp -a "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
DMG="$DIST/kirbysuperstar-$ASSET_VERSION-$PLATFORM.dmg"
sync
hdiutil create -volname "Kirby Super Star Recomp" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
APP_ZIP="$DIST/kirbysuperstar-$ASSET_VERSION-$PLATFORM-app.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
unzip -t "$APP_ZIP" >/dev/null
echo
echo "Packaged the existing manual build; no C generation or compilation was run."
echo "Playable app: $FINAL_APP"
echo "DMG:          $DMG"
echo "App ZIP:      $APP_ZIP"
echo "Package version/platform: $ASSET_VERSION / $PLATFORM"
