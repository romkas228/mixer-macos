// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AudioRealtime
import Foundation

public enum ResourceProfileMode: String, Codable, Sendable {
    case menuBarApp
    case headlessBypass
}

public struct AudioResourceActivity: Codable, Sendable {
    public let visibleAppCount: Int
    public let activeAppCount: Int
    public let activeRouteCount: Int
    public let outputDeviceCount: Int
    public let hardwareRefreshCount: UInt64
    public let routeStartCount: UInt64
}

public struct ResourceMemoryBreakdown: Codable, Sendable {
    public let internalBytes: UInt64
    public let compressedBytes: UInt64
    public let deviceBytes: UInt64
    public let graphicsLedgerFootprintBytes: Int64
    public let graphicsLedgerCompressedBytes: Int64
}

public struct ResourceSample: Codable, Sendable {
    public let elapsedSeconds: Double
    public let cpuNanoseconds: UInt64
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let interruptWakeups: UInt64
    public let idleWakeups: UInt64
    public let audio: AudioResourceActivity
    public let ui: ResourceUIState?
    public let memory: ResourceMemoryBreakdown?

    package init(elapsedSeconds: Double, cpuNanoseconds: UInt64, footprintBytes: UInt64,
                 residentBytes: UInt64, interruptWakeups: UInt64 = 0, idleWakeups: UInt64 = 0,
                 audio: AudioResourceActivity? = nil, ui: ResourceUIState? = nil,
                 memory: ResourceMemoryBreakdown? = nil) {
        self.elapsedSeconds = elapsedSeconds
        self.cpuNanoseconds = cpuNanoseconds
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.interruptWakeups = interruptWakeups
        self.idleWakeups = idleWakeups
        self.audio = audio ?? AudioResourceActivity(visibleAppCount: 0, activeAppCount: 0, activeRouteCount: 0,
                                                   outputDeviceCount: 0, hardwareRefreshCount: 0, routeStartCount: 0)
        self.ui = ui
        self.memory = memory
    }
}

public struct ResourceSummary: Codable, Sendable {
    public let durationSeconds: Double
    // Activity Monitor convention: 100% represents one fully occupied CPU core.
    public let averageCPUPercent: Double
    public let peakSampleCPUPercent: Double
    public let startFootprintBytes: UInt64
    public let endFootprintBytes: UInt64
    public let peakSampledFootprintBytes: UInt64
    public let peakSampledResidentBytes: UInt64
    public let interruptWakeupsPerSecond: Double
    public let idleWakeupsPerSecond: Double
    public let peakFootprintElapsedSeconds: Double?
    public let peakFootprintPanelPhase: ResourcePanelPhase?
    public let finalPanelPhase: ResourcePanelPhase?
    public let visiblePanelSampleCount: Int?
    public let knownPanelSampleCount: Int?
}

public struct ResourceReport: Codable, Sendable {
    public let schemaVersion: Int
    public let appVersion: String
    public let system: String
    public let capturedAt: Date
    public let mode: ResourceProfileMode
    public let summary: ResourceSummary
    public let samples: [ResourceSample]
    public let scope: String

