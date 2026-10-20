// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#ifndef MIXER_PROCESS_METRICS_H
#define MIXER_PROCESS_METRICS_H

#include <stdint.h>

typedef struct {
    uint64_t cpuNanoseconds;
    uint64_t footprintBytes;
    uint64_t residentBytes;
    uint64_t interruptWakeups;
    uint64_t idleWakeups;
} MixerProcessMetrics;

typedef struct {
    uint64_t internalBytes;
    uint64_t compressedBytes;
    uint64_t deviceBytes;
    int64_t graphicsLedgerFootprintBytes;
    int64_t graphicsLedgerCompressedBytes;
} MixerProcessMemoryDetails;

// Control/diagnostics only. Never call this from the audio callback.
// Reads only the current process. Returns 0 on success, otherwise an errno value.
int MixerReadOwnProcessMetrics(MixerProcessMetrics *metrics);
// Optional raw TASK_VM_INFO counters. Returns a Mach status (0 on success).
int MixerReadOwnMemoryDetails(MixerProcessMemoryDetails *details);

#endif
