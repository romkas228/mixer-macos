#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

projectRoot="${0:A:h:h}"
cd "$projectRoot"
export CLANG_MODULE_CACHE_PATH="$projectRoot/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$projectRoot/.build/ModuleCache"
configuration="${1:-release}"
# Fail before touching the existing app if a configured certificate/key is unavailable.
signingIdentity=$("$projectRoot/scripts/signing.sh" preflight)
"$projectRoot/scripts/build-icon.sh"
swift build --product Mixer --disable-sandbox --configuration "$configuration" --cache-path "$projectRoot/.build/cache" --config-path "$projectRoot/.build/config" --security-path "$projectRoot/.build/security"
binaryDirectory=$(swift build --disable-sandbox --configuration "$configuration" --cache-path "$projectRoot/.build/cache" --config-path "$projectRoot/.build/config" --security-path "$projectRoot/.build/security" --show-bin-path)
appPath="$projectRoot/build/Mixer.app"
mkdir -p "$projectRoot/build" "$projectRoot/.build/tools"
stagingDirectory=$(mktemp -d "$projectRoot/build/.Mixer-stage.XXXXXX")
trap 'rm -rf -- "$stagingDirectory"' EXIT
stagedApp="$stagingDirectory/Mixer.app"
mkdir -p "$stagedApp/Contents/MacOS" "$stagedApp/Contents/Resources"
cp "$binaryDirectory/Mixer" "$stagedApp/Contents/MacOS/Mixer"
cp "$projectRoot/Resources/Info.plist" "$stagedApp/Contents/Info.plist"
cp "$projectRoot/Resources/AppIcon.icns" "$stagedApp/Contents/Resources/AppIcon.icns"
cp "$projectRoot/LICENSE" "$stagedApp/Contents/Resources/LICENSE.txt"
cp "$projectRoot/NOTICE" "$stagedApp/Contents/Resources/NOTICE.txt"
"$projectRoot/scripts/signing.sh" sign "$stagedApp" "$signingIdentity"
clang -O2 -Wall -Wextra -Werror "$projectRoot/scripts/publish-app.c" -o "$projectRoot/.build/tools/publish-app"
"$projectRoot/.build/tools/publish-app" "$stagedApp" "$appPath"
print "Готово: $appPath"
