#!/usr/bin/env python3
"""Offline tests for tools/audit_zip.py.

Each case builds a throwaway archive, so the gate is proven to actually fail on
the things it claims to catch — a checker that never fires is worse than none.

    python tools/test_audit_zip.py
"""

from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_zip  # noqa: E402

ROOTS = ["AdiButtonAuras", "AdiButtonAuras_Config"]


def make_zip(path, entries):
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return path


CLEAN = {
    "AdiButtonAuras/AdiButtonAuras.toc": "## Interface: 16001",
    "AdiButtonAuras/Forever.lua": "local x = 1 -- nothing to see",
    "AdiButtonAuras/libs/texture.tga": b"\x00\x01\x02",
    "AdiButtonAuras_Config/AdiButtonAuras_Config.toc": "## Interface: 16001",
}


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def audit(self, entries):
        path = make_zip(os.path.join(self.tmp.name, "a.zip"), entries)
        return audit_zip.audit(path, ROOTS)

    def assert_flags(self, entries, needle):
        report = self.audit(entries)
        self.assertTrue(report["problems"], f"expected a problem mentioning {needle!r}")
        joined = " | ".join(report["problems"])
        self.assertIn(needle, joined)

    def test_clean_archive_passes(self):
        report = self.audit(CLEAN)
        self.assertEqual(report["problems"], [])
        self.assertEqual(report["entries"], 4)

    def test_github_token(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/notes.lua"] = "local t = 'ghp_" + "a" * 36 + "'"
        self.assert_flags(entries, "github token")

    def test_private_key(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/README.md"] = "-----BEGIN RSA PRIVATE KEY-----\nxx"
        self.assert_flags(entries, "private key")

    def test_api_token_header(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/CHANGELOG.md"] = "curl -H 'X-Api-Token: deadbeefcafe'"
        self.assert_flags(entries, "api token header")

    def test_windows_home_path(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/notes.txt"] = r"loaded from C:\Users\someone\Desktop\addon"
        self.assert_flags(entries, "windows home path")

    def test_account_directory(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/notes.txt"] = r"WTF\Account\NAME\SavedVariables"
        self.assert_flags(entries, "wow account dir")

    def test_backup_file(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/core/AuraTools.lua.bak"] = "old"
        self.assert_flags(entries, "forbidden extension")

    def test_executable(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/update.exe"] = b"MZ"
        self.assert_flags(entries, "forbidden extension")

    def test_zip_slip(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/../../evil.lua"] = "x"
        self.assert_flags(entries, "unsafe path")

    def test_savedvariables_dir(self):
        entries = dict(CLEAN)
        entries["AdiButtonAuras/SavedVariables/x.lua"] = "x"
        self.assert_flags(entries, "forbidden directory")

    def test_wrapper_folder_still_caught(self):
        wrapped = {f"build/{k}": v for k, v in CLEAN.items()}
        path = make_zip(os.path.join(self.tmp.name, "b.zip"), wrapped)
        with self.assertRaises(Exception):
            audit_zip.audit(path, ROOTS)

    def test_cli_exit_codes(self):
        good = make_zip(os.path.join(self.tmp.name, "good.zip"), CLEAN)
        self.assertEqual(audit_zip.main(["--file", good]), 0)

        bad_entries = dict(CLEAN)
        bad_entries["AdiButtonAuras/x.lua"] = "ghp_" + "b" * 36
        bad = make_zip(os.path.join(self.tmp.name, "bad.zip"), bad_entries)
        self.assertEqual(audit_zip.main(["--file", bad]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
