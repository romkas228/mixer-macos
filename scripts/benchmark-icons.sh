#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
projectRoot="${0:A:h:h}"
cd "$projectRoot"
mkdir -p .build/benchmarks
export CLANG_MODULE_CACHE_PATH="$projectRoot/.build/ModuleCache"
clang -O2 -I Sources/AudioRealtime/include -I Benchmarks \
    -c Benchmarks/IconLoadingBenchmark.c -o .build/benchmarks/IconLoadingBenchmark.o
binaryDirectory=$(swift build --configuration release --disable-sandbox --cache-path "$projectRoot/.build/cache" --config-path "$projectRoot/.build/config" --security-path "$projectRoot/.build/security" --show-bin-path)
projectDirectoryName="${projectRoot:t:l}"
packageIdentity="${projectDirectoryName//-/_}"
swiftc -O -package-name "$packageIdentity" -I "$binaryDirectory/Modules" -I "$binaryDirectory/AudioRealtime.build" \
    -import-objc-header Benchmarks/IconLoadingBenchmark.h \
    Sources/Mixer/AppIconCache.swift Sources/Mixer/MixerPanel.swift Sources/Mixer/MenuBarPanel.swift Benchmarks/IconLoadingBenchmark.swift \
    "$binaryDirectory"/MixerCore.build/*.o "$binaryDirectory"/AudioRealtime.build/*.o \
    .build/benchmarks/IconLoadingBenchmark.o \
    -o .build/benchmarks/IconLoadingBenchmark
exec .build/benchmarks/IconLoadingBenchmark "$@"
