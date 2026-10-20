// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AudioRealtime
import CoreAudio
import Foundation
import MixerCore

func preferencesClampAndRestoreMutedVolume() throws {
    try expect(AppPreference(volume: -1).gain == 0)
    try expect(AppPreference(volume: 2).gain == 1)
    try expect(AppPreference(volume: .nan).gain == 1)
    let preference = AppPreference(volume: 0.37, muted: true, outputUID: "headphones")
    try expect(preference.gain == 0)
    try expect(preference.volume == 0.37)
    try expect(try JSONDecoder().decode(AppPreference.self, from: JSONEncoder().encode(preference)) == preference)
    let corrupt = Data("{\"volume\":8,\"muted\":false}".utf8)
    try expect(try JSONDecoder().decode(AppPreference.self, from: corrupt).volume == 1)
}

func audioTaperPreservesStoredPercentagesAndMute() throws {
    // Load the old preferences format: keep 50% on the slider, apply the new attenuation.
    let stored = Data("{\"volume\":0.5,\"muted\":true,\"outputUID\":\"headphones\"}".utf8)
    var preference = try JSONDecoder().decode(AppPreference.self, from: stored)
    try expect(preference.volume == 0.5 && preference.gain == 0)
    preference.muted = false
    try expect(preference.volume == 0.5 && preference.gain == 0.25)
    try expect(preference.outputUID == "headphones")
    let restored = try JSONDecoder().decode(AppPreference.self, from: JSONEncoder().encode(preference))
    try expect(restored == preference && restored.gain == 0.25)

    var previous: Float = -1
    for step in 0...1000 {
        let gain = AppPreference(volume: Double(step) / 1000).gain
        try expect(gain > previous && gain >= 0 && gain <= 1)
        previous = gain
    }
    // The public property can also be mutated after initialization.
    for invalid in [Double.nan, .infinity, -.infinity] {
        preference.volume = invalid
        try expect(preference.gain == 1)
    }
    preference.volume = -1
    try expect(preference.gain == 0)
    preference.volume = 2
    try expect(preference.gain == 1)
}

func sliderPercentagesProduceExpectedStereoAttenuation() throws {
    let levels: [(Double, Float)] = [(0, 0), (0.25, 0.0625), (0.5, 0.25), (0.75, 0.5625), (1, 1)]
    for (percentage, expectedAmplitude) in levels {
        let context = try require(MixerRenderContextCreate(AppPreference(volume: percentage).gain, 48_000, 0, 2))
        defer { MixerRenderContextDestroy(context) }
        let input = PCMList(channels: [Array(repeating: 0.8, count: 512), Array(repeating: -0.4, count: 512)])
        let output = PCMList(channels: [Array(repeating: 9, count: 512), Array(repeating: 9, count: 512)])
        render(context, input, output)
        try expect(abs(output.samples(0).last! - 0.8 * expectedAmplitude) < 0.0001)
        try expect(abs(output.samples(1).last! + 0.4 * expectedAmplitude) < 0.0001)
        if percentage == 0 {
            try expect(output.samples(0).allSatisfy { $0 == 0 } && output.samples(1).allSatisfy { $0 == 0 })
        }
    }
}

func standardPlaybackBypassesProcessing() throws {
    try expect(!AppPreference().needsProcessing)
    try expect(AppPreference(volume: 0.99).needsProcessing)
    try expect(AppPreference(muted: true).needsProcessing)
    try expect(AppPreference(outputUID: "speakers").needsProcessing)
}

func disconnectedOutputFallsBackAndReturnsWhenReconnected() throws {
    let speakers = device(1, "speakers")
    let headphones = device(2, "headphones")
    let preference = AppPreference(outputUID: "headphones")
    try expect(RoutingPolicy.output(for: preference, devices: [speakers, headphones], defaultUID: "speakers") == headphones)
    try expect(RoutingPolicy.output(for: preference, devices: [speakers], defaultUID: "speakers") == speakers)
    try expect(preference.outputUID == "headphones")
    try expect(RoutingPolicy.output(for: preference, devices: [speakers, headphones], defaultUID: "speakers") == headphones)
    try expect(RoutingPolicy.output(for: preference, devices: [], defaultUID: nil) == nil)
}

func followingSystemOutputDoesNotPinADevice() throws {
    let first = device(1, "first"), second = device(2, "second")
    try expect(RoutingPolicy.output(for: AppPreference(volume: 0.5), devices: [first, second], defaultUID: "second") == second)
    try expect(RoutingPolicy.output(for: AppPreference(), devices: [first], defaultUID: nil) == nil)
}

