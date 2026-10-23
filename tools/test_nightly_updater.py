#!/usr/bin/env python3
"""Offline safety tests for Kirby Super Star Recomp's Nightly updater."""
import importlib.util
import json
import os
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("kirby_in_app_updater", ROOT / "tools" / "in_app_updater.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not import updater helpers")
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


class NightlyUpdaterTests(unittest.TestCase):
    def test_https_context_keeps_certificate_and_hostname_verification_enabled(self):
        context = UPDATER._https_context()
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_checksum_parser_selects_exact_asset(self):
        checksum_text = "a" * 64 + "  other.zip\n" + "b" * 64 + "  current.zip\n"
        self.assertEqual(UPDATER.checksum_for_asset(checksum_text, "current.zip"), "b" * 64)

    def test_checksum_parser_rejects_missing_asset(self):
        with self.assertRaises(RuntimeError):
            UPDATER.checksum_for_asset("c" * 64 + "  other.zip\n", "current.zip")

    def test_official_asset_url_must_point_to_nightly_repo(self):
        self.assertTrue(UPDATER._official_asset_url(
            "https://github.com/NVDEMU/KirbySuperStarPC/releases/download/Nightly/pack.zip"
        ))
        self.assertFalse(UPDATER._official_asset_url(
            "https://example.invalid/NVDEMU/KirbySuperStarPC/releases/download/Nightly/pack.zip"
        ))
        self.assertFalse(UPDATER._official_asset_url(
            "https://github.com/other/repo/releases/download/Nightly/pack.zip"
        ))

    def test_archive_rejects_parent_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            archive_path = Path(temp) / "unsafe.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("kirbysuperstar-Nightly-windows-x64/KirbySuperStarSNESRecomp.exe", "host")
                archive.writestr("kirbysuperstar-Nightly-windows-x64/../../escape.txt", "no")
            with self.assertRaises(RuntimeError):
                UPDATER.verify_archive_paths(archive_path, allow_symlinks=False)

    def test_archive_rejects_windows_backslash_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            archive_path = Path(temp) / "unsafe.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr(r"kirbysuperstar-Nightly-windows-x64\..\escape.txt", "no")
            with self.assertRaises(RuntimeError):
                UPDATER.verify_archive_paths(archive_path, allow_symlinks=False)

    def test_archive_requires_single_kirby_setup_pack_root(self):
        with tempfile.TemporaryDirectory() as temp:
            archive_path = Path(temp) / "two-roots.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("kirbysuperstar-Nightly-windows-x64/host.exe", "one")
                archive.writestr("other/host.exe", "two")
            with self.assertRaises(RuntimeError):
                UPDATER.verify_archive_paths(archive_path, allow_symlinks=False)

    def test_update_preserves_rom_settings_mod_state_and_generated_game_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            installed = root / "installed"
            installed.mkdir()
            executable_name = "KirbySuperStarSNESRecomp" + (".exe" if os.name == "nt" else "")
            (installed / executable_name).write_text("old setup host", encoding="utf-8")
            (installed / "rom.cfg").write_text("/Users/player/Kirby Super Star (USA).sfc\n", encoding="utf-8")
            (installed / "config.ini").write_text("[KeyMap]\nstart = Return\n", encoding="utf-8")
            (installed / "mods").mkdir()
            (installed / "mods" / "state.toml").write_text("enabled=false\n", encoding="utf-8")
            (installed / "src" / "gen").mkdir(parents=True)
            (installed / "src" / "gen" / "game.c").write_text("local ROM-derived output", encoding="utf-8")
            (installed / "recomp").mkdir()
            (installed / "recomp" / "funcs.h").write_text("local generated funcs", encoding="utf-8")
            (installed / "saves").mkdir()
            (installed / "saves" / "slot.srm").write_bytes(b"save-data")

            archive_path = root / "nightly.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                package = "kirbysuperstar-Nightly-linux-x64"
                archive.writestr(package + "/" + executable_name, "new setup host")
                archive.writestr(package + "/README.txt", "new release")
                archive.writestr(package + "/rom.cfg", "/default/rom.sfc\n")
                archive.writestr(package + "/config.ini", "new defaults\n")
                archive.writestr(package + "/mods/state.toml", "enabled=true\n")
                archive.writestr(package + "/src/gen/game.c", "must never replace ROM output")
                archive.writestr(package + "/recomp/funcs.h", "must never replace funcs")
                archive.writestr(package + "/update/updater.py", "# helper\n")
                archive.writestr(package + "/update/BUILD_PROVENANCE.json", json.dumps({"commit": "a" * 40}))

            UPDATER.install_setup_pack(archive_path, installed, root / "staging")
            self.assertEqual((installed / executable_name).read_text(), "new setup host")
            self.assertEqual((installed / "README.txt").read_text(), "new release")
            self.assertEqual((installed / "rom.cfg").read_text(), "/Users/player/Kirby Super Star (USA).sfc\n")
            self.assertEqual((installed / "config.ini").read_text(), "[KeyMap]\nstart = Return\n")
            self.assertEqual((installed / "mods" / "state.toml").read_text(), "enabled=false\n")
            self.assertEqual((installed / "src" / "gen" / "game.c").read_text(), "local ROM-derived output")
            self.assertEqual((installed / "recomp" / "funcs.h").read_text(), "local generated funcs")
            self.assertEqual((installed / "saves" / "slot.srm").read_bytes(), b"save-data")

    def test_update_provenance_is_read_from_runtime_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "update" / "BUILD_PROVENANCE.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"commit": "b" * 40}), encoding="utf-8")
            self.assertEqual(UPDATER.local_provenance(root)["commit"], "b" * 40)


if __name__ == "__main__":
    unittest.main(verbosity=2)
