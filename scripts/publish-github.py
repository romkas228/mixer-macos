#!/usr/bin/env python3
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
"""First publication via gh + git. Uploads source and creates a DRAFT release only."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "romkas228/mixer-macos"
OWNER = "romkas228"
REMOTE = "https://github.com/romkas228/mixer-macos.git"


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class PublicationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PublicationError(message)


def command(*args, missing=False):
    process_env = os.environ.copy()
    process_env["GH_HOST"] = "github.com"
    result = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=True, text=True, env=process_env)
    if result.returncode:
        if missing and "HTTP 404" in result.stderr:
            return None
        raise PublicationError((result.stderr or result.stdout).strip() or f"Не вдалося виконати {args[0]}")
    return result.stdout.strip()


def api(path, missing=False):
    value = command("gh", "api", path, missing=missing)
    return json.loads(value) if value is not None else None


def git(*args):
    return command("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", *args)


def identity():
    user = api("user")
    require(user["login"].casefold() == OWNER, f"Потрібен вхід у GitHub CLI як {OWNER}.")
    require(isinstance(user["id"], int) and user["id"] > 0, "Не вдалося прочитати GitHub user ID.")
    return f"{user['id']}+{OWNER}@users.noreply.github.com"


def release_assets(release, version):
    ready = ROOT / "build/releases" / f"v{version}-arm64"
    history = ROOT / "build/release-history" / f"v{version}-arm64-before-gpl"
    archived = False
    if ready.exists():
        require(not ready.is_symlink(), "Папка релізу не може бути посиланням.")
        metadata = json.loads((ready / "release-manifest.json").read_text())
        if metadata.get("license") == "GPL-3.0-only":
            release.check(ready)
            require((ready / "INSTALL.md").read_bytes() == (ROOT / "docs/INSTALL.md").read_bytes()
                    and (ready / "RELEASE-NOTES.md").read_bytes() == (ROOT / "docs/releases" / f"{version}.md").read_bytes(),
                    "Документація готового пакета змінилася; підготуй новий пакет окремо.")
            return ready
        require((ready / "VERIFICATION.txt").is_file() and not history.exists() and not history.is_symlink(),
                "Попередній пакет не можна автоматично перенести в історію.")
        release.directory(ROOT / "build/release-history")
        ready.rename(history)
        archived = True
    candidate = None
    try:
        candidate = release.prepare()
        return release.verify(candidate)
    except Exception:
        if candidate is not None:
            print(f"Кандидат збережено: {candidate}", file=sys.stderr)
        if archived and not ready.exists():
            history.rename(ready)
        raise


def commit_source(source, manifest, email):
    source.verify_files(ROOT, manifest)
    if not (ROOT / ".git").exists():
        command("git", "init", "--initial-branch=main")
    require(command("git", "rev-parse", "--show-toplevel") == str(ROOT), "Очікується Git-репозиторій в корені Mixer.")
    require(command("git", "branch", "--show-current") == "main", "Публікація очікує гілку main.")
    origin = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT, capture_output=True, text=True)
    if origin.returncode == 0:
        require(origin.stdout.strip() == REMOTE, "origin указує на інший репозиторій.")
    else:
        command("git", "remote", "add", "origin", REMOTE)
    files = [item["path"] for item in manifest["files"]]
    tracked = set(command("git", "ls-files").splitlines())
    require(tracked <= set(files), "Git вже відстежує файли поза переліком публікації.")
    command("git", "config", "--local", "user.name", OWNER)
    command("git", "config", "--local", "user.email", email)
    command("git", "-c", "core.autocrlf=false", "add", "--", *files)
    staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=ROOT)
    require(staged.returncode in (0, 1), "Не вдалося перевірити Git index.")
    if staged.returncode == 1:
        command("git", "commit", "-m", f"Prepare Mixer {manifest['version']} with GPL-3.0-only")
    require(set(command("git", "ls-tree", "-r", "--name-only", "HEAD").splitlines()) == set(files),
            "Commit не відповідає переліку публікації.")
    for item in manifest["files"]:
        blob = subprocess.run(["git", "show", "HEAD:" + item["path"]], cwd=ROOT, capture_output=True, check=True)
        require(hashlib.sha256(blob.stdout).hexdigest() == item["sha256"],
                f"Commit містить іншу версію файла: {item['path']}")
    return command("git", "rev-parse", "HEAD")


def upload_draft(ready, version, commit):
    tag = "v" + version
    current = api(f"repos/{REPOSITORY}/releases/tags/{tag}", missing=True)
    if current is not None:
        require(current["draft"], "Реліз уже опублікований; автоматично він не змінюється.")
    assets = [ready / f"Mixer-{version}-macOS-arm64.zip", ready / "SHA256SUMS",
              ready / "INSTALL.md", ready / "release-manifest.json"]
    if current is None:
        command("gh", "release", "create", tag, *assets, "--repo", REPOSITORY,
                "--draft", "--prerelease", "--verify-tag", "--target", commit,
                "--title", f"Mixer {version}", "--notes-file", ready / "RELEASE-NOTES.md")
    else:
        existing = {asset["name"] for asset in current["assets"]}
        for path in assets:
            if path.name in existing:
                with tempfile.TemporaryDirectory(prefix=".github-asset-", dir=ROOT / "build") as temporary:
                    command("gh", "release", "download", tag, "--repo", REPOSITORY,
                            "--pattern", path.name, "--dir", temporary)
                    require((Path(temporary) / path.name).read_bytes() == path.read_bytes(),
                            f"У draft уже є інший {path.name}; він не перезаписаний.")
            else:
                command("gh", "release", "upload", tag, path, "--repo", REPOSITORY)
        command("gh", "release", "edit", tag, "--repo", REPOSITORY, "--prerelease",
                "--notes-file", ready / "RELEASE-NOTES.md", "--title", f"Mixer {version}")
    result = api(f"repos/{REPOSITORY}/releases/tags/{tag}")
    require(result["draft"] and result["prerelease"], "Не підтверджено стан draft pre-release.")
    require({p.name for p in assets} <= {a["name"] for a in result["assets"]}, "У draft бракує assets.")
    return result["html_url"]


def main():
    source = module("mixer_source", "prepare-github.py")
    release = module("mixer_release", "release.py")
    try:
        require(shutil.which("gh") and shutil.which("git"), "Потрібні GitHub CLI (gh) та git.")
        manifest, snapshot, archive = source.prepare()
        print(f"Підготовлено {len(manifest['files'])} файлів: {archive}", flush=True)
        email = identity()
        remote = api(f"repos/{REPOSITORY}", missing=True)
        if remote is not None:
            require(remote["full_name"].casefold() == REPOSITORY and not remote["private"],
                    "Існуючий репозиторій має іншу адресу або видимість.")
            existing_release = api(f"repos/{REPOSITORY}/releases/tags/v{manifest['version']}", missing=True)
            require(existing_release is None or existing_release["draft"],
                    "Реліз цієї версії вже опубліковано; репозиторій не змінений.")
            branches = api(f"repos/{REPOSITORY}/branches?per_page=100")
            require(not branches or {b["name"] for b in branches} == {"main"},
                    "Існуючий репозиторій містить інші гілки; він не змінений.")
        ready = release_assets(release, manifest["version"])
        commit = commit_source(source, manifest, email)
        tag = "v" + manifest["version"]
        tags = command("git", "tag", "--list", tag)
        if tags:
            require(command("git", "rev-list", "-n", "1", tag) == commit, "Локальний тег указує на інший commit.")
        else:
            command("git", "tag", "--annotate", tag, "--message", f"Mixer {manifest['version']}", commit)
        if remote is None:
            command("gh", "repo", "create", REPOSITORY, "--public", "--disable-wiki",
                    "--description", "Native per-app audio mixer for macOS 26+ — Swift, AppKit and Core Audio")
        else:
            refs = git("ls-remote", "origin", "refs/heads/main")
            if refs:
                remote_head = refs.split()[0]
                known = subprocess.run(["git", "merge-base", "--is-ancestor", remote_head, commit], cwd=ROOT, capture_output=True)
                require(known.returncode == 0, "Історія віддаленої main відрізняється; force push не виконується.")
        git("push", "--set-upstream", "origin", "main")
        command("gh", "repo", "edit", REPOSITORY, "--default-branch", "main")
        git("push", "origin", "refs/tags/" + tag)
        draft = upload_draft(ready, manifest["version"], commit)
        print(f"Код: https://github.com/{REPOSITORY}\nЧернетка релізу: {draft}")
        print("Реліз залишається draft; бінарний пакет ще не опубліковано.")
    except Exception as error:
        print(f"Публікацію не завершено: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
