#!/usr/bin/env bash
# Bundle every non-system dylib used by a staged playable macOS executable.
# Homebrew paths must never leak into a portable .app / DMG.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: bundle_macos_dylibs.sh MAIN_EXECUTABLE LIBRARY_DIRECTORY" >&2
  exit 2
fi
MAIN_EXE="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
LIB_DIR="$2"
mkdir -p "$LIB_DIR"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: macOS dylib bundling requires otool, install_name_tool and codesign." >&2
  exit 1
fi
[[ -x "$MAIN_EXE" ]] || { echo "error: missing executable: $MAIN_EXE" >&2; exit 1; }

python3 - "$MAIN_EXE" "$LIB_DIR" <<'PY'
import os
import re
import shutil
import subprocess
import sys
from collections import deque
from pathlib import Path

main = Path(sys.argv[1]).resolve()
lib_dir = Path(sys.argv[2]).resolve()
main_dir = main.parent
lib_dir.mkdir(parents=True, exist_ok=True)

def run(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def install_id(binary):
    # otool -L includes a dylib's LC_ID_DYLIB as its first listed name.
    # It is not a dependency and must not be resolved/re-written with -change.
    lines = run(["otool", "-D", str(binary)]).splitlines()[1:]
    for line in lines:
        value = line.strip()
        if value:
            return value
    return None

def dependencies(binary):
    lines = run(["otool", "-L", str(binary)]).splitlines()[1:]
    result = []
    for line in lines:
        item = line.strip().split(" (compatibility version ", 1)[0]
        if item:
            result.append(item)
    identity = install_id(binary)
    if identity is not None:
        result = [item for item in result if item != identity]
    return result

def rpaths(binary):
    lines = run(["otool", "-l", str(binary)]).splitlines()
    found = []
    for i, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for following in lines[i + 1:i + 5]:
            match = re.match(r"\s*path (.*?) \(offset \d+\)$", following)
            if match:
                found.append(match.group(1))
                break
    return found

def is_system_path(path):
    value = str(path)
    return (
        value.startswith("/System/Library/")
        or value == "/System/Library"
        or value.startswith("/usr/lib/")
        or value == "/usr/lib"
        or value.startswith("/System/Volumes/Preboot/Cryptexes/OS/")
    )

def expand_rpath(raw, consumer):
    if raw.startswith("@loader_path/"):
        return consumer.parent / raw[len("@loader_path/"):]
    if raw == "@loader_path":
        return consumer.parent
    if raw.startswith("@executable_path/"):
        return main_dir / raw[len("@executable_path/"):]
    if raw == "@executable_path":
        return main_dir
    if raw.startswith("/"):
        return Path(raw)
    return None

def resolve_dependency(raw, consumer):
    if raw.startswith("/"):
        candidate = Path(raw)
        if is_system_path(candidate):
            return candidate
        return candidate.resolve() if candidate.is_file() else None
    if raw.startswith("@loader_path/"):
        candidate = consumer.parent / raw[len("@loader_path/"):]
        return candidate.resolve() if candidate.is_file() else None
    if raw == "@loader_path":
        candidate = consumer.parent
        return candidate.resolve() if candidate.is_file() else None
    if raw.startswith("@executable_path/"):
        candidate = main_dir / raw[len("@executable_path/"):]
        return candidate.resolve() if candidate.is_file() else None
    if raw == "@executable_path":
        return main_dir.resolve()

    if raw.startswith("@rpath/"):
        suffix = raw[len("@rpath/"):]
        for value in rpaths(consumer):
            base = expand_rpath(value, consumer)
            if base is None:
                continue
            candidate = base / suffix
            if candidate.is_file():
                return candidate.resolve()
        # Some SDK-linked Apple system frameworks are represented as @rpath
        # despite living in the canonical system framework locations.
        if ".framework/" in suffix:
            candidates = (
                Path("/System/Library/Frameworks") / suffix,
                Path("/System/Library/PrivateFrameworks") / suffix,
                Path("/System/iOSSupport/System/Library/Frameworks") / suffix,
            )
            for candidate in candidates:
                if candidate.is_file():
                    return candidate.resolve()
        return None

    return None

# Queue pairs original library paths with their staged copy. Inspect original
# install names/RPATHs to resolve dependencies, but patch only staged binaries.
pending = deque([(main, main)])
processed = set()
dest_sources = {}
staged_binaries = [main]

while pending:
    source, staged = pending.popleft()
    source = Path(source).resolve()
    staged = Path(staged).resolve()
    key = (str(source), str(staged))
    if key in processed:
        continue
    processed.add(key)

    # Give staged dylibs relocatable identities too; the loader does not need
    # Homebrew install names embedded in the copied library.
    if staged != main:
        source_identity = install_id(source)
        desired_identity = "@loader_path/" + staged.name
        if source_identity and source_identity != desired_identity:
            run(["install_name_tool", "-id", desired_identity, str(staged)])

    for load_name in dependencies(source):
        if is_system_path(load_name):
            continue
        resolved = resolve_dependency(load_name, source)
        if resolved is None:
            # Absolute system paths are handled above. Anything else that
            # cannot be found must fail the package rather than ship a broken app.
            raise SystemExit(
                "error: cannot resolve macOS runtime dependency "
                + repr(load_name) + " required by " + str(source)
            )
        if is_system_path(resolved):
            continue

        filename = Path(load_name).name
        if not filename or filename in (".", ".."):
            raise SystemExit("error: invalid dylib install name: " + repr(load_name))
        destination = lib_dir / filename
        previous = dest_sources.get(str(destination))
        if previous is not None and previous != str(resolved):
            raise SystemExit(
                "error: dylib filename collision for " + filename
                + ": " + previous + " and " + str(resolved)
            )
        dest_sources[str(destination)] = str(resolved)
        if not destination.exists():
            shutil.copy2(resolved, destination)
            staged_binaries.append(destination)
            pending.append((resolved, destination))
        else:
            if str(destination) not in {str(p.resolve()) for p in staged_binaries}:
                staged_binaries.append(destination)
                pending.append((resolved, destination))

        if staged == main:
            replacement = "@executable_path/lib/" + filename
        else:
            replacement = "@loader_path/" + filename
        if load_name != replacement:
            run(["install_name_tool", "-change", load_name, replacement, str(staged)])

# Validate the rewritten load commands from the packaged copy, not the source.
seen = set()
for binary in staged_binaries:
    binary = Path(binary).resolve()
    if str(binary) in seen:
        continue
    seen.add(str(binary))
    for load_name in dependencies(binary):
        if is_system_path(load_name):
            continue
        if load_name.startswith("@loader_path/"):
            candidate = binary.parent / load_name[len("@loader_path/"):]
            if not candidate.is_file():
                raise SystemExit(
                    "error: bundled dylib reference is missing: "
                    + str(binary) + " -> " + load_name
                )
            continue
        if load_name.startswith("@executable_path/"):
            candidate = main_dir / load_name[len("@executable_path/"):]
            if not candidate.is_file():
                raise SystemExit(
                    "error: bundled executable reference is missing: "
                    + str(binary) + " -> " + load_name
                )
            continue
        resolved = resolve_dependency(load_name, binary)
        if resolved is not None and is_system_path(resolved):
            continue
        raise SystemExit(
            "error: non-portable load path remains in " + str(binary)
            + ": " + load_name
        )

# Sign the rewritten game executable and copied dylibs before signing the outer
# app bundle. The game binary lives in Resources, so explicitly sign it rather
# than relying solely on codesign --deep to discover nested code there.
for binary in staged_binaries:
    binary = Path(binary)
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(binary)])
    run(["codesign", "--verify", "--strict", str(binary)])

print("Bundled and signed " + str(len(dest_sources)) + " non-system macOS dylib(s).")
for filename in sorted(Path(key).name for key in dest_sources):
    print("  " + filename)
PY
