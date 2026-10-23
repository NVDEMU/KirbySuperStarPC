#!/usr/bin/env bash
# Package the native installer/App bundle/AppImage around the updater ZIP.
set -euo pipefail

PLATFORM="$1"
VERSION="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ZIP="$DIST/kirbysuperstar-$VERSION-$PLATFORM.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"

if [[ ! -f "$ZIP" ]]; then
  echo "::error::Missing portable setup pack: $ZIP" >&2
  exit 1
fi
UNPACK="$WORK/unpacked"
mkdir -p "$UNPACK"
python3 - "$ZIP" "$UNPACK" <<'PY'
import os
import sys
import zipfile

archive_path, destination = sys.argv[1:3]
with zipfile.ZipFile(archive_path) as zf:
    zf.extractall(destination)
    # ZipFile.extractall() does not restore Unix execute bits. That leaves the
    # setup executable and bundled compiler tools as non-executable files in
    # the .app, so Finder launches an app that immediately exits. Restore the
    # stored POSIX mode bits as part of native-app staging.
    for member in zf.infolist():
        mode = (member.external_attr >> 16) & 0o777
        if not mode:
            continue
        target = os.path.join(destination, member.filename.replace("/", os.sep))
        if os.path.exists(target):
            os.chmod(target, mode)
PY
PACK="$UNPACK/kirbysuperstar-$VERSION-$PLATFORM"
if [[ ! -d "$PACK" || -e "$PACK/rom.cfg" ]]; then
  echo "::error::Unexpected setup-pack layout or machine-specific rom.cfg found." >&2
  exit 1
fi
if [[ ! -f "$PACK/update/updater.py" || ! -f "$PACK/update/BUILD_PROVENANCE.json" ]]; then
  echo "::error::The base setup pack is missing updater metadata." >&2
  exit 1
fi

case "$PLATFORM" in
  windows-x64)
    CSC="/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
    [[ -f "$CSC" ]] || CSC="/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"
    [[ -f "$CSC" ]] || { echo "::error::csc.exe is missing on the Windows runner." >&2; exit 1; }
    OUT="$DIST/kirbysuperstar-$VERSION-windows-x64.exe"
    # Git Bash/MSYS rewrites slash-prefixed C# compiler switches such as
    # /nologo into filesystem paths (for example C:/Program Files/Git/nologo).
    # Disable argument path conversion for this one native Windows tool call.
    MSYS2_ARG_CONV_EXCL='*' "$CSC" /nologo /target:winexe \
      "/out:$(cygpath -w "$OUT")" \
      /reference:System.Windows.Forms.dll \
      /reference:System.Drawing.dll \
      /reference:System.IO.Compression.dll \
      /reference:System.IO.Compression.FileSystem.dll \
      "/resource:$(cygpath -w "$ZIP"),KirbySetupPack.zip" \
      "$(cygpath -w "$ROOT/scripts/windows_setup_installer.cs")"
    [[ -s "$OUT" ]] || { echo "::error::Windows installer was not produced." >&2; exit 1; }
    ;;

  macos-arm64|macos-x64)
    APP="$WORK/Kirby Super Star Recomp.app"
    CONTENTS="$APP/Contents"
    MACOS="$CONTENTS/MacOS"
    RESOURCES="$CONTENTS/Resources"
    mkdir -p "$MACOS" "$RESOURCES/setup-pack"
    cp -a "$PACK/." "$RESOURCES/setup-pack/"

    # Keep the script as a resource and make CFBundleExecutable a real Mach-O
    # binary. LaunchServices/Finder does not reliably launch a shell script
    # directly as CFBundleExecutable on current macOS.
    cp "$ROOT/scripts/macos_app_launcher.sh" "$RESOURCES/launcher.sh"
    chmod 644 "$RESOURCES/launcher.sh"
    /usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror \
      "$ROOT/scripts/macos_app_launcher.c" -o "$MACOS/KirbySuperStarRecomp"
    chmod 755 "$MACOS/KirbySuperStarRecomp"
    /bin/sh -n "$RESOURCES/launcher.sh"
    file "$MACOS/KirbySuperStarRecomp" | grep -q 'Mach-O' || {
      echo "::error::CFBundleExecutable is not a native Mach-O binary." >&2
      exit 1
    }
    [[ -x "$RESOURCES/setup-pack/KirbySuperStarSNESRecomp" ]] || {
      echo "::error::The setup-host executable lost its execute bit in the ZIP." >&2
      ls -l "$RESOURCES/setup-pack/KirbySuperStarSNESRecomp" >&2 || true
      exit 1
    }

    APP_VERSION="$VERSION"
    if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then APP_VERSION="0.0.0"; fi
    cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>KirbySuperStarRecomp</string>
  <key>CFBundleIdentifier</key><string>com.nvdemu.kirbysuperstarrecomp</string>
  <key>CFBundleName</key><string>Kirby Super Star Recomp</string>
  <key>CFBundleDisplayName</key><string>Kirby Super Star Recomp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    codesign --force --deep --sign - --timestamp=none "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"

    DMG_ROOT="$WORK/dmg-root"
    mkdir -p "$DMG_ROOT"
    cp -a "$APP" "$DMG_ROOT/"
    ln -s /Applications "$DMG_ROOT/Applications"
    DMG="$DIST/kirbysuperstar-$VERSION-$PLATFORM.dmg"
    # hdiutil on GitHub macOS runners can sporadically report
    # "Resource busy" immediately after a large amount of bundle I/O. Flush
    # writes first, then retry that transient error with bounded backoff.
    sync
    HDIUTIL_LOG="$WORK/hdiutil-create.log"
    for attempt in 1 2 3 4 5; do
      if hdiutil create -volname "Kirby Super Star Recomp" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >"$HDIUTIL_LOG" 2>&1; then
        cat "$HDIUTIL_LOG"
        break
      else
        hdiutil_status=$?
        cat "$HDIUTIL_LOG"
      fi
      if ! grep -qi "Resource busy" "$HDIUTIL_LOG" || [[ "$attempt" -eq 5 ]]; then
        exit "$hdiutil_status"
      fi
      echo "hdiutil hit a transient Resource busy error (attempt $attempt/5); retrying..."
      rm -f "$DMG"
      sleep "$((attempt * 5))"
      sync
    done
    test -s "$DMG"
    hdiutil verify "$DMG"

    APP_ZIP="$DIST/kirbysuperstar-$VERSION-$PLATFORM-app.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
    unzip -t "$APP_ZIP" >/dev/null
    ;;

  linux-x64)
    APPDIR="$WORK/AppDir"
    DATA="$APPDIR/usr/share/kirbysuperstar/setup-pack"
    mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
      "$APPDIR/usr/share/icons/hicolor/256x256/apps" "$DATA"
    cp -a "$PACK/." "$DATA/"
    if [[ ! -f "$PACK/KirbySuperStarSNESRecomp" ]]; then
      echo "::error::Linux setup host is missing from the portable ZIP." >&2
      exit 1
    fi
    cp "$PACK/KirbySuperStarSNESRecomp" "$APPDIR/usr/bin/KirbySuperStarSNESRecomp"
    chmod +x "$APPDIR/usr/bin/KirbySuperStarSNESRecomp"

    cat > "$APPDIR/AppRun" <<'APP_RUN'
