#!/usr/bin/env python3
"""Update the Kirby Super Star Recomp setup pack from the official Nightly release.

The game itself is rebuilt locally from the player's own ROM. This updater
installs source/setup-pack files only and never downloads or ships ROM data.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import platform
import shutil
import signal
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

REPOSITORY = "NVDEMU/KirbySuperStarPC"
RELEASE_TAG = "Nightly"
API_RELEASE = f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{RELEASE_TAG}"
USER_AGENT = "nvd123-KirbySuperStarPC-Updater/1.0"
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
DETACHED_PROCESS = getattr(subprocess, "DETACHED_PROCESS", 0)
RUNTIME_TEMP_ENV = "KIRBY_UPDATER_RUNTIME_TEMP"
BOOTSTRAPPED_ENV = "KIRBY_UPDATER_BOOTSTRAPPED"
EXE_STEM = "KirbySuperStarSNESRecomp"


def _apple_script_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def notify(message: str, title: str = "Kirby Super Star Recomp Updater",
           kind: str = "info") -> None:
    if os.name == "nt":
        icon = {"error": 0x10, "warning": 0x30}.get(kind, 0x40)
        ctypes.windll.user32.MessageBoxW(None, message, title, 0x00000000 | icon)
    elif sys.platform == "darwin":
        script = (
            f'display alert "{_apple_script_string(title)}" '
            f'message "{_apple_script_string(message)}" '
            f'as {"critical" if kind == "error" else "warning" if kind == "warning" else "informational"}'
        )
        result = subprocess.run(["/usr/bin/osascript", "-e", script],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                check=False)
        if result.returncode != 0:
            print(f"{title}: {message}", file=sys.stderr if kind == "error" else sys.stdout)
    else:
        print(f"{title}: {message}", file=sys.stderr if kind == "error" else sys.stdout)


def ask_yes_no(message: str, title: str = "Kirby Super Star Recomp Updater") -> bool:
    if os.name == "nt":
        result = ctypes.windll.user32.MessageBoxW(
            None, message, title, 0x00000004 | 0x00000020 | 0x00010000
        )
        return result == 6
    if sys.platform == "darwin":
        script = (
            f'display dialog "{_apple_script_string(message)}" '
            f'with title "{_apple_script_string(title)}" '
            'buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel"'
        )
        result = subprocess.run(["/usr/bin/osascript", "-e", script],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, check=False)
        return result.returncode == 0 and "button returned:Continue" in result.stdout
    return False


def _https_context() -> ssl.SSLContext:
    """Use the bundled CA root set when packaged, with normal TLS checks always on."""
    ca_file = Path(__file__).resolve().with_name("cacert.pem")
    if ca_file.is_file():
        try:
            return ssl.create_default_context(cafile=str(ca_file))
        except (OSError, ssl.SSLError) as exc:
            raise RuntimeError(f"The updater CA certificate file could not be loaded: {ca_file}") from exc
    return ssl.create_default_context()


def http_bytes(url: str, timeout: int = 45) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json",
                 "Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(request, timeout=timeout, context=_https_context()) as response:
        return response.read()


def get_json(url: str) -> dict[str, Any]:
    data = json.loads(http_bytes(url).decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("GitHub returned an unexpected JSON response.")
    return data


def local_provenance(install_root: Path) -> dict[str, Any]:
    path = install_root / "update" / "BUILD_PROVENANCE.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def platform_suffixes() -> tuple[str, str]:
    if os.name == "nt":
        return "-windows-x64.zip", "SHA256SUMS-windows-x64.txt"
    if sys.platform == "darwin":
        machine = platform.machine().lower()
        if machine in ("arm64", "aarch64"):
            return "-macos-arm64.zip", "SHA256SUMS-macos-arm64.txt"
        if machine in ("x86_64", "amd64"):
            return "-macos-x64.zip", "SHA256SUMS-macos-x64.txt"
        raise RuntimeError(f"Unsupported Mac architecture: {machine}")
    raise RuntimeError(
        "The in-app installer supports Windows and macOS. On Linux, download the "
        "latest linux-x64 setup ZIP from the Nightly GitHub Release and unpack it "
        "over your setup-pack folder."
    )


def _official_asset_url(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    return (
        parsed.scheme == "https"
        and parsed.hostname == "github.com"
        and parsed.path.startswith(f"/{REPOSITORY}/releases/download/{RELEASE_TAG}/")
    )


def download_to(url: str, destination: Path) -> None:
    if not _official_asset_url(url):
        raise RuntimeError("GitHub returned an unexpected asset URL; the download was refused.")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180, context=_https_context()) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output, length=1024 * 1024)
    if not destination.is_file() or destination.stat().st_size == 0:
        raise RuntimeError("GitHub returned an empty download.")


def checksum_for_asset(text: str, filename: str) -> str:
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or parts[1].strip().lstrip("*") != filename:
            continue
        digest = parts[0].lower()
        if len(digest) == 64:
            try:
                int(digest, 16)
                return digest
            except ValueError:
                pass
    raise RuntimeError(f"The release checksum file does not contain {filename}.")


def verify_archive_paths(archive_path: Path, allow_symlinks: bool) -> str:
    """Validate paths and return the one allowed top-level setup-pack directory."""
    seen: set[str] = set()
    roots: set[str] = set()
    with zipfile.ZipFile(archive_path, "r") as archive:
        for info in archive.infolist():
            name = info.filename
            if not name or "\\" in name:
                raise RuntimeError("The update archive has an invalid path.")
            rel = PurePosixPath(name)
            if rel.is_absolute() or any(part in ("..", "") for part in rel.parts):
                raise RuntimeError("The update archive contains a path outside its install folder.")
            if not rel.parts or ":" in rel.parts[0]:
                raise RuntimeError("The update archive contains a drive-qualified path.")
            normalized = str(rel)
            if normalized in seen:
                raise RuntimeError("The update archive contains duplicate paths.")
            seen.add(normalized)
            roots.add(rel.parts[0])
            mode = (info.external_attr >> 16) & 0xFFFF
            if stat.S_ISLNK(mode):
                if not allow_symlinks:
                    raise RuntimeError("Windows updates must not contain symbolic links.")
                try:
                    target_text = archive.read(info).decode("utf-8")
                except (UnicodeDecodeError, OSError) as exc:
                    raise RuntimeError("The update archive contains an invalid symbolic link.") from exc
                target = PurePosixPath(target_text)
                if not target_text or target.is_absolute() or "\\" in target_text:
                    raise RuntimeError("The update archive contains an unsafe symbolic link.")
                stack = list(rel.parent.parts)
                for part in target.parts:
                    if part in ("", "."):
                        continue
                    if part == "..":
                        if len(stack) <= 1:
                            raise RuntimeError("The update archive contains an escaping symbolic link.")
                        stack.pop()
                    else:
                        stack.append(part)
    if len(roots) != 1:
        raise RuntimeError("The update ZIP must contain exactly one setup-pack directory.")
    root_name = next(iter(roots))
    if not root_name.startswith("kirbysuperstar-"):
        raise RuntimeError("The update ZIP does not look like an official Kirby setup pack.")
    return root_name


def extract_setup_pack(archive_path: Path, staging: Path, allow_symlinks: bool) -> Path:
    root_name = verify_archive_paths(archive_path, allow_symlinks)
    package_root = staging / root_name
    package_root.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path, "r") as archive:
        # Direct extraction is avoided so symlinks and executable bits are handled
        # explicitly after the complete archive has passed path validation.
        for info in archive.infolist():
            member = PurePosixPath(info.filename)
            relative = PurePosixPath(*member.parts[1:])
            if not relative.parts:
                continue
            target = package_root.joinpath(*relative.parts)
            mode = (info.external_attr >> 16) & 0xFFFF
            if info.is_dir() or info.filename.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if stat.S_ISLNK(mode):
                link_target = archive.read(info).decode("utf-8")
                if target.exists() or target.is_symlink():
                    raise RuntimeError("The update archive contains a duplicate symbolic link.")
                target.symlink_to(link_target)
                continue
            with archive.open(info, "r") as source, target.open("wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            permissions = mode & 0o777
            if permissions:
                target.chmod(permissions)
    return package_root


def _remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path)


PRESERVED_ROOTS = {
    "saves", "rom.cfg", "settings.toml", "config.ini", "controller.ini",
    "keybinds.ini", "input.ini", "launcher-window.ini", "game_options.toml",
    "disc.cfg", "bios.cfg",
}


def should_preserve_path(relative: Path) -> bool:
    if not relative.parts:
        return True
    parts = relative.parts
    if parts[0] in PRESERVED_ROOTS:
        return True
    # Player-owned or ROM-derived content must never be replaced by a setup pack.
    if parts[0] == "build":
        return True
    if parts[0] == "src" and len(parts) >= 2 and parts[1] == "gen":
        return True
    if parts[0] == "recomp" and len(parts) >= 2 and parts[1] == "funcs.h":
        return True
    if parts[0] == "mods" and len(parts) >= 2 and parts[1] in ("state.toml", "custom", "installed"):
        return True
    if relative.suffix.lower() in {".srm", ".sav", ".sna", ".state"}:
        return True
    return False


def _install_item(source: Path, destination: Path) -> None:
    if source.is_dir() and not source.is_symlink():
        if destination.exists() and not destination.is_dir():
            raise RuntimeError(f"Refusing to replace a user file with a directory: {destination.name}")
        destination.mkdir(parents=True, exist_ok=True)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        if destination.exists() and destination.is_dir() and not destination.is_symlink():
            raise RuntimeError(f"Refusing to replace a user directory with a symlink: {destination.name}")
        temporary = destination.with_name(destination.name + f".kirby-update-{os.getpid()}.tmp")
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(os.readlink(source), target_is_directory=source.is_dir())
        os.replace(temporary, destination)
        return
    if destination.exists() and destination.is_dir():
        raise RuntimeError(f"Refusing to replace a user directory with a file: {destination.name}")
    temporary = destination.with_name(destination.name + f".kirby-update-{os.getpid()}.tmp")
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def install_setup_pack(archive_path: Path, install_root: Path, staging_parent: Path) -> Path:
    extracted = staging_parent / "extracted"
    extracted.mkdir(parents=True, exist_ok=True)
    package_root = extract_setup_pack(
        archive_path, extracted, allow_symlinks=(sys.platform == "darwin")
    )
    executable_name = EXE_STEM + (".exe" if os.name == "nt" else "")
    if not (package_root / executable_name).is_file():
        raise RuntimeError(f"The update ZIP is missing {executable_name}.")
    if not (package_root / "update" / "updater.py").is_file():
        raise RuntimeError("The update ZIP is missing its updater helper.")
    if not (package_root / "update" / "BUILD_PROVENANCE.json").is_file():
        raise RuntimeError("The update ZIP is missing its build provenance metadata.")

    install_root = install_root.resolve()
    if not install_root.is_dir():
        raise RuntimeError("The setup-pack installation folder no longer exists.")
    # Stage/validate every incoming path before touching the installed copy.
    for source in sorted(package_root.rglob("*")):
        relative = source.relative_to(package_root)
        if should_preserve_path(relative):
            continue
        destination = install_root / relative
        _install_item(source, destination)
    return install_root / executable_name


def wait_for_parent_exit(pid: int) -> None:
    if pid <= 0:
        return
    if os.name == "nt":
        process = ctypes.windll.kernel32.OpenProcess(0x00100000, False, pid)
        if process:
            try:
                ctypes.windll.kernel32.WaitForSingleObject(process, 0xFFFFFFFF)
            finally:
                ctypes.windll.kernel32.CloseHandle(process)
        return
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            return
        time.sleep(0.5)


def detached_runtime_bootstrap(argv: list[str]) -> bool:
    """Use a temporary copy of bundled Python so updating toolchain files is safe."""
    if os.environ.get(BOOTSTRAPPED_ENV) == "1":
        return False
    executable = Path(sys.executable).resolve()
    lowered = [part.lower() for part in executable.parts]
    if "toolchain" not in lowered or "python" not in lowered:
        return False

    try:
        python_index = max(i for i, part in enumerate(lowered) if part == "python")
    except ValueError:
        return False
    python_root = Path(*executable.parts[:python_index + 1])
    if not python_root.is_dir():
        return False
    try:
        relative_interpreter = executable.relative_to(python_root)
    except ValueError:
        return False

    temp_root = Path(tempfile.mkdtemp(prefix="kirby-updater-runtime-"))
    copied_python = temp_root / "python"
    shutil.copytree(python_root, copied_python, dirs_exist_ok=True, symlinks=True)
    staged_script = temp_root / "updater.py"
    shutil.copy2(Path(__file__).resolve(), staged_script)
    source_ca = Path(__file__).resolve().with_name("cacert.pem")
    if source_ca.is_file():
        shutil.copy2(source_ca, temp_root / "cacert.pem")
    interpreter = copied_python / relative_interpreter
    if not interpreter.is_file():
        shutil.rmtree(temp_root, ignore_errors=True)
        raise RuntimeError("Could not start the updater from its temporary Python runtime.")

    env = os.environ.copy()
    env[BOOTSTRAPPED_ENV] = "1"
    env[RUNTIME_TEMP_ENV] = str(temp_root)
    flags = (DETACHED_PROCESS | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) |
             CREATE_NO_WINDOW) if os.name == "nt" else 0
    subprocess.Popen(
        [str(interpreter), str(staged_script), *argv],
        env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, creationflags=flags,
        start_new_session=(os.name != "nt"), close_fds=(os.name != "nt"),
    )
    return True


def cleanup_bootstrap_runtime() -> None:
    temp = os.environ.get(RUNTIME_TEMP_ENV)
    if not temp:
        return
    root = Path(temp)
    if os.name == "nt":
        command = f'for /L %i in (1,1,4) do @ping 127.0.0.1 -n 2 >nul & rmdir /s /q "{root}"'
        subprocess.Popen(["cmd.exe", "/c", command], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS)
    else:
        shutil.rmtree(root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--install-root", required=True, type=Path)
    parser.add_argument("--parent-pid", type=int, required=True)
    args = parser.parse_args()
    install_root = args.install_root.resolve()
    work: Path | None = None

    try:
        suffix, checksum_name = platform_suffixes()
        local = local_provenance(install_root)
        local_commit = str(local.get("commit", "")).lower()

        release = get_json(API_RELEASE)
        if release.get("draft") or release.get("tag_name") != RELEASE_TAG:
            raise RuntimeError("GitHub did not return the official Kirby Nightly release.")
        assets_list = release.get("assets", [])
        if not isinstance(assets_list, list):
            raise RuntimeError("GitHub returned an invalid Nightly asset list.")
        assets = {str(item.get("name", "")): item for item in assets_list if isinstance(item, dict)}
        manifest_asset = assets.get("nightly-manifest.json")
        if not manifest_asset:
            raise RuntimeError("The Nightly release is missing updater metadata. Download the newest pack manually.")
        manifest_url = str(manifest_asset.get("browser_download_url", ""))
        if not _official_asset_url(manifest_url):
            raise RuntimeError("The Nightly manifest URL is not an official Kirby release asset.")
        manifest = get_json(manifest_url)
        if manifest.get("repository") != REPOSITORY or manifest.get("channel") != "nightly":
            raise RuntimeError("The release metadata is not for the official Kirby Super Star Nightly channel.")
        remote_commit = str(manifest.get("commit", "")).lower()
        if len(remote_commit) != 40 or any(ch not in "0123456789abcdef" for ch in remote_commit):
            raise RuntimeError("The Nightly metadata contains an invalid commit ID.")
        if local_commit and local_commit == remote_commit:
            notify(f"You are already up to date.\nInstalled commit: {remote_commit[:12]}")
            return 0

        packages = [item for item in assets_list
                    if isinstance(item, dict) and str(item.get("name", "")).endswith(suffix)]
        if not packages:
            raise RuntimeError(f"The Nightly release has no package for this platform ({suffix}).")
        packages.sort(key=lambda item: str(item.get("updated_at", "")), reverse=True)
        package = packages[0]
        checksum_asset = assets.get(checksum_name)
        if not checksum_asset:
            raise RuntimeError(f"The Nightly release is missing {checksum_name}.")

        package_name = str(package.get("name", ""))
        package_url = str(package.get("browser_download_url", ""))
        checksum_url = str(checksum_asset.get("browser_download_url", ""))
        if not _official_asset_url(package_url) or not _official_asset_url(checksum_url):
            raise RuntimeError("The Nightly download links are not official Kirby release assets.")

        version = str(manifest.get("version", "Nightly"))
        if not ask_yes_no(
            f"A Kirby Super Star Recomp Nightly update is available.\n\n"
            f"Latest version: {version}\nLatest commit: {remote_commit[:12]}\n"
            f"Installed commit: {local_commit[:12] if local_commit else 'unknown'}\n\n"
            "Download and verify the platform-specific setup pack now?"
        ):
            return 0

        work = Path(tempfile.mkdtemp(prefix="kirby-nightly-update-"))
        package_path = work / package_name
        checksum_path = work / checksum_name
        notify("Downloading the Nightly setup pack and SHA-256 checksum. This may take a while.")
        download_to(package_url, package_path)
        download_to(checksum_url, checksum_path)
        expected_hash = checksum_for_asset(checksum_path.read_text(encoding="utf-8"), package_name)
        digest = hashlib.sha256()
        with package_path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest().lower() != expected_hash:
            raise RuntimeError("The downloaded setup pack failed SHA-256 verification and will not be installed.")

        # Validate all paths and the pack's executable before asking the player to close.
        test_root = work / "validation"
        test_root.mkdir()
        package_root = extract_setup_pack(package_path, test_root, allow_symlinks=(sys.platform == "darwin"))
        executable_name = EXE_STEM + (".exe" if os.name == "nt" else "")
        if not (package_root / executable_name).is_file():
            raise RuntimeError(f"The update ZIP is missing {executable_name}.")
        if not (package_root / "update" / "BUILD_PROVENANCE.json").is_file():
            raise RuntimeError("The update ZIP is missing build provenance metadata.")
        shutil.rmtree(test_root, ignore_errors=True)

        notify(
            "The Nightly setup pack has been downloaded and SHA-256 verified.\n\n"
            "Continue, then close Kirby Super Star Recomp when prompted. "
            "The updater will wait until the running game exits before installing."
        )
        wait_for_parent_exit(args.parent_pid)
        executable = install_setup_pack(package_path, install_root, work)
        notify(
            "The setup pack was updated successfully.\n\n"
            "The updated setup host will open. Choose Generate & rebuild to rebuild "
            "the playable game from your own ROM; your ROM selection, settings, "
            "mod preferences, saves, and locally generated files are preserved."
        )
        subprocess.Popen([str(executable)], cwd=str(install_root),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL,
                         creationflags=(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP |
                                        CREATE_NO_WINDOW) if os.name == "nt" else 0,
                         start_new_session=(os.name != "nt"))
        return 0
    except Exception as exc:
        notify(f"The update was not installed.\n\n{exc}\n\nYour existing installation and player data were left in place.",
               kind="error")
        return 1
    finally:
        if work is not None:
            shutil.rmtree(work, ignore_errors=True)
        cleanup_bootstrap_runtime()


if __name__ == "__main__":
    try:
        if detached_runtime_bootstrap(sys.argv[1:]):
            raise SystemExit(0)
        raise SystemExit(main())
    except Exception as exc:
        notify(f"The updater could not start safely:\n{exc}", kind="error")
        raise SystemExit(1)
