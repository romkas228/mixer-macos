# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
"""Source publication guards. No network, real commits, or remote writes."""
import contextlib
import importlib.util
import io
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile

PROJECT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, PROJECT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


source = load("publication_source", "prepare-github.py")
publication = load("publication", "publish-github.py")


class PublicationChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mixer-publication-checks-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for original in source.selected_files(PROJECT):
            destination = self.root / original.relative_to(PROJECT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, destination)

    def test_snapshot_excludes_local_data_and_preserves_source(self):
        for name in (".mixer-signing/key.p12", "build/Mixer.app/private", ".git/config",
                     "docs/RELEASE.md", "docs/performance/private.json", "backup.pfx"):
            private = self.root / name
            private.parent.mkdir(parents=True, exist_ok=True)
            private.write_text("private fixture")
        with patch.object(source, "ROOT", self.root):
            manifest, snapshot, archive = source.prepare()
            source.verify_files(snapshot, manifest)
        names = {item["path"] for item in manifest["files"]}
        self.assertIn("Sources/Mixer/MixerApplication.swift", names)
        self.assertIn("LICENSE", names)
        self.assertIn("scripts/build.sh", names)
        self.assertTrue(all(not name.startswith((".git/", ".mixer-signing/", "build/", "docs/performance/")) for name in names))
        self.assertNotIn("docs/RELEASE.md", names)
        self.assertFalse(any(name.endswith((".p12", ".pfx")) for name in names))
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(set(zipped.namelist()), {"mixer-macos/" + n for n in names})

    def test_secret_home_path_and_symlink_block_preparation(self):
        path = self.root / "Sources/Mixer/Private.swift"
        for value in ("ghp_" + "x" * 36, "/" + "Users/fixture/private"):
            with self.subTest(value=value[:4]), patch.object(source, "ROOT", self.root):
                path.write_text(value)
                with self.assertRaises(source.PreparationError):
                    source.prepare()
                self.assertFalse((self.root / "build/github").exists())
        path.unlink()
        path.symlink_to(self.root / "NOTICE")
        with patch.object(source, "ROOT", self.root), self.assertRaises(source.PreparationError):
            source.prepare()

    def test_frozen_source_change_is_detected(self):
        with patch.object(source, "ROOT", self.root):
            manifest, _, _ = source.prepare()
        (self.root / "NOTICE").write_text("changed fixture")
        with self.assertRaises(source.PreparationError):
            source.verify_files(self.root, manifest)

    def fake_modules(self):
        prepared = SimpleNamespace(prepare=Mock(return_value=(
            {"files": [], "version": "0.1.18"}, self.root, self.root / "source.zip")))
        release = SimpleNamespace()
        return lambda name, filename: prepared if filename == "prepare-github.py" else release

    def test_wrong_account_blocks_all_publication(self):
        with patch.object(publication, "module", side_effect=self.fake_modules()), \
             patch.object(publication, "api", return_value={"login": "another-user", "id": 7}), \
             patch.object(publication.shutil, "which", return_value="/tool"), \
             patch.object(publication, "command") as command, \
             patch.object(publication, "release_assets") as assets, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(publication.main(), 1)
            command.assert_not_called()
            assets.assert_not_called()

    def test_network_error_blocks_git_and_remote_mutation(self):
        with patch.object(publication, "module", side_effect=self.fake_modules()), \
             patch.object(publication, "command", side_effect=publication.PublicationError("fixture network error")) as command, \
             patch.object(publication.shutil, "which", return_value="/tool"), \
             patch.object(publication, "commit_source") as commit, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(publication.main(), 1)
            self.assertEqual(command.call_args_list[0].args, ("gh", "api", "user"))
            self.assertEqual(command.call_count, 1)
            commit.assert_not_called()

    def test_release_is_created_only_as_draft_prerelease(self):
        names = ["Mixer-0.1.18-macOS-arm64.zip", "SHA256SUMS", "INSTALL.md", "release-manifest.json"]
        result = {"draft": True, "prerelease": True, "assets": [{"name": n} for n in names],
                  "html_url": "https://github.com/romkas228/mixer-macos/releases/test"}
        with patch.object(publication, "api", side_effect=[None, result]), patch.object(publication, "command") as command:
            publication.upload_draft(self.root, "0.1.18", "a" * 40)
            arguments = command.call_args.args
            self.assertEqual(arguments[:3], ("gh", "release", "create"))
            self.assertIn("--draft", arguments)
            self.assertIn("--prerelease", arguments)
            self.assertIn("--verify-tag", arguments)
            self.assertNotIn("--clobber", arguments)

    def test_published_release_is_not_modified(self):
        with patch.object(publication, "api", return_value={"draft": False}), patch.object(publication, "command") as command:
            with self.assertRaises(publication.PublicationError):
                publication.upload_draft(self.root, "0.1.18", "a" * 40)
            command.assert_not_called()

    def test_existing_published_version_stops_before_commit_or_upload(self):
        responses = [
            {"login": "romkas228", "id": 7},
            {"full_name": "romkas228/mixer-macos", "private": False},
            {"draft": False},
        ]
        with patch.object(publication, "module", side_effect=self.fake_modules()), \
             patch.object(publication, "api", side_effect=responses), \
             patch.object(publication.shutil, "which", return_value="/tool"), \
             patch.object(publication, "command") as command, \
             patch.object(publication, "commit_source") as commit, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(publication.main(), 1)
            command.assert_not_called()
            commit.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