#!/bin/bash
set -euo pipefail

APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
PACK="$APPDIR/usr/share/kirbysuperstar/setup-pack"
DATA="$HOME/.local/share/NVDEMU/Kirby Super Star Recomp"
MARKER="$DATA/.appimage-bundle-provenance.json"
PROVENANCE="$PACK/update/BUILD_PROVENANCE.json"
UPDATED=0
LOG_DIR="$HOME/.local/state/NVDEMU/Kirby Super Star Recomp"
mkdir -p "$LOG_DIR" || exit 1
exec >>"$LOG_DIR/launcher.log" 2>&1
echo
echo "===== Kirby Super Star Recomp AppImage: $(date) ====="

fail() {
  echo "ERROR: $*" >&2
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title="Kirby Super Star Recomp" --text="$*" >/dev/null 2>&1 || true
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --error "$*" --title "Kirby Super Star Recomp" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "Kirby Super Star Recomp could not start" "$*" >/dev/null 2>&1 || true
  fi
  exit 1
}

[ -d "$PACK" ] || fail "The AppImage is missing its setup-pack resources."
[ -f "$PROVENANCE" ] || fail "The setup pack is missing its provenance metadata."
mkdir -p "$DATA" || fail "Could not create the writable setup folder."

if [ ! -f "$MARKER" ] || ! cmp -s "$MARKER" "$PROVENANCE"; then
  echo "Syncing application files into: $DATA (preserving local ROM and player data)"
  # Stream tar directly between processes: unlike cp -a, this excludes local
  # user state while still replacing shipped application files for new builds.
  # No giant temporary archive is written to the user's disk.
  if ! tar -C "$PACK" \
    --exclude='./rom.cfg' \
    --exclude='./config.ini' \
    --exclude='./keybinds.ini' \
    --exclude='./input.ini' \
    --exclude='./controller.ini' \
    --exclude='./settings.toml' \
    --exclude='./game_options.toml' \
    --exclude='./saves' \
    --exclude='./build' \
    --exclude='./src/gen' \
    --exclude='./recomp/funcs.h' \
    --exclude='./mods/state.toml' \
    --exclude='./mods/custom' \
    --exclude='./mods/installed' \
    -cf - . | tar -C "$DATA" -xf -; then
    fail "Could not install the AppImage's files. See $LOG_DIR/launcher.log."
  fi
  cp "$PROVENANCE" "$MARKER.tmp.$" || fail "Could not write application update marker."
  mv -f "$MARKER.tmp.$" "$MARKER" || fail "Could not activate application update marker."
  UPDATED=1
