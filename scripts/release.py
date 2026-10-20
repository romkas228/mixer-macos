#!/usr/bin/env python3
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare an existing signed app, then verify it before publishing local assets.

Uses only Python's standard library and macOS developer tools. Never signs code,
reads a private key, changes trust settings, installs, launches, or uploads an app.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
FILES = (
    "Contents/Info.plist", "Contents/MacOS/Mixer",
    "Contents/Resources/AppIcon.icns", "Contents/_CodeSignature/CodeResources",
)
OPTIONAL_FILES = ("Contents/Resources/LICENSE.txt", "Contents/Resources/NOTICE.txt")
ROOT_FILES = ("LICENSE", "NOTICE")
LICENSE_ID = "GPL-3.0-only"
DIRECTORIES = {"Contents", "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature"}
BUNDLE_ID = "local.mixer.Mixer"


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def run(*arguments):
    result = subprocess.run([str(a) for a in arguments], capture_output=True, text=True)
    if result.returncode:
        raise ReleaseError(f"{Path(str(arguments[0])).name}: {(result.stderr or result.stdout).strip()}")
    return result.stdout + result.stderr


def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def directory(path):
    require(not path.is_symlink(), f"Папка не може бути символічним посиланням: {path}")
    path.mkdir(exist_ok=True)
    require(path.is_dir(), f"Очікується папка: {path}")


def fingerprint():
    identity = ROOT / ".mixer-signing/identity.sha1"
    require(identity.is_file(), "Спочатку налаштуй постійний підпис. Див. docs/SIGNING.md.")
    value = identity.read_text().strip().upper()
    require(re.fullmatch(r"[0-9A-F]{40}", value), "Некоректний відбиток сертифіката.")
    return value


def validate_app(app):
    require(app.is_dir() and not app.is_symlink(), "Потрібен справжній bundle Mixer.app.")
    for entry in app.rglob("*"):
        relative = entry.relative_to(app).as_posix()
        require(not entry.is_symlink(), f"Посилання всередині bundle заборонене: {relative}")
        require((entry.is_dir() and relative in DIRECTORIES)
                or (entry.is_file() and relative in FILES + OPTIONAL_FILES),
                f"Неочікуваний вміст bundle: {relative}")
    require(all((app / name).is_file() for name in FILES), "У bundle бракує обов’язкових файлів.")
    require(os.access(app / "Contents/MacOS/Mixer", os.X_OK), "Mixer не має права виконання.")
    for relative, name in zip(OPTIONAL_FILES, ROOT_FILES):
        resource = app / relative
        if resource.exists():
            require(resource.read_bytes() == (ROOT / name).read_bytes(),
                    f"Ліцензійний ресурс у bundle застарів: {relative}")
    raw = (app / "Contents/Info.plist").read_bytes()
    require(raw == (ROOT / "Resources/Info.plist").read_bytes(),
            "Info.plist збірки відрізняється від поточного проєкту. Перевір версію збірки.")
    info = plistlib.loads(raw)
    require(info.get("CFBundleIdentifier") == BUNDLE_ID
            and info.get("CFBundleExecutable") == "Mixer", "Невірна ідентичність bundle.")
    version, build = info.get("CFBundleShortVersionString", ""), info.get("CFBundleVersion", "")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
            and re.fullmatch(r"[0-9]+", build), "Некоректна версія збірки.")
    require(info.get("LSMinimumSystemVersion") == "26.0", "Очікується мінімальна macOS 26.0.")
    executable = app / "Contents/MacOS/Mixer"
    arch = run("/usr/bin/xcrun", "lipo", "-archs", executable).strip()
    require(arch == "arm64", "Перший пакет підтримує лише Apple Silicon (arm64).")
    minimum = re.findall(r"^\s*minos\s+(\S+)", run("/usr/bin/xcrun", "vtool", "-show-build", executable), re.M)
    require(minimum == ["26.0"], "Мінімальна macOS в executable не відповідає Info.plist.")
    return {"version": version, "build": build, "architecture": arch,
            "minimumMacOS": "26.0", "bundleIdentifier": BUNDLE_ID}


def inventory(app):
    return [{"path": name, "sha256": digest(app / name),
             "bytes": (app / name).stat().st_size,
             "mode": stat.S_IMODE((app / name).stat().st_mode)}
            for name in FILES + OPTIONAL_FILES if (app / name).is_file()]


def compare_apps(first, second):
    validate_app(second)
    require(inventory(first) == inventory(second), "Архівація змінила файли або права bundle.")