func helperBundleUsesContainingApplication() throws {
    let helper = URL(fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Helper.app")
    try expect(ProcessIdentity.outermostApp(helper)?.path == "/Applications/Browser.app")
    try expect(ProcessIdentity.outermostApp(URL(fileURLWithPath: "/usr/bin/afplay")) == nil)
}

func permissionRequestDoesNotMuteAppsOrOpenPhysicalDevices() throws {
    let tap = SystemAudioAccess.tapDescription()
    try expect(tap.muteBehavior == .unmuted)
    try expect(tap.isPrivate)
    // A global input can request consent before any source app starts playing.
    try expect(tap.isExclusive)
    try expect(tap.processes.isEmpty)
    let aggregate = SystemAudioAccess.aggregateDescription(tapUID: "test-tap")
    let devices = try require(aggregate[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
    try expect(devices.isEmpty)
    try expect(aggregate[kAudioAggregateDeviceMainSubDeviceKey] == nil)
    let taps = try require(aggregate[kAudioAggregateDeviceTapListKey] as? [[String: String]])
    try expect(taps.count == 1 && taps[0][kAudioSubTapUIDKey] == "test-tap")
}

func optionalBindingsKeepNativePropertyBufferSizes() throws {
    // Reproduce the exact `try?` + typed optional-binding context used by device discovery.
    // Without a constrained value type Swift can infer Optional<UInt32>/Optional<Double> here.
    guard let alive: UInt32 = try? NativeAudioProperty.read(initial: 0, fill: { data, size in
        try expect(size == 4)
        data.storeBytes(of: UInt32(1), as: UInt32.self)
    }) else { throw CheckFailure(description: "A live device was rejected by its property read") }
    try expect(alive == 1)
    guard let rate: Double = try? NativeAudioProperty.read(initial: 0, fill: { data, size in
        try expect(size == 8)
        data.storeBytes(of: Double(48_000), as: Double.self)
    }) else { throw CheckFailure(description: "A valid sample rate was rejected by its property read") }
    try expect(rate == 48_000)
}

func nativePropertyReadsPIDAndStreamFormatWithoutOptionalStorage() throws {
    let pid: Int32 = try NativeAudioProperty.read(initial: Int32(0)) { data, size in
        try expect(size == 4)
        data.storeBytes(of: Int32(1234), as: Int32.self)
    }
    try expect(pid == 1234)
    var expected = AudioStreamBasicDescription()
    expected.mSampleRate = 44_100
    expected.mChannelsPerFrame = 2
    let format = try NativeAudioProperty.read(initial: AudioStreamBasicDescription()) { data, size in
        try expect(size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        data.storeBytes(of: expected, as: AudioStreamBasicDescription.self)
    }
    try expect(format.mSampleRate == 44_100 && format.mChannelsPerFrame == 2)
}

func nativePropertyRejectsPartialReads() throws {
    do {
        _ = try NativeAudioProperty.read(initial: UInt32(0)) { _, size in size = 2 }
        throw CheckFailure(description: "A partial Core Audio property read was accepted")
    } catch let error as NativeAudioProperty.ReadError {
        try expect(error == .unexpectedSize(expected: 4, actual: 2))
    }
}

func audioFailuresOnlyMentionPermissionsForAPermissionsError() throws {
    let format = RouteFailure(error: HardwareError(operation: "Непідтримуваний формат звуку", status: kAudioDeviceUnsupportedFormatError))
    try expect(format.message == "Непідтримуваний формат звуку")
    try expect(format.details.contains("Core Audio:"))
    let denied = RouteFailure(error: HardwareError(operation: "Не вдалося запустити аудіопотік", status: kAudioDevicePermissionsError))
    try expect(denied.message.contains("доступ до системного звуку"))
    let missing = RouteFailure(message: "Немає доступного аудіовиходу.")
    try expect(!missing.message.contains("дозвіл"))
}

func renderAttenuatesStereoAndSmoothsGainChanges() throws {
    let frames = 512
    let context = try require(MixerRenderContextCreate(0.5, 48_000, 0, 2))
    defer { MixerRenderContextDestroy(context) }
    let input = PCMList(channels: [Array(repeating: 0.8, count: frames), Array(repeating: -0.4, count: frames)])
    let output = PCMList(channels: [Array(repeating: 9, count: frames), Array(repeating: 9, count: frames)])
    render(context, input, output)
    try expect(abs(output.samples(0).last! - 0.4) < 0.0001)
    try expect(abs(output.samples(1).last! + 0.2) < 0.0001)
    try expect(output.samples(0)[0] > 0 && output.samples(0)[0] < 0.01)
    MixerRenderContextSetGain(context, 0)
    render(context, input, output)
    try expect(output.samples(0)[0] > 0.38) // De-click instead of an abrupt mute.
    try expect(output.samples(0).last == 0)
    try expect(output.samples(1).last == 0)
    try expect(MixerRenderContextCallbackCount(context) == 2)
}

func renderHandlesInterleavedStereoAndMonoOutput() throws {
    let context = try require(MixerRenderContextCreate(1, 48_000, 0, 1))
    defer { MixerRenderContextDestroy(context) }
    let input = PCMList(channels: [Array(repeating: [Float(0.6), Float(0.2)], count: 512).flatMap { $0 }],
                        channelCounts: [2])
    let output = PCMList(channels: [Array(repeating: 9, count: 512)])
    render(context, input, output)
    try expect(abs(output.samples(0).last! - 0.4) < 0.0001)
}

func renderSkipsPhysicalInputAndClearsUnusedOutputChannels() throws {
    let context = try require(MixerRenderContextCreate(1, 48_000, 1, 4))
    defer { MixerRenderContextDestroy(context) }
    let input = PCMList(channels: [Array(repeating: 0.99, count: 512), Array(repeating: 0.2, count: 512), Array(repeating: -0.3, count: 512)])
    let output = PCMList(channels: Array(repeating: Array(repeating: Float(9), count: 512), count: 4))
    render(context, input, output)
    try expect(abs(output.samples(0).last! - 0.2) < 0.0001)
    try expect(abs(output.samples(1).last! + 0.3) < 0.0001)
    try expect(output.samples(2).allSatisfy { $0 == 0 })
    try expect(output.samples(3).allSatisfy { $0 == 0 })
}

func shortOrMissingInputProducesSafeSilence() throws {
    let context = try require(MixerRenderContextCreate(1, 48_000, 0, 2))
    defer { MixerRenderContextDestroy(context) }
    let input = PCMList(channels: [[0.5, 0.5], [0.2, 0.2]])
    let output = PCMList(channels: [Array(repeating: 9, count: 512), Array(repeating: 9, count: 512)])
    render(context, input, output)
    try expect(output.samples(0).dropFirst(2).allSatisfy { $0 == 0 })
    try expect(output.samples(1).dropFirst(2).allSatisfy { $0 == 0 })
    input.list.pointee.mBuffers.mData = nil
    render(context, input, output)
    try expect(output.samples(0).allSatisfy { $0 == 0 })
    try expect(output.samples(1).allSatisfy { $0 == 0 })
}

func realTimeGainCannotAmplifyEvenWithInvalidInput() throws {
    let context = try require(MixerRenderContextCreate(20, 48_000, 0, 2))
    defer { MixerRenderContextDestroy(context) }
    let input = PCMList(channels: [Array(repeating: 0.7, count: 512), Array(repeating: 0.7, count: 512)])
    let output = PCMList(channels: [Array(repeating: 0, count: 512), Array(repeating: 0, count: 512)])
    render(context, input, output)
    try expect(output.samples(0).allSatisfy { $0 >= 0 && $0 <= 0.7 })
    MixerRenderContextSetGain(context, .nan)
    render(context, input, output)
    try expect(abs(output.samples(0).last! - 0.7) < 0.0001)
}

private func device(_ id: AudioObjectID, _ uid: String) -> OutputDevice {
    OutputDevice(id: id, uid: uid, name: uid, sampleRate: 48_000, channels: 2, transport: 0)
}

private func render(_ context: OpaquePointer, _ input: PCMList, _ output: PCMList) {
    var now = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
    _ = MixerRenderAudio(0, &now, input.list, &inputTime, output.list, &outputTime, UnsafeMutableRawPointer(context))
}

private final class PCMList {
    let list: UnsafeMutablePointer<AudioBufferList>
    private let raw: UnsafeMutableRawPointer
    private var allocations: [UnsafeMutablePointer<Float>] = []
    private let lengths: [Int]

    init(channels: [[Float]], channelCounts: [UInt32]? = nil) {
        lengths = channels.map(\.count)
        raw = .allocate(byteCount: MemoryLayout<AudioBufferList>.size + (channels.count - 1) * MemoryLayout<AudioBuffer>.stride,
                        alignment: MemoryLayout<AudioBufferList>.alignment)
        list = raw.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(channels.count)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for (index, samples) in channels.enumerated() {
            let memory = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            memory.initialize(from: samples, count: samples.count)
            allocations.append(memory)
            buffers[index] = AudioBuffer(mNumberChannels: channelCounts?[index] ?? 1,
                                         mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size), mData: memory)
        }
    }
    func samples(_ index: Int) -> [Float] { Array(UnsafeBufferPointer(start: allocations[index], count: lengths[index])) }
    deinit {
        for (index, memory) in allocations.enumerated() { memory.deinitialize(count: lengths[index]); memory.deallocate() }
        raw.deallocate()
    }
}


private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool,
                    file: StaticString = #fileID, line: UInt = #line) throws {
    if try !condition() { throw CheckFailure(description: "Assertion failed: \(file):\(line)") }
}

private func require<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "Missing value: \(file):\(line)") }
    return value
}