fi

HOST="$DATA/KirbySuperStarSNESRecomp"
[ -f "$HOST" ] || fail "Setup-host executable is missing at $HOST."
chmod u+x "$HOST" || fail "Could not mark setup-host executable as runnable."
ANALYZER="$DATA/snesrecomp/recompiler-rs/target/release/snesrecomp-analyze"
if [ -f "$ANALYZER" ]; then
  chmod u+x "$ANALYZER" || fail "Could not mark the bundled analyzer as runnable."
fi

export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$DATA" || fail "Could not enter the writable setup folder."
if [ "$UPDATED" -eq 1 ]; then
  # A refreshed source pack must not jump into the pre-update build/.
  echo "Updated source pack detected; keeping the setup UI open for Generate & rebuild."
  export SNESRECOMP_NO_HANDOFF=1
  export SNESRECOMP_FORCE_SETUP=1
fi
echo "Launching setup host: $HOST"
set +e
"$HOST" "$@"
STATUS=$?
set -e
echo "Setup host exited with status $STATUS."
if [ "$STATUS" -ne 0 ]; then
  fail "Setup host exited with code $STATUS. See $LOG_DIR/launcher.log."
fi
exit 0
APP_RUN
    chmod +x "$APPDIR/AppRun"
    # Validate the generated launcher before it is packed into the AppImage.
    bash -n "$APPDIR/AppRun"
    test -x "$APPDIR/AppRun"
    test -x "$APPDIR/usr/bin/KirbySuperStarSNESRecomp"

    cat > "$APPDIR/usr/share/applications/kirbysuperstar.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Kirby Super Star Recomp
Comment=Build and play from your own verified Kirby Super Star ROM
Exec=AppRun
Icon=kirbysuperstar
Categories=Game;
Terminal=false
DESKTOP
    cat > "$APPDIR/usr/share/icons/hicolor/256x256/apps/kirbysuperstar.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect x="8" y="8" width="240" height="240" rx="56" fill="#f3a2c5"/>
  <circle cx="128" cy="128" r="78" fill="#fff0f6"/>
  <path d="M82 88 L82 168 L107 168 L107 143 L125 128 L107 112 L107 88 Z" fill="#b21b58"/>
  <path d="M139 88 L174 88 L174 110 L151 110 L151 119 L170 119 L170 139 L151 139 L151 146 L175 146 L175 168 L139 168 Z" fill="#b21b58"/>
</svg>
SVG

    LINUXDEPLOY="$WORK/linuxdeploy-x86_64.AppImage"
    curl --fail --location --retry 3 --silent --show-error \
      https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage \
      --output "$LINUXDEPLOY"
    chmod +x "$LINUXDEPLOY"
    ARCH=x86_64 "$LINUXDEPLOY" --appimage-extract-and-run \
      --appdir "$APPDIR" \
      --executable "$APPDIR/usr/bin/KirbySuperStarSNESRecomp" \
      --desktop-file "$APPDIR/usr/share/applications/kirbysuperstar.desktop" \
      --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/kirbysuperstar.svg" \
      --output appimage
    APPIMAGE="$(find "$ROOT" -maxdepth 1 -type f -name '*.AppImage' -print -quit)"
    [[ -n "$APPIMAGE" ]] || { echo "::error::linuxdeploy did not produce an AppImage." >&2; exit 1; }
    mv "$APPIMAGE" "$DIST/kirbysuperstar-$VERSION-linux-x64.AppImage"
    chmod +x "$DIST/kirbysuperstar-$VERSION-linux-x64.AppImage"
    file "$DIST/kirbysuperstar-$VERSION-linux-x64.AppImage"
    ;;

  *)
    echo "::error::Unsupported native release platform: $PLATFORM" >&2
    exit 2
    ;;
esac

echo "Native release package(s) created:"
find "$DIST" -maxdepth 1 -type f \( \
  -name "kirbysuperstar-$VERSION-windows-x64.exe" -o \
  -name "kirbysuperstar-$VERSION-macos-*.dmg" -o \
  -name "kirbysuperstar-$VERSION-macos-*-app.zip" -o \
  -name "kirbysuperstar-$VERSION-linux-x64.AppImage" \) -print
