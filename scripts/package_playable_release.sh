#!/usr/bin/env bash
# Build native playable release packages from an already configured playable build.
set -euo pipefail
ROOT="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_ARG="\${1:-build-playable}"
PLATFORM="\${2:?usage: package_playable_release.sh BUILD_DIR PLATFORM VERSION}"
VERSION="\${3:?usage: package_playable_release.sh BUILD_DIR PLATFORM VERSION}"
if [[ "$BUILD_ARG" = /* ]]; then BUILD_DIR="$(cd "$BUILD_ARG" && pwd -P)"; else BUILD_DIR="$(cd "$ROOT/$BUILD_ARG" && pwd -P)"; fi
CACHE="$BUILD_DIR/CMakeCache.txt"
[[ -f "$CACHE" ]] || { echo "error: missing CMake cache: $CACHE" >&2; exit 1; }
if grep -Eq '^SNESRECOMP_SETUP_HOST:BOOL=ON$' "$CACHE"; then echo "error: refusing to package setup host as playable." >&2; exit 1; fi
if [[ ! -f "$ROOT/recomp/funcs.h" ]] || ! find "$ROOT/src/gen" -maxdepth 1 -type f -name '*.c' -print -quit | grep -q .; then
  echo "error: generated game code missing; expected a playable build." >&2; exit 1
fi
case "$PLATFORM" in
  macos-arm64|macos-x64)
    KIRBY_RELEASE_ASSET_VERSION="$VERSION" KIRBY_RELEASE_PLATFORM="$PLATFORM" bash "$ROOT/scripts/package_playable_macos_app.sh" "$BUILD_DIR"
    ;;
  windows-x64)
    EXE="$BUILD_DIR/KirbySuperStarSNESRecomp.exe"
    [[ -s "$EXE" ]] || { echo "error: playable Windows executable missing: $EXE" >&2; exit 1; }
    DIST="$ROOT/dist"; mkdir -p "$DIST"
    ZIP="$DIST/kirbysuperstar-$VERSION-windows-x64-playable.zip"
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    python3 - "$BUILD_DIR" "$ZIP" "$VERSION" <<'PY'
import os, sys, zipfile
from pathlib import Path
build = Path(sys.argv[1]).resolve()
archive_path = Path(sys.argv[2])
version = sys.argv[3]
prefix = f"kirbysuperstar-{version}-windows-x64-playable/build"
exclude_dirs = {"CMakeFiles", "_deps", ".git", "saves"}
exclude_names = {"CMakeCache.txt","build.ninja",".ninja_deps",".ninja_log","cmake_install.cmake","Makefile","rules.ninja","rom.cfg","config.ini","keybinds.ini","input.ini","controller.ini","launcher-window.ini","settings.toml","game_options.toml"}
exclude_suffixes = {".o",".obj",".a",".sfc",".smc",".fig",".srm",".sav",".state"}
with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    for root, dirs, files in os.walk(build):
        dirs[:] = sorted(d for d in dirs if d not in exclude_dirs)
        for name in sorted(files):
            path = Path(root) / name
            rel = path.relative_to(build)
            if name in exclude_names or path.suffix.lower() in exclude_suffixes: continue
            if rel.parts and rel.parts[0] == "saves": continue
            if len(rel.parts) >= 2 and rel.parts[0] == "mods" and rel.parts[1] in {"custom","installed"}: continue
            if rel.as_posix() == "mods/state.toml": continue
            zf.write(path, f"{prefix}/{rel.as_posix()}")
with zipfile.ZipFile(archive_path) as zf:
    names = zf.namelist()
    if not any(n.endswith("/build/KirbySuperStarSNESRecomp.exe") for n in names): raise SystemExit("playable Windows executable missing from package")
    bad = [n for n in names if Path(n).suffix.lower() in {".sfc",".smc",".fig",".srm",".sav"} or Path(n).name.lower() == "rom.cfg"]
    if bad: raise SystemExit("refusing to package ROM/local data: " + ", ".join(bad))
print(f"Created playable Windows runtime ZIP: {archive_path}")
PY
    CSC="/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
    [[ -f "$CSC" ]] || CSC="/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"
    [[ -f "$CSC" ]] || { echo "error: csc.exe missing on Windows runner." >&2; exit 1; }
    OUT="$DIST/kirbysuperstar-$VERSION-windows-x64.exe"
    MSYS2_ARG_CONV_EXCL='*' "$CSC" /nologo /target:winexe "/out:$(cygpath -w "$OUT")" \
      /reference:System.Windows.Forms.dll /reference:System.Drawing.dll \
      /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll \
      "/resource:$(cygpath -w "$ZIP"),KirbyPlayablePack.zip" \
      "$(cygpath -w "$ROOT/scripts/windows_playable_installer.cs")"
    [[ -s "$OUT" ]] || { echo "error: playable Windows installer was not produced." >&2; exit 1; }
    ;;
  linux-x64)
    EXE="$BUILD_DIR/KirbySuperStarSNESRecomp"
    [[ -s "$EXE" ]] || { echo "error: playable Linux executable missing: $EXE" >&2; exit 1; }
    DIST="$ROOT/dist"; mkdir -p "$DIST"
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    APPDIR="$WORK/AppDir"; PLAY="$APPDIR/usr/share/kirbysuperstar/playable-build"
    mkdir -p "$PLAY" "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
    python3 - "$BUILD_DIR" "$PLAY" <<'PY'
import os, shutil, sys
from pathlib import Path
src, dst = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
skip_dirs = {"CMakeFiles","_deps",".git","saves"}
skip_names = {"CMakeCache.txt","build.ninja",".ninja_deps",".ninja_log","cmake_install.cmake","Makefile","rules.ninja","rom.cfg","config.ini","keybinds.ini","input.ini","controller.ini","launcher-window.ini","settings.toml","game_options.toml"}
skip_suffixes = {".o",".obj",".a",".sfc",".smc",".fig",".srm",".sav",".state"}
for root, dirs, files in os.walk(src):
    base = Path(root); rel_dir = base.relative_to(src)
    dirs[:] = sorted(d for d in dirs if d not in skip_dirs and not (rel_dir.as_posix() == "mods" and d in {"custom","installed"}))
    for name in sorted(files):
        s = base / name; rel = s.relative_to(src)
        if name in skip_names or s.suffix.lower() in skip_suffixes or rel.as_posix() == "mods/state.toml" or s.is_symlink(): continue
        d = dst / rel; d.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(s, d)
exe = dst / "KirbySuperStarSNESRecomp"
if not exe.is_file(): raise SystemExit("playable Linux executable missing from staged runtime")
exe.chmod(exe.stat().st_mode | 0o111)
print(f"Staged playable Linux runtime: {dst}")
PY
    cp "$PLAY/KirbySuperStarSNESRecomp" "$APPDIR/usr/bin/KirbySuperStarSNESRecomp"
    chmod +x "$APPDIR/usr/bin/KirbySuperStarSNESRecomp"
    cat > "$APPDIR/AppRun" <<APP_RUN
#!/bin/bash
set -euo pipefail
APPDIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd -P)"
PACK="\$APPDIR/usr/share/kirbysuperstar/playable-build"
DATA="\$HOME/.local/share/NVDEMU/Kirby Super Star Recomp/playable"
MARKER="\$DATA/.playable-build-version"
VERSION="$VERSION"
LOG_DIR="\$HOME/.local/state/NVDEMU/Kirby Super Star Recomp"
mkdir -p "\$LOG_DIR" "\$DATA" || exit 1
exec >>"\$LOG_DIR/playable-launcher.log" 2>&1
echo
echo "===== Kirby Super Star Recomp playable AppImage: \$(date) ====="
if [[ ! -f "\$MARKER" || "\$(cat "\$MARKER" 2>/dev/null || true)" != "\$VERSION" ]]; then
  tar -C "\$PACK" --exclude='./rom.cfg' --exclude='./config.ini' --exclude='./keybinds.ini' \
    --exclude='./input.ini' --exclude='./controller.ini' --exclude='./settings.toml' \
    --exclude='./game_options.toml' --exclude='./saves' --exclude='./mods/state.toml' \
    --exclude='./mods/custom' --exclude='./mods/installed' -cf - . | tar -C "\$DATA" --touch -xf -
  printf '%s\n' "\$VERSION" >"\$MARKER.tmp"; mv -f "\$MARKER.tmp" "\$MARKER"
fi
[[ -x "\$DATA/KirbySuperStarSNESRecomp" ]] || chmod u+x "\$DATA/KirbySuperStarSNESRecomp"
export LD_LIBRARY_PATH="\$APPDIR/usr/lib:\$APPDIR/usr/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
cd "\$DATA"
exec "\$DATA/KirbySuperStarSNESRecomp" "\$@"
APP_RUN
    chmod +x "$APPDIR/AppRun"; bash -n "$APPDIR/AppRun"
    cat > "$APPDIR/usr/share/applications/kirbysuperstar.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Kirby Super Star Recomp
Comment=Playable native build; supply your own verified ROM
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
      https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage --output "$LINUXDEPLOY"
    chmod +x "$LINUXDEPLOY"
    ARCH=x86_64 "$LINUXDEPLOY" --appimage-extract-and-run --appdir "$APPDIR" \
      --executable "$APPDIR/usr/bin/KirbySuperStarSNESRecomp" \
      --desktop-file "$APPDIR/usr/share/applications/kirbysuperstar.desktop" \
      --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/kirbysuperstar.svg" --output appimage
    APPIMAGE="$(find "$ROOT" -maxdepth 1 -type f -name '*.AppImage' -print -quit)"
    [[ -n "$APPIMAGE" ]] || { echo "error: linuxdeploy did not produce an AppImage." >&2; exit 1; }
    mv "$APPIMAGE" "$DIST/kirbysuperstar-$VERSION-linux-x64.AppImage"
    chmod +x "$DIST/kirbysuperstar-$VERSION-linux-x64.AppImage"
    ;;
  *) echo "error: unsupported platform: $PLATFORM" >&2; exit 2 ;;
esac
echo "Playable release assets produced for $PLATFORM."
find "$ROOT/dist" -maxdepth 1 -type f \( -name "kirbysuperstar-$VERSION-$PLATFORM*.zip" -o -name "kirbysuperstar-$VERSION-$PLATFORM.exe" -o -name "kirbysuperstar-$VERSION-$PLATFORM.dmg" -o -name "kirbysuperstar-$VERSION-$PLATFORM.AppImage" \) -print
