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
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    zf.extractall(sys.argv[2])
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
    "$CSC" /nologo /target:winexe \
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

    # Copy into a writable per-user folder on first run or after a new app
    # bundle is installed. A separate marker prevents an old app bundle from
    # reverting a newer Nightly installed by the in-app updater.
    cat > "$MACOS/KirbySuperStarRecomp" <<'APP_LAUNCHER'
#!/bin/sh
set -eu
APP_PACK="$(cd "$(dirname "$0")/../Resources/setup-pack" && pwd)"
DATA="$HOME/Library/Application Support/NVDEMU/Kirby Super Star Recomp"
PROVENANCE="$APP_PACK/update/BUILD_PROVENANCE.json"
MARKER="$DATA/.app-bundle-provenance.json"
mkdir -p "$DATA"
if [ ! -f "$MARKER" ] || ! cmp -s "$MARKER" "$PROVENANCE"; then
  /usr/bin/ditto "$APP_PACK" "$DATA"
  cp "$PROVENANCE" "$MARKER"
fi
cd "$DATA"
exec "$DATA/KirbySuperStarSNESRecomp" "$@"
APP_LAUNCHER
    chmod +x "$MACOS/KirbySuperStarRecomp"

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
    hdiutil create -volname "Kirby Super Star Recomp" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
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
#!/bin/sh
set -eu
APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PACK="$APPDIR/usr/share/kirbysuperstar/setup-pack"
DATA="$HOME/.local/share/NVDEMU/Kirby Super Star Recomp"
MARKER="$DATA/.appimage-bundle-provenance.json"
PROVENANCE="$PACK/update/BUILD_PROVENANCE.json"
mkdir -p "$DATA"
if [ ! -f "$MARKER" ] || ! cmp -s "$MARKER" "$PROVENANCE"; then
  cp -a "$PACK/." "$DATA/"
  cp "$PROVENANCE" "$MARKER"
fi
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/x86_64-linux-gnu"
cd "$DATA"
exec "$DATA/KirbySuperStarSNESRecomp" "$@"
APP_RUN
    chmod +x "$APPDIR/AppRun"

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
