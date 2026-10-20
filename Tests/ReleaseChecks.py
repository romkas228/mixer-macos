# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only

"""Packaging checks using isolated app copies; never launch or install Mixer."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

PROJECT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("release", PROJECT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mixer-release-checks-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "Project with spaces"
        self.root.mkdir()
        for name in ("LICENSE", "NOTICE", "Resources/Info.plist", "docs/INSTALL.md", "scripts/publish-release.c",
                     ".mixer-signing/identity.sha1"):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, destination)
        for baseline in (PROJECT / ".mixer-signing").glob("*.req"):
            shutil.copyfile(baseline, self.root / ".mixer-signing" / baseline.name)
        shutil.copytree(PROJECT / "docs/releases", self.root / "docs/releases")
        self.app = self.root / "build/Mixer.app"
        shutil.copytree(PROJECT / "build/Mixer.app", self.app)
        self.patch = patch.object(release, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def candidate(self):
        with contextlib.redirect_stderr(io.StringIO()):
            return release.prepare()

    def archive(self, app, destination):
        payload = self.root / "fixture-payload"
        release.run("/usr/bin/ditto", app, payload / "Mixer.app")
        for name in release.ROOT_FILES:
            shutil.copyfile(self.root / name, payload / name)
        release.run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", payload, destination)

    def replace_zip_member(self, candidate, member, replacement):
        archive = next(candidate.glob("*.zip"))
        changed = self.root / "changed.zip"
        with zipfile.ZipFile(archive) as old, zipfile.ZipFile(changed, "w") as new:
            for item in old.infolist():
                if item.filename == member:
                    if replacement is not None:
                        new.writestr(item, replacement)
                else:
                    new.writestr(item, old.read(item))
        changed.replace(archive)
        (candidate / "SHA256SUMS").write_text(f"{release.digest(archive)}  {archive.name}\n")

    def test_real_bundle_roundtrip_and_public_manifest(self):
        candidate = self.candidate()
        metadata = json.loads((candidate / "release-manifest.json").read_text())
        extracted = release.unpack(candidate / metadata["archive"], self.root / "unpacked")
        release.compare_apps(self.app, extracted)
        self.assertEqual(metadata["files"], release.inventory(extracted))
        self.assertEqual(metadata["license"], "GPL-3.0-only")
        for name in release.ROOT_FILES:
            self.assertEqual((extracted.parent / name).read_bytes(), (self.root / name).read_bytes())
        self.assertNotIn(str(self.root), (candidate / "release-manifest.json").read_text())
        self.assertEqual(len(list(candidate.iterdir())), 5)
        self.assertFalse((candidate / "VERIFICATION.txt").exists())
        self.assertFalse((self.root / "build/releases").exists())

    def test_rejects_private_extra_hidden_files_and_links(self):
        for name in ("Contents/Resources/backup.p12", "Contents/.env", "Contents/Resources/link"):
            with self.subTest(name=name):
                unexpected = self.app / name
                if name.endswith("link"):
                    unexpected.symlink_to(self.root / "Resources/Info.plist")
                else:
                    unexpected.write_text("test fixture only")
                with self.assertRaises(release.ReleaseError):
                    release.validate_app(self.app)
                unexpected.unlink()

    def test_requires_complete_executable_bundle(self):
        executable = self.app / "Contents/MacOS/Mixer"
        mode = executable.stat().st_mode
        executable.chmod(0o644)
        with self.assertRaisesRegex(release.ReleaseError, "права виконання"):
            release.validate_app(self.app)
        executable.chmod(stat.S_IMODE(mode))
        (self.app / "Contents/Resources/AppIcon.icns").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "бракує"):
            release.validate_app(self.app)

    def test_rejects_stale_build_metadata(self):
        info = self.app / "Contents/Info.plist"
        data = plistlib.loads(info.read_bytes())
        data["CFBundleShortVersionString"] = "0.0.0"
        info.write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(release.ReleaseError, "відрізняється"):
            release.prepare()

    def test_adhoc_cannot_be_prepared_as_persistent_release(self):
        release.run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", self.app)
        with self.assertRaisesRegex(release.ReleaseError, "ad-hoc"):
            self.candidate()

    def test_wrong_signer_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "сертифікату"):
            release.signed_identity(self.app, "0" * 40)

    def test_zip_rejects_traversal_absolute_paths_links_and_duplicates(self):
        for kind in ("../escape", "/tmp/escape", "link", "duplicate"):
            with self.subTest(kind=kind):
                archive = self.root / "unsafe.zip"
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    with zipfile.ZipFile(archive, "w") as stream:
                        for name in release.FILES:
                            stream.writestr("Mixer.app/" + name, "fixture")
                        for name in release.ROOT_FILES:
                            stream.writestr(name, "license fixture")
                        if kind == "link":
                            entry = zipfile.ZipInfo("Mixer.app/Contents/")
                            entry.create_system = 3
                            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                            stream.writestr(entry, "/tmp")
                        else:
                            name = "Mixer.app/Contents/Info.plist" if kind == "duplicate" else kind
                            stream.writestr(name, "unsafe fixture")
                with self.assertRaises(release.ReleaseError):
                    release.unpack(archive, self.root / "should-not-exist")
                self.assertFalse((self.root / "should-not-exist").exists())

    def test_manifest_detects_changed_archive(self):
        candidate = self.candidate()
        archive = next(candidate.glob("*.zip"))
        with archive.open("ab") as stream:
            stream.write(b"changed")
        with self.assertRaisesRegex(release.ReleaseError, "SHA-256"):
            release.verify(candidate)
        self.assertFalse((self.root / "build/releases").exists())

    def test_bundle_comparison_detects_tampered_resource(self):
        candidate = self.candidate()
        extracted = release.unpack(next(candidate.glob("*.zip")), self.root / "unpacked")
        with (extracted / "Contents/Resources/AppIcon.icns").open("ab") as stream:
            stream.write(b"tampered fixture")
        with self.assertRaisesRegex(release.ReleaseError, "змінила"):
            release.compare_apps(self.app, extracted)

    def test_native_adhoc_signature_survives_archive_and_detects_tampering(self):
        # Real native signature verification of a fixture needs no private certificate.
        for relative, name in zip(release.OPTIONAL_FILES, release.ROOT_FILES):
            shutil.copyfile(self.root / name, self.app / relative)
        release.run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", self.app)
        archive = self.root / "fixture.zip"
        self.archive(self.app, archive)
        extracted = release.unpack(archive, self.root / "unpacked")
        release.run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", extracted)
        with (extracted / "Contents/Resources/AppIcon.icns").open("ab") as stream:
            stream.write(b"tampered fixture")
        with self.assertRaises(release.ReleaseError):
            release.run("/usr/bin/codesign", "--verify", "--deep", "--strict", extracted)

    def test_license_copy_is_required_even_with_updated_archive_checksum(self):
        for name in release.ROOT_FILES:
            with self.subTest(name=name):
                candidate = self.candidate()
                self.replace_zip_member(candidate, name, None)
                with self.assertRaisesRegex(release.ReleaseError, "неповний"):
                    release.verify(candidate)
        self.assertFalse((self.root / "build/releases").exists())

    def test_modified_license_is_rejected_even_with_updated_archive_checksum(self):
        candidate = self.candidate()
        self.replace_zip_member(candidate, "LICENSE", b"replaced license fixture")
        with self.assertRaisesRegex(release.ReleaseError, "Ліцензійні файли"):
            release.verify(candidate)
        self.assertFalse((self.root / "build/releases").exists())

    def test_embedded_license_must_match_repository(self):
        for relative, name in zip(release.OPTIONAL_FILES, release.ROOT_FILES):
            shutil.copyfile(self.root / name, self.app / relative)
        release.validate_app(self.app)
        self.assertEqual(len(release.inventory(self.app)), 6)
        (self.app / "Contents/Resources/NOTICE.txt").write_text("old notice fixture")
        with self.assertRaisesRegex(release.ReleaseError, "застарів"):
            release.validate_app(self.app)

    def test_stored_requirement_must_pin_certificate(self):
        expected = release.fingerprint()
        baseline = self.root / ".mixer-signing" / (expected + ".req")
        baseline.write_text('identifier "local.mixer.Mixer"\n')
        with self.assertRaisesRegex(release.ReleaseError, "закріпленому"):
            release.native_verify(self.app, expected)

    def test_failed_native_verification_keeps_candidate_unpublished(self):
        candidate = self.candidate()
        with patch.object(release, "native_verify", side_effect=release.ReleaseError("fixture native failure")):
            with self.assertRaisesRegex(release.ReleaseError, "fixture native failure"):
                release.verify(candidate)
        self.assertTrue(candidate.is_dir())
        self.assertFalse((candidate / "VERIFICATION.txt").exists())
        self.assertFalse((self.root / "build/releases").exists())

    def test_success_gate_publishes_complete_directory_once(self):
        # Simulate only the external trust decision to exercise the final filesystem gate.
        # This does not assert that the real self-signed identity passes native verification.
        candidate = self.candidate()
        with patch.object(release, "native_verify") as verification:
            destination = release.verify(candidate)
            verification.assert_called_once()
        self.assertFalse(candidate.exists())
        self.assertTrue((destination / "VERIFICATION.txt").is_file())
        original = release.digest(next(destination.glob("*.zip")))
        another = self.candidate()
        with patch.object(release, "native_verify"):
            with self.assertRaisesRegex(release.ReleaseError, "уже існує"):
                release.verify(another)
        self.assertEqual(original, release.digest(next(destination.glob("*.zip"))))
        self.assertTrue(another.is_dir())
        self.assertFalse((another / "VERIFICATION.txt").exists())

    def test_atomic_publisher_never_replaces_or_merges_destination(self):
        publisher = self.root / "publish-release"
        release.run("/usr/bin/clang", "-O2", "-Wall", "-Wextra", "-Werror",
                    self.root / "scripts/publish-release.c", "-o", publisher)
        first, second, destination = (self.root / n for n in ("first", "second", "destination"))
        first.mkdir()
        (first / "version").write_text("first")
        release.run(publisher, first, destination)
        second.mkdir()
        (second / "version").write_text("second")
        with self.assertRaises(release.ReleaseError):
            release.run(publisher, second, destination)
        self.assertEqual((destination / "version").read_text(), "first")
        self.assertEqual((second / "version").read_text(), "second")

    def test_ready_check_repeats_native_validation_without_republishing(self):
        candidate = self.candidate()
        with patch.object(release, "native_verify"):
            ready = release.verify(candidate)
        before = {p.name: release.digest(p) for p in ready.iterdir()}
        with patch.object(release, "native_verify") as native:
            release.check(ready)
            native.assert_called_once()
        self.assertEqual(before, {p.name: release.digest(p) for p in ready.iterdir()})


if __name__ == "__main__":
    unittest.main(verbosity=2)