def signed_identity(app, expected):
    details = run("/usr/bin/codesign", "--display", "--verbose=4", "-r-", app)
    requirement = re.search(r"^designated => (.+)$", details, re.M)
    expected_rule = f'identifier "{BUNDLE_ID}" and certificate leaf = H"{expected.lower()}"'
    require(requirement and requirement[1] == expected_rule,
            "DR не відповідає постійному сертифікату Mixer; ad-hoc не приймається.")
    match = re.search(r"^CDHash=([0-9a-f]+)$", details, re.M)
    require(match is not None, "Не вдалося прочитати CDHash.")
    return match[1]


def check_zip(path):
    # Validate paths and Unix types before extraction, including AppleDouble metadata.
    normal = set(ROOT_FILES) | {"Mixer.app"} | {f"Mixer.app/{p}" for p in DIRECTORIES | set(FILES + OPTIONAL_FILES)}
    allowed = set(normal) | {n + "/" for n in normal if n == "Mixer.app" or n[10:] in DIRECTORIES}
    for name in normal:
        item = Path(name)
        metadata = Path("__MACOSX") / item.parent / ("._" + item.name)
        allowed.add(metadata.as_posix())
        allowed.update(p.as_posix() + "/" for p in metadata.parents if p.as_posix() != ".")
    with zipfile.ZipFile(path) as archive:
        names = [item.filename for item in archive.infolist()]
        require(len(names) == len(set(names)), "ZIP містить повторні шляхи.")
        require(set(names) <= allowed, "ZIP містить неочікувані або небезпечні шляхи.")
        require(set(ROOT_FILES) | {f"Mixer.app/{p}" for p in FILES} <= set(names), "ZIP неповний.")
        require(sum(i.file_size for i in archive.infolist()) <= 256 * 1024 * 1024, "ZIP завеликий.")
        for item in archive.infolist():
            kind = stat.S_IFMT(item.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR) and not item.flag_bits & 1,
                    "ZIP містить посилання, спеціальний або зашифрований файл.")
        require(archive.testzip() is None, "Помилка CRC в ZIP.")


def unpack(archive, work):
    check_zip(archive)
    run("/usr/bin/ditto", "-x", "-k", archive, work)
    return work / "Mixer.app"