@main
private enum MixerChecks {
    @MainActor static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Preference safety and persistence", preferencesClampAndRestoreMutedVolume),
            ("Audio taper preserves saved percentages, mute and gain safety", audioTaperPreservesStoredPercentagesAndMute),
            ("Slider percentages attenuate rendered stereo samples", sliderPercentagesProduceExpectedStereoAttenuation),
            ("Bypass policy", standardPlaybackBypassesProcessing),
            ("Output disconnect/reconnect", disconnectedOutputFallsBackAndReturnsWhenReconnected),
            ("System output follows changes", followingSystemOutputDoesNotPinADevice),
            ("Nested helper identity", helperBundleUsesContainingApplication),
            ("Permission request preserves playback and excludes physical inputs", permissionRequestDoesNotMuteAppsOrOpenPhysicalDevices),
            ("Optional bindings preserve Core Audio property ABI sizes", optionalBindingsKeepNativePropertyBufferSizes),
            ("Native PID and audio stream format reads", nativePropertyReadsPIDAndStreamFormatWithoutOptionalStorage),
            ("Partial Core Audio property reads fail safely", nativePropertyRejectsPartialReads),
            ("Audio errors distinguish permissions from device/format errors", audioFailuresOnlyMentionPermissionsForAPermissionsError),
            ("Stereo attenuation and de-click", renderAttenuatesStereoAndSmoothsGainChanges),
            ("Interleaved stereo and mono output", renderHandlesInterleavedStereoAndMonoOutput),
            ("Physical input isolation and extra outputs", renderSkipsPhysicalInputAndClearsUnusedOutputChannels),
            ("Short and unavailable input buffers", shortOrMissingInputProducesSafeSilence),
            ("Real-time gain safety", realTimeGainCannotAmplifyEvenWithInvalidInput),
            ("Resource CPU weighting, memory accounting and JSON", resourceSummaryUsesElapsedCPUAndPhysicalFootprint),
            ("Resource counters and timestamps reject invalid samples", resourceSummaryRejectsResetCountersAndInvalidTime),
            ("Self-process resource reader", resourceReaderUsesOnlyOwnProcessAndMonotonicCPU),
            ("ICNS decoding selects a small representation", iconThumbnailSelectsSmallICNSRepresentation),
            ("Large and malformed icon inputs", iconThumbnailBoundsLargeImagesAndRejectsInvalidFiles),
            ("Bundle icon metadata and modern system renderer fallback", iconThumbnailResolvesBundleFileAndPreservesModernIconFallback),
            ("Memory peaks correlate with actual panel state", resourcePeakCorrelatesWithPanelState),
            ("Diagnostic UI counters are thread-safe", resourceUITrackerHandlesConcurrentCounters),
            ("Panel background metadata and older report compatibility", resourceBackgroundMetadataPreservesOlderReports),
            ("Older resource reports retain unknown UI state", resourceReportsDecodeOlderSchemaWithoutInventingUIState),
            ("Development diagnostics replace one local file", developmentArchiveWritesOneFileOnlyForProjectBuilds),
            ("Login item reads OS state without automatic registration", loginItemReadsActualStateWithoutRegistering),
            ("Login item registration, approval and removal", loginItemHandlesRegistrationApprovalAndRemoval),
            ("Login item failures preserve actual state", loginItemPropagatesErrorsWithoutInventingEnabledState),
            ("Login item can recover from notFound and verifies registration state", loginItemCanRecoverFromNotFoundWithoutReportingUnconfirmedSuccess),
            ("Menu panel stays within primary display edges", menuPanelStaysWithinPrimaryDisplayEdges),
            ("Menu panel supports negative and vertical display origins", menuPanelSupportsNegativeAndVerticallyArrangedDisplays),
            ("Menu panel fits short and narrow displays", menuPanelFitsShortAndNarrowDisplays),
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
