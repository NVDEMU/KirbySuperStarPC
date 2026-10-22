#!/usr/bin/env bash
# Package a Kirby Super Star release: a SETUP PACK.
#
# The zip does not contain the game. It contains a setup program (the host
# built with -DSNESRECOMP_SETUP_HOST=ON, i.e. without recompiled code), the
# recompiler and this source tree. On first run the player picks their own
# ROM and the launcher recompiles and rebuilds locally. No ROM, no src/gen,
# no recomp/funcs.h ever leaves this tree in a zip -- the framework's packager
# enforces that mechanically.
#
# Usage:
#   scripts/package_release.sh [<build-dir>] [<platform-tag>] [--embed-toolchain]
#
# Both positionals are optional; BUILD_DIR and PLATFORM still work as env vars.
# Defaults: build, and the host's own <os>-<arch>. --embed-toolchain copies
# the cmake-clang-v1 pack named by RETCOMM_TOOLCHAIN_DIR into the zip so the
# player downloads nothing.
#
# Writes: dist/kirbysuperstar-<VERSION>-<platform-tag>.zip
set -euo pipefail

# A silent exit is the worst outcome a packaging step can have: the first
# Windows CI run died here with exit 1 and not one line of output. Name the
# command and line instead of leaving the reader to bisect a shell script.
trap 'echo "::error::$(basename "${BASH_SOURCE[0]}") failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

EXTRA=()
POS=()
for a in "$@"; do
  case "$a" in
    --embed-toolchain|--no-embed-toolchain) EXTRA+=("$a") ;;
    *) POS+=("$a") ;;
  esac
done
BUILD_DIR="${POS[0]:-${BUILD_DIR:-build}}"
PLATFORM="${POS[1]:-${PLATFORM:-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)}}"

IMPL="snesrecomp/tools/ci/stage_setup_host.sh"
if [ ! -f "$IMPL" ]; then
  echo "package_release.sh: $IMPL missing — the snesrecomp pin predates setup packs." >&2
  echo "  Update the submodule: git submodule update --init --recursive" >&2
  exit 1
fi

# The ROM hint and digests come from rom_identity.txt -- the same file the
# build compiles in and tools/regen.sh verifies against -- so a revision bump
# is one edit. stage_setup_host.sh already needs python3, so this does too.
IDENTITY_TOOL="snesrecomp/tools/rom_identity.py"
ROM_FILE="$(python3 "$IDENTITY_TOOL" rom_identity.txt --get rom_file)"
ROM_SHA256="$(python3 "$IDENTITY_TOOL" rom_identity.txt --get expected_sha256)"
ROM_CRC32="$(python3 "$IDENTITY_TOOL" rom_identity.txt --get expected_crc32)"

# Stage the updater beside the host executable. The same updater is
# copied by CMake for local builds; official setup packs also carry provenance
# and a CA bundle so TLS verification works with the portable Python runtime.
HOST=""
for candidate in "$BUILD_DIR/KirbySuperStarSNESRecomp.exe" \
                 "$BUILD_DIR/Release/KirbySuperStarSNESRecomp.exe" \
                 "$BUILD_DIR/KirbySuperStarSNESRecomp"; do
  if [[ -f "$candidate" ]]; then HOST="$candidate"; break; fi
done
if [[ -z "$HOST" ]]; then
  echo "package_release.sh: KirbySuperStarSNESRecomp not found under $BUILD_DIR" >&2
  exit 1
fi
HOST_DIR="$(cd "$(dirname "$HOST")" && pwd)"
UPDATE_DIR="$HOST_DIR/update"
mkdir -p "$UPDATE_DIR"
cp tools/in_app_updater.py "$UPDATE_DIR/updater.py"
curl -fsSL --retry 5 --retry-delay 2 \
  -o "$UPDATE_DIR/cacert.pem" https://curl.se/ca/cacert.pem
if ! grep -q 'BEGIN CERTIFICATE' "$UPDATE_DIR/cacert.pem"; then
  echo "error: updater CA bundle download is empty or invalid" >&2
  exit 1
fi
COMMIT_ID="$(git rev-parse HEAD)"
PACK_VERSION="${RELEASE_VERSION:-$(tr -d '[:space:]' < VERSION)}"
printf '{\n  "repository": "NVDEMU/KirbySuperStarPC",\n  "commit": "%s",\n  "version": "%s",\n  "platform": "%s"\n}\n' \
  "$COMMIT_ID" "$PACK_VERSION" "$PLATFORM" > "$UPDATE_DIR/BUILD_PROVENANCE.json"

# The portable ZIP is a setup pack, not a precompiled game. The player creates
# ROM-derived code locally; the updater preserves it and reopens the setup host
# so the player can run Generate & rebuild after a Nightly source update.
bash "$IMPL" \
  --runtime-dir mods \
  --runtime-dir update \
  --build-dir "$BUILD_DIR" \
  --artifact "$PLATFORM" \
  --exe-name KirbySuperStarSNESRecomp \
  --zip-prefix kirbysuperstar \
  --display-name "Kirby Super Star" \
  --rom-hint "$ROM_FILE" \
  --rom-sha256 "$ROM_SHA256" \
  --rom-crc32 "$ROM_CRC32" \
  "${EXTRA[@]+"${EXTRA[@]}"}"