def prepare():
    expected = fingerprint()
    app = ROOT / "build/Mixer.app"
    validate_app(app)
    directory(ROOT / "build")
    directory(ROOT / "build/release-candidates")
    candidate = None
    try:
        with tempfile.TemporaryDirectory(prefix=".release-work-", dir=ROOT / "build") as temporary:
            work = Path(temporary)
            snapshot = work / "payload/Mixer.app"
            run("/usr/bin/ditto", app, snapshot)
            compare_apps(app, snapshot)
            metadata = validate_app(snapshot)
            metadata.update(schema=1, certificateSHA1=expected,
                            cdhash=signed_identity(snapshot, expected), files=inventory(snapshot))
            metadata["license"] = LICENSE_ID
            metadata["licenseFiles"] = {n: digest(ROOT / n) for n in ROOT_FILES}
            for n in ROOT_FILES:
                shutil.copyfile(ROOT / n, snapshot.parent / n)
            name = f'Mixer-{metadata["version"]}-macOS-{metadata["architecture"]}.zip'
            metadata["archive"] = name
            notes = ROOT / "docs/releases" / f'{metadata["version"]}.md'
            require(notes.is_file(), f"Потрібен опис релізу: {notes}")
            candidate = Path(tempfile.mkdtemp(prefix=f'{metadata["version"]}-arm64-', dir=ROOT / "build/release-candidates"))
            run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", snapshot.parent, candidate / name)
            extracted = unpack(candidate / name, work / "roundtrip")
            compare_apps(snapshot, extracted)
            shutil.copyfile(ROOT / "docs/INSTALL.md", candidate / "INSTALL.md")
            shutil.copyfile(notes, candidate / "RELEASE-NOTES.md")
            (candidate / "release-manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
            (candidate / "SHA256SUMS").write_text(f"{digest(candidate / name)}  {name}\n")
    except Exception:
        if candidate is not None:
            shutil.rmtree(candidate)
        raise
    print("Кандидат підготовлено; ZIP зберіг файли й права bundle. Strict verification ще не виконана.", file=sys.stderr)
    return candidate


def native_verify(app, expected):
    baseline = ROOT / ".mixer-signing" / f"{expected}.req"
    require(baseline.is_file(), "Відсутнє збережене правило ідентичності сертифіката.")
    rule = f'identifier "{BUNDLE_ID}" and certificate leaf = H"{expected.lower()}"'
    require(baseline.read_text().strip().lower() == rule.lower(),
            "Збережене правило не відповідає закріпленому сертифікату.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures",
        "--test-requirement", baseline, app)


def check_assets(candidate, verified=False):
    manifest = candidate / "release-manifest.json"
    require(manifest.is_file() and not manifest.is_symlink(), "Відсутній manifest кандидата.")
    metadata = json.loads(manifest.read_text())
    require(isinstance(metadata, dict), "Manifest має бути JSON-об’єктом.")
    require(metadata.get("schema") == 1 and isinstance(metadata.get("version"), str)
            and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", metadata["version"])
            and metadata.get("architecture") == "arm64", "Невідомий формат manifest.")
    name = f'Mixer-{metadata["version"]}-macOS-arm64.zip'
    require(metadata.get("archive") == name, "Невірна назва ZIP у manifest.")
    assets = {name, "INSTALL.md", "RELEASE-NOTES.md", "release-manifest.json", "SHA256SUMS"}
    if verified:
        assets.add("VERIFICATION.txt")
    require({p.name for p in candidate.iterdir()} == assets
            and all((candidate / n).is_file() and not (candidate / n).is_symlink() for n in assets),
            "Неочікуваний вміст папки кандидата.")
    hashes = {n: digest(candidate / n) for n in assets}
    require((candidate / "SHA256SUMS").read_text() == f"{hashes[name]}  {name}\n", "SHA-256 ZIP не збігається.")
    expected = fingerprint()
    require(metadata.get("certificateSHA1") == expected, "Підписувач у manifest змінився.")
    with tempfile.TemporaryDirectory(prefix=".release-verify-", dir=ROOT / "build") as temporary:
        work = Path(temporary)
        extracted = unpack(candidate / name, work / "extracted")
        actual = validate_app(extracted)
        require(all(metadata.get(k) == v for k, v in actual.items()), "Метадані ZIP не відповідають manifest.")
        require(inventory(extracted) == metadata.get("files"), "Вміст ZIP не відповідає manifest.")
        require(metadata.get("license") == LICENSE_ID, "Невідома ліцензія пакета.")
        require(metadata.get("licenseFiles") == {n: digest(ROOT / n) for n in ROOT_FILES},
                "Ліцензійні повідомлення у manifest застаріли.")
        require(all(digest(extracted.parent / n) == metadata["licenseFiles"][n] for n in ROOT_FILES),
                "Ліцензійні файли в ZIP не відповідають manifest.")
        require(signed_identity(extracted, expected) == metadata.get("cdhash"), "CDHash змінився.")
        native_verify(extracted, expected)
    require(all(digest(candidate / n) == h for n, h in hashes.items()), "Кандидат змінився під час перевірки.")
    return metadata


def check(ready):
    ready = Path(os.path.abspath(ready))
    require(ready.parent == ROOT / "build/releases" and ready.is_dir() and not ready.is_symlink(),
            "Потрібна папка готового локального релізу.")
    return check_assets(ready, verified=True)


def verify(candidate):
    directory(ROOT / "build")
    directory(ROOT / "build/release-candidates")
    candidate = Path(os.path.abspath(candidate))
    require(candidate.parent == ROOT / "build/release-candidates"
            and candidate.is_dir() and not candidate.is_symlink(), "Потрібна папка локального кандидата.")
    metadata = check_assets(candidate)
    directory(ROOT / "build/releases")
    destination = ROOT / "build/releases" / f'v{metadata["version"]}-arm64'
    require(not destination.exists() and not destination.is_symlink(), f"Реліз уже існує: {destination}")
    directory(ROOT / ".build")
    directory(ROOT / ".build/tools")
    publisher = ROOT / ".build/tools/publish-release"
    run("/usr/bin/clang", "-O2", "-Wall", "-Wextra", "-Werror", ROOT / "scripts/publish-release.c", "-o", publisher)
    marker = candidate / "VERIFICATION.txt"
    marker.write_text("PASS: ZIP CRC, paths, SHA-256, bundle files and permissions, metadata, pinned certificate, CDHash,\n"
                      "and native codesign --verify --deep --strict --all-architectures with saved requirement.\n"
                      "Downloaded installation and update on another Mac: pending.\n")
    try:
        run(publisher, candidate, destination)
    except Exception:
        marker.unlink()
        raise
    return destination


def main():
    args = sys.argv[1:]
    candidate = None
    try:
        if args == ["prepare"]:
            print(prepare())
        elif len(args) == 2 and args[0] == "verify":
            candidate = Path(args[1])
            print(f"Готовий локальний реліз: {verify(candidate)}")
        elif len(args) == 2 and args[0] == "check":
            check(Path(args[1]))
            print("Готовий пакет повторно пройшов native verification.")
        elif not args:
            candidate = prepare()
            print(f"Готовий локальний реліз: {verify(candidate)}")
        else:
            raise ReleaseError("Використання: ./scripts/release.sh [prepare | verify CANDIDATE | check RELEASE]")
    except (ReleaseError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"Реліз не підтверджено: {error}", file=sys.stderr)
        if candidate is not None and candidate.is_dir():
            print(f"Кандидат збережено: {candidate}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
