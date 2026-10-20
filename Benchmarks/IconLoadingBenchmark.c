// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#include "IconLoadingBenchmark.h"
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>

uint64_t MixerBenchmarkPeakFootprint(void) {
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return 0;
    return usage.ri_lifetime_max_phys_footprint;
}
