# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
"""Source publication guards. Git fixtures stay in temp dirs; no remote writes."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
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
        self.root = Path(temporary.name).resolve()
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
        with patch.object(publication, "api", side_effect=[[], [dict(result, tag_name="v0.1.18")]]), \
             patch.object(publication, "command") as command:
            publication.upload_draft(self.root, "0.1.18", "a" * 40)
            arguments = command.call_args.args
            self.assertEqual(arguments[:3], ("gh", "release", "create"))
            self.assertIn("--draft", arguments)
            self.assertIn("--prerelease", arguments)
            self.assertIn("--verify-tag", arguments)
            self.assertNotIn("--clobber", arguments)

    def test_published_release_is_not_modified(self):
        with patch.object(publication, "api", return_value=[{"draft": False, "tag_name": "v0.1.18"}]), \
             patch.object(publication, "command") as command:
            with self.assertRaises(publication.PublicationError):
                publication.upload_draft(self.root, "0.1.18", "a" * 40)
            command.assert_not_called()

    def test_existing_published_version_stops_before_commit_or_upload(self):
        responses = [
            {"login": "romkas228", "id": 7},
            {"full_name": "romkas228/mixer-macos", "private": False},
            [{"draft": False, "tag_name": "v0.1.18"}],
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

    def test_draft_is_found_even_when_published_tag_endpoint_returns_404(self):
        draft = {"id": 8, "tag_name": "v0.1.18", "draft": True}

        def server(arguments, **kwargs):
            if arguments[2].endswith("/releases?per_page=100&page=1"):
                return SimpleNamespace(returncode=0, stdout=json.dumps([draft]), stderr="")
            return SimpleNamespace(returncode=1, stdout="", stderr="gh: Not Found (HTTP 404)")

        with patch.object(publication.subprocess, "run", side_effect=server):
            self.assertEqual(publication.find_release("v0.1.18"), draft)
            with self.assertRaisesRegex(publication.PublicationError, "gh api .*releases/tags/v0.1.18.*HTTP 404"):
                publication.api(f"repos/{publication.REPOSITORY}/releases/tags/v0.1.18")

    def test_draft_on_later_page_is_found_and_duplicate_tags_are_rejected(self):
        first_page = [{"tag_name": f"other-{i}"} for i in range(100)]
        draft = {"id": 8, "tag_name": "v0.1.18", "draft": True}
        with patch.object(publication, "api", side_effect=[first_page, [draft]]) as api:
            self.assertEqual(publication.find_release("v0.1.18"), draft)
            self.assertTrue(api.call_args.args[0].endswith("page=2"))
        with patch.object(publication, "api", side_effect=[[draft] + first_page[:99], [draft]]):
            with self.assertRaisesRegex(publication.PublicationError, "декілька релізів"):
                publication.find_release("v0.1.18")

    def asset_fixture(self):
        ready = self.root / "build/releases/v0.1.18-arm64"
        ready.mkdir(parents=True)
        names = ["Mixer-0.1.18-macOS-arm64.zip", "SHA256SUMS", "INSTALL.md", "release-manifest.json"]
        for name in names:
            (ready / name).write_bytes(("fixture " + name).encode())
        result = {"id": 8, "tag_name": "v0.1.18", "draft": True, "prerelease": True,
                  "assets": [{"name": name} for name in names], "html_url": "https://example.test/draft"}
        return ready, names, result

    def test_existing_draft_is_resumed_without_creating_another_or_replacing_assets(self):
        ready, names, result = self.asset_fixture()
        partial = dict(result, assets=result["assets"][:2])

        def download(*arguments):
            if arguments[:3] == ("gh", "release", "download"):
                name = arguments[arguments.index("--pattern") + 1]
                directory = Path(arguments[arguments.index("--dir") + 1])
                (directory / name).write_bytes((ready / name).read_bytes())

        with patch.object(publication, "ROOT", self.root), \
             patch.object(publication, "api", side_effect=[[partial], [result]]), \
             patch.object(publication, "command", side_effect=download) as command:
            self.assertEqual(publication.upload_draft(ready, "0.1.18", "a" * 40), result["html_url"])
        calls = [call.args for call in command.call_args_list]
        self.assertFalse(any(args[:3] == ("gh", "release", "create") for args in calls))
        self.assertEqual([args[4].name for args in calls if args[:3] == ("gh", "release", "upload")], names[2:])
        self.assertFalse(any("--clobber" in args or "--draft=false" in args for args in calls))

    def test_different_existing_asset_is_rejected(self):
        ready, _, result = self.asset_fixture()

        def download(*arguments):
            name = arguments[arguments.index("--pattern") + 1]
            directory = Path(arguments[arguments.index("--dir") + 1])
            (directory / name).write_bytes(b"different remote asset")

        with patch.object(publication, "ROOT", self.root), \
             patch.object(publication, "api", return_value=[result]), \
             patch.object(publication, "command", side_effect=download) as command:
            with self.assertRaisesRegex(publication.PublicationError, "не перезаписаний"):
                publication.upload_draft(ready, "0.1.18", "a" * 40)
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[:3], ("gh", "release", "download"))

    def fixture_git(self, *arguments):
        result = subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                                 "-c", "commit.gpgsign=false", *arguments], cwd=self.root,
                                capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def tagged_fixture(self):
        self.fixture_git("init", "--initial-branch=main")
        self.fixture_git("add", ".")
        self.fixture_git("commit", "-m", "Fixture release")
        original = self.fixture_git("rev-parse", "HEAD")
        self.fixture_git("tag", "v0.1.18", original)
        return original

    def test_retry_preserves_existing_tag_after_publication_tool_fix(self):
        original = self.tagged_fixture()
        script = self.root / "scripts/publish-github.py"
        script.write_text(script.read_text() + "\n# fixture publication fix\n")
        self.fixture_git("add", "scripts/publish-github.py")
        self.fixture_git("commit", "-m", "Fix publication fixture")
        head = self.fixture_git("rev-parse", "HEAD")
        with patch.object(publication, "ROOT", self.root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(publication.release_commit("0.1.18", head), original)
        self.assertNotEqual(original, head)
        self.assertEqual(self.fixture_git("rev-parse", "v0.1.18"), original)

    def test_full_retry_commits_tool_fix_and_resumes_original_draft(self):
        original = self.tagged_fixture()
        script = self.root / "scripts/publish-github.py"
        script.write_text(script.read_text() + "\n# fixture publication fix\n")
        ready, _, result = self.asset_fixture()
        run_command = publication.command

        def remote_api(path, **kwargs):
            if path == "user":
                return {"login": "romkas228", "id": 7}
            if path == f"repos/{publication.REPOSITORY}":
                return {"full_name": publication.REPOSITORY, "private": False}
            if "/releases?" in path:
                return [result]
            if "/branches?" in path:
                return [{"name": "main"}]
            raise AssertionError("Unexpected API endpoint: " + path)

        def execute(*arguments, **kwargs):
            if arguments[:3] == ("gh", "release", "download"):
                name = arguments[arguments.index("--pattern") + 1]
                directory = Path(arguments[arguments.index("--dir") + 1])
                (directory / name).write_bytes((ready / name).read_bytes())
                return ""
            if arguments[:3] in (("gh", "release", "edit"), ("gh", "repo", "edit")):
                return ""
            self.assertEqual(arguments[0], "git")
            return run_command(*arguments, **kwargs)

        with patch.object(publication, "ROOT", self.root), \
             patch.object(publication, "api", side_effect=remote_api), \
             patch.object(publication, "release_assets", return_value=ready), \
             patch.object(publication, "git", return_value=original + "\trefs/heads/main") as remote_git, \
             patch.object(publication, "command", side_effect=execute), \
             patch.object(publication, "upload_draft", wraps=publication.upload_draft) as upload, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(publication.main(), 0, errors.getvalue())
        self.assertNotEqual(self.fixture_git("rev-parse", "HEAD"), original)
        self.assertEqual(self.fixture_git("rev-parse", "v0.1.18"), original)
        self.assertEqual(self.fixture_git("status", "--porcelain"), "")
        self.assertEqual(upload.call_args.args[-1], original)
        self.assertEqual([call.args for call in remote_git.call_args_list], [
            ("ls-remote", "origin", "refs/heads/main"),
            ("push", "--set-upstream", "origin", "main"),
            ("push", "origin", "refs/tags/v0.1.18"),
        ])

    def test_app_changes_cannot_reuse_existing_version_tag(self):
        original = self.tagged_fixture()
        app = self.root / "Sources/Mixer/MixerApplication.swift"
        app.write_text(app.read_text() + "\n// fixture app change\n")
        self.fixture_git("add", "Sources/Mixer/MixerApplication.swift")
        self.fixture_git("commit", "-m", "Change app fixture")
        head = self.fixture_git("rev-parse", "HEAD")
        with patch.object(publication, "ROOT", self.root):
            with self.assertRaisesRegex(publication.PublicationError, "Потрібна нова версія"):
                publication.release_commit("0.1.18", head)
        self.assertEqual(self.fixture_git("rev-parse", "v0.1.18"), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
