#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
projectRoot="${0:A:h:h}"
cd "$projectRoot"
mkdir -p .build/benchmarks
clang -O2 -DNDEBUG -I Sources/AudioRealtime/include \
    Benchmarks/AudioRenderBenchmark.c Sources/AudioRealtime/AudioRealtime.c \
    -framework CoreAudio -o .build/benchmarks/AudioRenderBenchmark
exec .build/benchmarks/AudioRenderBenchmark
