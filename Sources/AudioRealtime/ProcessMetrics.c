// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#include "ProcessMetrics.h"
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <unistd.h>

int MixerReadOwnProcessMetrics(MixerProcessMetrics *metrics) {
    if (!metrics) return EINVAL;
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0)
        return errno ? errno : EIO;
    *metrics = (MixerProcessMetrics){
        .cpuNanoseconds = usage.ri_user_time + usage.ri_system_time,
        .footprintBytes = usage.ri_phys_footprint,
        .residentBytes = usage.ri_resident_size,
        .interruptWakeups = usage.ri_interrupt_wkups,
        .idleWakeups = usage.ri_pkg_idle_wkups,
    };
    return 0;
}

int MixerReadOwnMemoryDetails(MixerProcessMemoryDetails *details) {
    if (!details) return KERN_INVALID_ARGUMENT;
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (status != KERN_SUCCESS) return status;
    if (count < TASK_VM_INFO_REV3_COUNT) return KERN_FAILURE;
    *details = (MixerProcessMemoryDetails){
        .internalBytes = info.internal,
        .compressedBytes = info.compressed,
        .deviceBytes = info.device,
        .graphicsLedgerFootprintBytes = info.ledger_tag_graphics_footprint,
        .graphicsLedgerCompressedBytes = info.ledger_tag_graphics_footprint_compressed,
    };
    return KERN_SUCCESS;
}
