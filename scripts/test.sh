#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
projectRoot="${0:A:h:h}"
cd "$projectRoot"
export CLANG_MODULE_CACHE_PATH="$projectRoot/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$projectRoot/.build/ModuleCache"
swift run --configuration debug --disable-sandbox --cache-path "$projectRoot/.build/cache" --config-path "$projectRoot/.build/config" --security-path "$projectRoot/.build/security" MixerChecks
