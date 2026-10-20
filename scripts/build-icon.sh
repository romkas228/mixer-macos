#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

projectRoot="${0:A:h:h}"
sourceImage="$projectRoot/Resources/AppIcon.png"
outputIcon="$projectRoot/Resources/AppIcon.icns"
iconset="$projectRoot/.build/AppIcon.iconset"

# The source is kept in the project; only the multi-resolution ICNS goes into the app.
if [[ -f "$outputIcon" && "$outputIcon" -nt "$sourceImage" && "$outputIcon" -nt "$0" && "$outputIcon" -nt "$projectRoot/scripts/pack-icon.swift" ]]; then
    exit 0
fi
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$sourceImage" --out "$iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$sourceImage" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
swift -module-cache-path "$projectRoot/.build/ModuleCache" "$projectRoot/scripts/pack-icon.swift" "$iconset" "$outputIcon"
print "Іконку зібрано: $outputIcon"
