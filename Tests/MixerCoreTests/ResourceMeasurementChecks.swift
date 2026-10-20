// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AudioRealtime
import Foundation
import MixerCore

func resourceSummaryUsesElapsedCPUAndPhysicalFootprint() throws {
    let samples = [
        ResourceSample(elapsedSeconds: 0, cpuNanoseconds: 5_000_000_000, footprintBytes: 100,
                       residentBytes: 300, interruptWakeups: 10, idleWakeups: 4),
        ResourceSample(elapsedSeconds: 1, cpuNanoseconds: 6_000_000_000, footprintBytes: 200,
                       residentBytes: 600, interruptWakeups: 12, idleWakeups: 4),
        ResourceSample(elapsedSeconds: 3, cpuNanoseconds: 10_000_000_000, footprintBytes: 150,
                       residentBytes: 450, interruptWakeups: 19, idleWakeups: 7),
    ]
    let report = try ResourceReport(samples: samples, mode: .headlessBypass)
    let summary = report.summary
    // Unequal sampling intervals must be weighted by duration, and CPU can exceed one core.
    guard abs(summary.averageCPUPercent - 500.0 / 3) < 0.0001,
          summary.peakSampleCPUPercent == 200, summary.durationSeconds == 3,
          summary.startFootprintBytes == 100, summary.endFootprintBytes == 150,
          summary.peakSampledFootprintBytes == 200, summary.peakSampledResidentBytes == 600,
          summary.interruptWakeupsPerSecond == 3, summary.idleWakeupsPerSecond == 1 else {
        throw ResourceCheckFailure("Resource summary confused cumulative CPU, duration or memory metrics")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ResourceReport.self, from: report.jsonData())
    guard decoded.mode == .headlessBypass, decoded.samples.count == 3,
          decoded.summary.peakSampledFootprintBytes == 200 else {
        throw ResourceCheckFailure("Resource JSON did not preserve report values")
    }
}

func resourceSummaryRejectsResetCountersAndInvalidTime() throws {
    let first = ResourceSample(elapsedSeconds: 0, cpuNanoseconds: 100, footprintBytes: 1, residentBytes: 1,
                               interruptWakeups: 2)
    for last in [
        ResourceSample(elapsedSeconds: 1, cpuNanoseconds: 99, footprintBytes: 1, residentBytes: 1, interruptWakeups: 2),
        ResourceSample(elapsedSeconds: 0, cpuNanoseconds: 101, footprintBytes: 1, residentBytes: 1, interruptWakeups: 2),
        ResourceSample(elapsedSeconds: .nan, cpuNanoseconds: 101, footprintBytes: 1, residentBytes: 1, interruptWakeups: 2),
        ResourceSample(elapsedSeconds: 1, cpuNanoseconds: 101, footprintBytes: 1, residentBytes: 1, interruptWakeups: 1),
    ] {
        do {
            _ = try ResourceReport(samples: [first, last], mode: .headlessBypass)
            throw ResourceCheckFailure("Invalid samples were accepted")
        } catch ResourceMeasurementError.invalidSamples {}
    }
}

func resourceReaderUsesOnlyOwnProcessAndMonotonicCPU() throws {
    var first = MixerProcessMetrics(), last = MixerProcessMetrics()
    var details = MixerProcessMemoryDetails()
    guard MixerReadOwnProcessMetrics(nil) == EINVAL,
          MixerReadOwnProcessMetrics(&first) == 0, MixerReadOwnProcessMetrics(&last) == 0,
          last.cpuNanoseconds >= first.cpuNanoseconds,
          first.footprintBytes > 0, first.residentBytes > 0,
          MixerReadOwnMemoryDetails(nil) != 0, MixerReadOwnMemoryDetails(&details) == 0,
          details.internalBytes > 0 else {
        throw ResourceCheckFailure("The current process resource reader failed")
    }
}

private struct ResourceCheckFailure: Error {
    let description: String
    init(_ description: String) { self.description = description }
}
