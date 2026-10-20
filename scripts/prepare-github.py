#!/usr/bin/env python3
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
"""Create a reviewable source snapshot using an explicit publication allowlist."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "romkas228/mixer-macos"
TOP_FILES = (".gitignore", "LICENSE", "NOTICE", "Package.swift", "README.md")
CODE_DIRECTORIES = ("Sources", "Tests", "scripts", "Benchmarks")
CODE_SUFFIXES = {".swift", ".c", ".h", ".py", ".sh"}
RESOURCE_FILES = ("Info.plist", "AppIcon.png", "AppIcon.icns", "AppIcon.prompt.md")
DOC_FILES = ("INSTALL.md", "ARCHITECTURE.md", "SIGNING.md", "PUBLISHING.md")


class PreparationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PreparationError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def selected_files(root):
    files = [root / n for n in TOP_FILES]
    files += [root / "Resources" / n for n in RESOURCE_FILES]
    files += [root / "docs" / n for n in DOC_FILES]
    for directory in CODE_DIRECTORIES:
        base = root / directory
        require(base.is_dir() and not base.is_symlink(), f"Невірна папка: {directory}")
        for path in base.rglob("*"):
            require(not path.is_symlink(), f"Посилання не публікується: {path.relative_to(root)}")
            if path.is_file() and path.suffix in CODE_SUFFIXES:
                files.append(path)
    files += sorted((root / "docs/releases").glob("*.md"))
    for path in files:
        require(path.is_file() and not path.is_symlink(), f"Відсутній звичайний файл: {path.relative_to(root)}")
    return sorted(set(files))


def inspect_text(path):
    if path.suffix in {".png", ".icns"}:
        return
    content = path.read_text()
    patterns = (
        r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        r"gh[pousr]_[A-Za-z0-9]{30,}", r"github_pat_[A-Za-z0-9_]{30,}",
        r"AKIA[0-9A-Z]{16}", r"/" + r"Users/[^\s]+", r"/" + r"var/folders/",
    )
    require(not any(re.search(pattern, content) for pattern in patterns),
            f"Файл потребує перевірки перед публікацією: {path.name}")


def verify_files(root, manifest):
    for item in manifest["files"]:
        path = root / item["path"]
        require(path.is_file() and not path.is_symlink() and sha(path) == item["sha256"],
                f"Файл змінився після підготовки: {item['path']}")


def prepare():
    files = selected_files(ROOT)
    for path in files:
        inspect_text(path)
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Невірна версія проєкту.")
    manifest = {"repository": REPOSITORY, "version": version, "files": [
        {"path": p.relative_to(ROOT).as_posix(), "sha256": sha(p),
         "mode": stat.S_IMODE(p.stat().st_mode)} for p in files]}
    encoded = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    identifier = hashlib.sha256(encoded.encode()).hexdigest()[:12]
    output = ROOT / "build/github"
    require(not (ROOT / "build").is_symlink() and not output.is_symlink(), "Невірна папка build/github.")
    output.mkdir(parents=True, exist_ok=True)
    snapshot = output / ("source-" + identifier)
    if snapshot.exists():
        require(snapshot.is_dir() and not snapshot.is_symlink(), "Невірна папка snapshot.")
        actual = {p.relative_to(snapshot).as_posix() for p in snapshot.rglob("*") if p.is_file() or p.is_symlink()}
        require(actual == {i["path"] for i in manifest["files"]}, "Snapshot має зайві або відсутні файли.")
        verify_files(snapshot, manifest)
    else:
        staging = Path(tempfile.mkdtemp(prefix=".source-", dir=output))
        try:
            for item in manifest["files"]:
                target = staging / item["path"]
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / item["path"], target)
                target.chmod(item["mode"])
            verify_files(staging, manifest)
            staging.rename(snapshot)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    manifest_path = output / (snapshot.name + ".json")
    manifest_path.write_text(encoded)
    archive = output / f"Mixer-{version}-source-{identifier}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
        for item in manifest["files"]:
            zipped.write(snapshot / item["path"], "mixer-macos/" + item["path"])
    verify_files(ROOT, manifest)
    return manifest, snapshot, archive


if __name__ == "__main__":
    manifest, snapshot, archive = prepare()
    print(f"Source files: {len(manifest['files'])}\nSnapshot: {snapshot}\nReview archive: {archive}")
