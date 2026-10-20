#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
projectRoot="${0:A:h:h}"
cd "$projectRoot"
export CLANG_MODULE_CACHE_PATH="$projectRoot/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$projectRoot/.build/ModuleCache"
buildOptions=(--disable-sandbox --configuration debug --cache-path "$projectRoot/.build/cache" --config-path "$projectRoot/.build/config" --security-path "$projectRoot/.build/security")
swift build --product MixerChecks "${buildOptions[@]}"
binaryDirectory=$(swift build "${buildOptions[@]}" --show-bin-path)
mkdir -p .build/tools
# Compile the actual AppKit views into a test-only executable, without AppDelegate or audio startup.
swiftc -swift-version 6 -parse-as-library -package-name mixer_macos \
    -module-cache-path "$projectRoot/.build/ModuleCache" \
    -I "$binaryDirectory/Modules" -I "$binaryDirectory/AudioRealtime.build" \
    Sources/Mixer/AppIconCache.swift Sources/Mixer/MixerPanel.swift Sources/Mixer/MenuBarPanel.swift \
    Tests/MixerInterfaceChecks/MixerInterfaceChecks.swift \
    "$binaryDirectory"/MixerCore.build/*.swift.o "$binaryDirectory"/AudioRealtime.build/*.c.o \
    -framework AppKit -framework CoreAudio -framework ServiceManagement \
    -o .build/tools/MixerInterfaceChecks
.build/tools/MixerInterfaceChecks
