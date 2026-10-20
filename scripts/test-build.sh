#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
projectRoot="${0:A:h:h}"
cd "$projectRoot"
mkdir -p .build/tools
clang -O2 -Wall -Wextra -Werror scripts/publish-app.c -o .build/tools/publish-app
testDirectory=$(mktemp -d "${TMPDIR:-/tmp}/mixer-build-checks.XXXXXX")
trap 'rm -rf -- "$testDirectory"' EXIT

mkdir -p "$testDirectory/staged.app" "$testDirectory/installed.app"
print -- new > "$testDirectory/staged.app/version"
print -- old > "$testDirectory/installed.app/version"
print -- obsolete > "$testDirectory/installed.app/old-only"
.build/tools/publish-app "$testDirectory/staged.app" "$testDirectory/installed.app"
[[ $(< "$testDirectory/installed.app/version") == new ]]
[[ ! -e "$testDirectory/installed.app/old-only" ]]
[[ $(< "$testDirectory/staged.app/version") == old ]]
[[ -f "$testDirectory/staged.app/old-only" ]]
print -- "PASS: Complete bundles exchange without merging old resources"

mkdir "$testDirectory/first.app"
print -- first > "$testDirectory/first.app/version"
.build/tools/publish-app "$testDirectory/first.app" "$testDirectory/new.app"
[[ $(< "$testDirectory/new.app/version") == first && ! -e "$testDirectory/first.app" ]]
print -- "PASS: Initial publication moves the complete bundle"

print -- keep > "$testDirectory/not-a-directory"
if .build/tools/publish-app "$testDirectory/staged.app" "$testDirectory/not-a-directory" 2> "$testDirectory/error"; then
    print -u2 -- "FAIL: A non-directory destination was overwritten"; exit 1
fi
[[ $(< "$testDirectory/not-a-directory") == keep && -f "$testDirectory/staged.app/version" ]]
ln -s "$testDirectory/installed.app" "$testDirectory/symlink.app"
if .build/tools/publish-app "$testDirectory/staged.app" "$testDirectory/symlink.app" 2> "$testDirectory/error"; then
    print -u2 -- "FAIL: A symbolic link destination was overwritten"; exit 1
fi
[[ -L "$testDirectory/symlink.app" && $(< "$testDirectory/installed.app/version") == new ]]
print -- "PASS: Invalid destinations preserve existing and staged content"

identityFile="$projectRoot/.mixer-signing/identity.sha1"
configurationBefore=absent
if [[ -f "$identityFile" ]]; then configurationBefore=$(shasum -a 256 "$identityFile"); fi
if ./scripts/signing.sh configure invalid > "$testDirectory/log" 2>&1; then
    print -u2 -- "FAIL: An invalid identity was accepted"; exit 1
fi
if ./scripts/signing.sh configure 0000000000000000000000000000000000000000 > "$testDirectory/log" 2>&1; then
    print -u2 -- "FAIL: An unavailable identity was accepted"; exit 1
fi
configurationAfter=absent
if [[ -f "$identityFile" ]]; then configurationAfter=$(shasum -a 256 "$identityFile"); fi
[[ "$configurationBefore" == "$configurationAfter" ]]
print -- "PASS: Invalid or unavailable certificates cannot change the selected identity"

fixture="$testDirectory/Project"
mkdir -p "$fixture/scripts" "$fixture/.mixer-signing" "$fixture/build/Mixer.app"
cp scripts/build.sh scripts/signing.sh "$fixture/scripts/"
print -- 0000000000000000000000000000000000000000 > "$fixture/.mixer-signing/identity.sha1"
print -- preserved > "$fixture/build/Mixer.app/sentinel"
if "$fixture/scripts/build.sh" > "$testDirectory/log" 2>&1; then
    print -u2 -- "FAIL: The build accepted an unavailable configured certificate"; exit 1
fi
[[ $(< "$fixture/build/Mixer.app/sentinel") == preserved && ! -d "$fixture/.build" ]]
print -- "PASS: Missing configured keys stop the build before replacing the installed app"

pendingFixture="$testDirectory/PendingProject"
mkdir -p "$pendingFixture/scripts" "$pendingFixture/build/Mixer.app"
cp scripts/build.sh scripts/signing.sh "$pendingFixture/scripts/"
print -- preserved > "$pendingFixture/build/Mixer.app/sentinel"
"$pendingFixture/scripts/signing.sh" prepare 0000000000000000000000000000000000000000 > "$testDirectory/log"
if "$pendingFixture/scripts/build.sh" > "$testDirectory/log" 2>&1; then
    print -u2 -- "FAIL: Pending identity silently fell back to ad-hoc"; exit 1
fi
if "$pendingFixture/scripts/signing.sh" configure 1111111111111111111111111111111111111111 > "$testDirectory/log" 2>&1; then
    print -u2 -- "FAIL: A different identity replaced the prepared fingerprint"; exit 1
fi
[[ $(< "$pendingFixture/build/Mixer.app/sentinel") == preserved && ! -d "$pendingFixture/.build" ]]
[[ $(< "$pendingFixture/.mixer-signing/pending.sha1") == 0000000000000000000000000000000000000000 ]]
[[ ! -e "$pendingFixture/.mixer-signing/identity.sha1" ]]
print -- "PASS: A prepared identity blocks ad-hoc fallback and rejects a different fingerprint"

print -- "6/6 build checks passed"
