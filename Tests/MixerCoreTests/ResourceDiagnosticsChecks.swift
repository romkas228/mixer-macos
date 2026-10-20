// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MixerCore

func resourcePeakCorrelatesWithPanelState() throws {
    let tracker = ResourceUITracker()
    let hidden = tracker.snapshot()
    tracker.setPanel(phase: .preparing)
    tracker.recordIcon(cacheHit: false)
    let preparing = tracker.snapshot()
    tracker.setPanel(phase: .visible, width: 360, height: 500, backingScaleFactor: 2)
    tracker.recordIcon(cacheHit: true)
    let visible = tracker.snapshot()
    tracker.setPanel(phase: .hidden)
    let samples = [hidden, preparing, visible, tracker.snapshot()].enumerated().map { index, ui in
        ResourceSample(elapsedSeconds: Double(index), cpuNanoseconds: UInt64(index * 1000),
                       footprintBytes: [100, 200, 400, 150][index], residentBytes: 500, ui: ui)
    }
    let report = try ResourceReport(samples: samples, mode: .menuBarApp)
    guard report.summary.peakFootprintElapsedSeconds == 2,
          report.summary.peakFootprintPanelPhase == .visible,
          report.summary.finalPanelPhase == .hidden,
          report.summary.visiblePanelSampleCount == 1, report.summary.knownPanelSampleCount == 4,
          visible.panelOpenCount == 1, visible.panelWidth == 360, visible.panelHeight == 500,
          visible.backingScaleFactor == 2, visible.iconRenderCount == 1, visible.iconCacheHitCount == 1 else {
        throw DiagnosticsCheckFailure("The memory peak was not associated with the sampled UI state")
    }
}

func resourceUITrackerHandlesConcurrentCounters() throws {
    let tracker = ResourceUITracker()
    DispatchQueue.concurrentPerform(iterations: 1000) { tracker.recordIcon(cacheHit: $0.isMultiple(of: 2)) }
    let state = tracker.snapshot()
    guard state.iconCacheHitCount == 500, state.iconRenderCount == 500,
          state.panelPhase == .hidden else { throw DiagnosticsCheckFailure("UI counters lost concurrent updates") }
}

func resourceBackgroundMetadataPreservesOlderReports() throws {
    let tracker = ResourceUITracker()
    tracker.setPanel(phase: .visible, width: 360, height: 406, backingScaleFactor: 2,
                     background: .opaqueDiagnostic)
    let ui = tracker.snapshot()
    let report = try ResourceReport(samples: [
        ResourceSample(elapsedSeconds: 0, cpuNanoseconds: 0, footprintBytes: 100, residentBytes: 200, ui: ui),
        ResourceSample(elapsedSeconds: 1, cpuNanoseconds: 10, footprintBytes: 150, residentBytes: 200, ui: ui),
    ], mode: .menuBarApp)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let current = try decoder.decode(ResourceReport.self, from: report.jsonData())
    guard current.schemaVersion == 3,
          current.samples.allSatisfy({ $0.ui?.panelBackground == .opaqueDiagnostic }) else {
        throw DiagnosticsCheckFailure("The control background was not recorded in the report")
    }

    var object = try JSONSerialization.jsonObject(with: report.jsonData()) as! [String: Any]
    object["schemaVersion"] = 2
    var samples = object["samples"] as! [[String: Any]]
    for index in samples.indices {
        var state = samples[index]["ui"] as! [String: Any]
        state.removeValue(forKey: "panelBackground")
        samples[index]["ui"] = state
    }
    object["samples"] = samples
    let older = try decoder.decode(ResourceReport.self, from: JSONSerialization.data(withJSONObject: object))
    guard older.samples.allSatisfy({ $0.ui?.panelPhase == .visible && $0.ui?.panelBackground == nil }) else {
        throw DiagnosticsCheckFailure("An older report acquired an invented background style")
    }
}

func resourceReportsDecodeOlderSchemaWithoutInventingUIState() throws {
    let report = try diagnosticReport(footprint: 100)
    var object = try JSONSerialization.jsonObject(with: report.jsonData()) as! [String: Any]
    object["schemaVersion"] = 1
    var summary = object["summary"] as! [String: Any]
    for key in ["peakFootprintElapsedSeconds", "peakFootprintPanelPhase", "finalPanelPhase",
                "visiblePanelSampleCount", "knownPanelSampleCount"] { summary.removeValue(forKey: key) }
    object["summary"] = summary
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ResourceReport.self, from: JSONSerialization.data(withJSONObject: object))
    guard decoded.schemaVersion == 1, decoded.summary.peakFootprintElapsedSeconds == nil,
          decoded.summary.knownPanelSampleCount == nil,
          decoded.samples.allSatisfy({ $0.ui == nil && $0.memory == nil }) else {
        throw DiagnosticsCheckFailure("An older report acquired invented UI or memory details")
    }
}

func developmentArchiveWritesOneFileOnlyForProjectBuilds() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = directory.appendingPathComponent("Project")
    let app = project.appendingPathComponent("build/Mixer.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("// fixture".utf8).write(to: project.appendingPathComponent("Package.swift"))
    let first = try DevelopmentResourceArchive.save(diagnosticReport(footprint: 100), appBundleURL: app)
    let last = try DevelopmentResourceArchive.save(diagnosticReport(footprint: 200), appBundleURL: app)
    guard let first, let last, first == last,
          last.path == project.appendingPathComponent("build/Diagnostics/latest-resources.json").path else {
        throw DiagnosticsCheckFailure("The development report did not use the expected local path")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let report = try decoder.decode(ResourceReport.self, from: Data(contentsOf: last))
    let names = try FileManager.default.contentsOfDirectory(atPath: last.deletingLastPathComponent().path)
    guard report.summary.endFootprintBytes == 200, names == ["latest-resources.json"],
          try DevelopmentResourceArchive.save(report, appBundleURL: directory.appendingPathComponent("Applications/Mixer.app")) == nil else {
        throw DiagnosticsCheckFailure("The archive accumulated files or wrote outside a local build")
    }
}

private func diagnosticReport(footprint: UInt64) throws -> ResourceReport {
    try ResourceReport(samples: [
        ResourceSample(elapsedSeconds: 0, cpuNanoseconds: 0, footprintBytes: footprint, residentBytes: footprint),
        ResourceSample(elapsedSeconds: 1, cpuNanoseconds: 100, footprintBytes: footprint, residentBytes: footprint),
    ], mode: .menuBarApp)
}

private struct DiagnosticsCheckFailure: Error {
    let description: String
    init(_ description: String) { self.description = description }
}