    package init(samples: [ResourceSample], mode: ResourceProfileMode) throws {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else {
            throw ResourceMeasurementError.invalidSamples
        }
        var peakCPU: Double = 0
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let interval = current.elapsedSeconds - previous.elapsedSeconds
            guard interval.isFinite, interval > 0,
                  current.cpuNanoseconds >= previous.cpuNanoseconds,
                  current.interruptWakeups >= previous.interruptWakeups,
                  current.idleWakeups >= previous.idleWakeups else {
                throw ResourceMeasurementError.invalidSamples
            }
            peakCPU = max(peakCPU, Double(current.cpuNanoseconds - previous.cpuNanoseconds) / 1e9 / interval * 100)
        }
        let duration = last.elapsedSeconds - first.elapsedSeconds
        let peakSample = samples.max { $0.footprintBytes < $1.footprintBytes }!
        let knownPanelSamples = samples.filter { $0.ui != nil }
        summary = ResourceSummary(
            durationSeconds: duration,
            averageCPUPercent: Double(last.cpuNanoseconds - first.cpuNanoseconds) / 1e9 / duration * 100,
            peakSampleCPUPercent: peakCPU,
            startFootprintBytes: first.footprintBytes,
            endFootprintBytes: last.footprintBytes,
            peakSampledFootprintBytes: samples.map(\.footprintBytes).max() ?? 0,
            peakSampledResidentBytes: samples.map(\.residentBytes).max() ?? 0,
            interruptWakeupsPerSecond: Double(last.interruptWakeups - first.interruptWakeups) / duration,
            idleWakeupsPerSecond: Double(last.idleWakeups - first.idleWakeups) / duration,
            peakFootprintElapsedSeconds: peakSample.elapsedSeconds,
            peakFootprintPanelPhase: peakSample.ui?.panelPhase,
            finalPanelPhase: last.ui?.panelPhase,
            visiblePanelSampleCount: knownPanelSamples.isEmpty ? nil : knownPanelSamples.filter { $0.ui?.panelPhase == .visible }.count,
            knownPanelSampleCount: knownPanelSamples.isEmpty ? nil : knownPanelSamples.count)
        self.samples = samples
        self.mode = mode
        schemaVersion = 3
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        system = ProcessInfo.processInfo.operatingSystemVersionString
        capturedAt = Date()
        scope = "Current Mixer process only, including measurement overhead. Memory is physical footprint; peaks are sampled. Optional TASK_VM_INFO fields are raw, potentially overlapping accounting counters; graphics ledgers are not total system VRAM or proof of a particular allocation's owner. Wakeups are energy indicators, not watts or Activity Monitor Energy Impact. No coreaudiod, end-to-end audio latency or audio content is measured. Headless mode excludes AppKit UI and uses default bypass preferences."
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

package enum ResourceMeasurementError: LocalizedError {
    case alreadyRunning, unavailable, invalidDuration, invalidSamples

    package var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Вимірювання вже триває."
        case .unavailable: "Зараз вимірювання недоступне."
        case .invalidDuration: "Тривалість вимірювання має бути від 5 до 120 секунд."
        case .invalidSamples: "Не вдалося отримати послідовні показники ресурсів."
        }
    }
}

// Created, sampled and cancelled exclusively on AudioBackend's control queue.
// The timer exists only during an explicitly requested, bounded measurement.
final class ResourceMeasurement: @unchecked Sendable {
    private let queue: DispatchQueue
    private let duration: TimeInterval
    private let mode: ResourceProfileMode
    private let activity: () -> AudioResourceActivity
    private let uiState: () -> ResourceUIState?
    private let completion: (Result<ResourceReport, Error>) -> Void
    private var timer: DispatchSourceTimer?
    private var startTime: UInt64 = 0
    private var samples: [ResourceSample] = []

    init(queue: DispatchQueue, duration: TimeInterval, mode: ResourceProfileMode,
         activity: @escaping () -> AudioResourceActivity,
         uiState: @escaping () -> ResourceUIState? = { nil },
         completion: @escaping (Result<ResourceReport, Error>) -> Void) {
        self.queue = queue
        self.duration = duration
        self.mode = mode
        self.activity = activity
        self.uiState = uiState
        self.completion = completion
    }

    func start() {
        guard duration.isFinite, (5...120).contains(duration) else {
            completion(.failure(ResourceMeasurementError.invalidDuration)); return
        }
        startTime = DispatchTime.now().uptimeNanoseconds
        samples.reserveCapacity(Int(duration) + 2)
        do { try record() }
        catch { completion(.failure(error)); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }

    private func record() throws {
        var reading = MixerProcessMetrics()
        let error = MixerReadOwnProcessMetrics(&reading)
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1e9
        var details = MixerProcessMemoryDetails()
        let memory = MixerReadOwnMemoryDetails(&details) == 0
            ? ResourceMemoryBreakdown(internalBytes: details.internalBytes, compressedBytes: details.compressedBytes,
                                      deviceBytes: details.deviceBytes, graphicsLedgerFootprintBytes: details.graphicsLedgerFootprintBytes,
                                      graphicsLedgerCompressedBytes: details.graphicsLedgerCompressedBytes)
            : nil
        samples.append(ResourceSample(elapsedSeconds: elapsed, cpuNanoseconds: reading.cpuNanoseconds,
                                      footprintBytes: reading.footprintBytes, residentBytes: reading.residentBytes,
                                      interruptWakeups: reading.interruptWakeups, idleWakeups: reading.idleWakeups,
                                      audio: activity(), ui: uiState(), memory: memory))
    }

    private func tick() {
        do {
            try record()
            if let last = samples.last, last.elapsedSeconds >= duration {
                cancel()
                completion(Result { try ResourceReport(samples: samples, mode: mode) })
            }
        } catch {
            cancel()
            completion(.failure(error))
        }
    }

    deinit { timer?.cancel() }
}
