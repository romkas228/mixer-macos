#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
projectRoot="${0:A:h:h}"
cd "$projectRoot"
fail() { print -u2 -- "$*"; exit 1; }

fingerprint=$(./scripts/signing.sh preflight)
[[ "$fingerprint" != "-" ]] || fail "Спочатку налаштуй постійний сертифікат і створи збірку. Див. docs/SIGNING.md."
./scripts/signing.sh verify

testDirectory=$(mktemp -d "${TMPDIR:-/tmp}/mixer-signing-checks.XXXXXX")
trap 'rm -rf -- "$testDirectory"' EXIT
mkdir "$testDirectory/first" "$testDirectory/second"
cp -R build/Mixer.app "$testDirectory/first/Mixer.app"
cp -R build/Mixer.app "$testDirectory/second/Mixer.app"
firstApp="$testDirectory/first/Mixer.app"
secondApp="$testDirectory/second/Mixer.app"
# Change signed content without launching either fixture or touching the installed app.
/usr/bin/plutil -replace CFBundleVersion -string 1.1 "$firstApp/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string 1.2 "$secondApp/Contents/Info.plist"
./scripts/signing.sh sign "$firstApp" "$fingerprint"
./scripts/signing.sh sign "$secondApp" "$fingerprint"

codeHash() {
    /usr/bin/codesign --display --verbose=4 "$1" 2>&1 | /usr/bin/awk '/^CDHash=/ { sub(/^CDHash=/, ""); print }'
}
firstHash=$(codeHash "$firstApp")
secondHash=$(codeHash "$secondApp")
[[ -n "$firstHash" && -n "$secondHash" && "$firstHash" != "$secondHash" ]] \
    || fail "FAIL: Тестові збірки повинні мати різні хеші підписаного вмісту."
./scripts/signing.sh verify "$firstApp"
./scripts/signing.sh verify "$secondApp"
print -- "PASS: Different signed builds satisfy the saved certificate-bound identity"

cmp "$testDirectory/first/requirements.txt" "$testDirectory/second/requirements.txt"
print -- "PASS: The designated requirement remains identical across changed builds"

cp -R "$secondApp" "$testDirectory/Tampered.app"
print -- tampered > "$testDirectory/Tampered.app/Contents/Resources/signing-tamper-check"
if ./scripts/signing.sh verify "$testDirectory/Tampered.app" > "$testDirectory/tampered.log" 2>&1; then
    fail "FAIL: Змінені після підпису ресурси пройшли перевірку."
fi
print -- "PASS: Signature verification rejects tampered resources"

cp -R "$secondApp" "$testDirectory/OtherSigner.app"
/usr/bin/codesign --force --sign - --timestamp=none "$testDirectory/OtherSigner.app"
/usr/bin/codesign --verify --strict "$testDirectory/OtherSigner.app"
if ./scripts/signing.sh verify "$testDirectory/OtherSigner.app" > "$testDirectory/other-signer.log" 2>&1; then
    fail "FAIL: Ad-hoc заміна підписувача задовольнила постійну identity."
fi
print -- "PASS: A valid signature from a different signer is rejected"
print -- "4/4 signing checks passed. Системний дозвіл на звук ці перевірки не перевіряють."
