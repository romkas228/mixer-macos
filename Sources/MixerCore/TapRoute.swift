// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AudioRealtime
import CoreAudio
import Foundation

struct RouteConfiguration: Equatable {
    let processes: [AudioObjectID]
    let output: OutputDevice
}

// Owned only by AudioBackend's serial queue. The render callback only touches the C context.
final class TapRoute {
    let configuration: RouteConfiguration
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var context: OpaquePointer?
    private var started = false

    init(configuration: RouteConfiguration, gain: Float, name: String) throws {
        self.configuration = configuration
        do { try start(gain: gain, name: name) }
        catch { stop(); throw error }
    }

    func setGain(_ gain: Float) {
        if let context { MixerRenderContextSetGain(context, gain) }
    }

    private func start(gain: Float, name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: configuration.processes)
        description.name = "Mixer — \(name)"
        description.isPrivate = true
        // Original playback resumes whenever the tap is no longer being read, including startup failure.
        description.muteBehavior = .mutedWhenTapped
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "Не вдалося створити аудіомаршрут")

        let tapFormat = try HAL.scalar(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard Self.isFloatPCM(tapFormat), tapFormat.mChannelsPerFrame == 2 else {
            throw HardwareError(operation: "Цей формат звуку поки не підтримується", status: kAudioDeviceUnsupportedFormatError)
        }
        let output = configuration.output
        let physicalInputChannels = try HAL.channels(output.id, scope: kAudioObjectPropertyScopeInput)
        let physicalInputStreams = try HAL.objects(output.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        let tapUID = try HAL.string(tapID, kAudioTapPropertyUID)
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer — \(name)",
            kAudioAggregateDeviceUIDKey: "local.mixer.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality,
            ]],
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Не вдалося підключити аудіовихід")

        let rate: Double = try HAL.scalar(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        let outputStreams = try HAL.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard !outputStreams.isEmpty else {
            throw HardwareError(operation: "Аудіовихід не має доступних потоків", status: kAudioHardwareBadStreamError)
        }
        for stream in outputStreams {
            let format = try HAL.scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            guard Self.isFloatPCM(format), abs(format.mSampleRate - rate) < 1 else {
                throw HardwareError(operation: "Цей формат аудіовиходу поки не підтримується", status: kAudioDeviceUnsupportedFormatError)
            }
        }
        let inputStreams = try HAL.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        guard inputStreams.count > physicalInputStreams else {
            throw HardwareError(operation: "Аудіопотік програми недоступний", status: kAudioHardwareBadStreamError)
        }
        for stream in inputStreams.dropFirst(physicalInputStreams) {
            var format = try HAL.scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            // Keep capture and output on one HAL clock; never use independent render/capture queues.
            if abs(format.mSampleRate - rate) >= 1 {
                format.mSampleRate = rate
                var address = HAL.address(kAudioStreamPropertyVirtualFormat)
                try HAL.check(AudioObjectSetPropertyData(stream, &address, 0, nil,
                                                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format),
                              "Не вдалося узгодити частоту аудіо")
                format = try HAL.scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            }
            guard Self.isFloatPCM(format), abs(format.mSampleRate - rate) < 1 else {
                throw HardwareError(operation: "Частоти аудіопотоків несумісні", status: kAudioDeviceUnsupportedFormatError)
            }
        }

        guard let context = MixerRenderContextCreate(gain, rate, physicalInputChannels, output.channels) else {
            throw HardwareError(operation: "Не вдалося підготувати обробку звуку", status: kAudioHardwareUnspecifiedError)
        }
        self.context = context
        try HAL.check(MixerCreateIOProc(aggregateID, context, &ioProc), "Не вдалося підготувати аудіопотік")
        guard let ioProc else {
            throw HardwareError(operation: "Аудіопотік не створено", status: kAudioHardwareUnspecifiedError)
        }
        try HAL.check(MixerConfigureInputStreams(aggregateID, ioProc, UInt32(physicalInputStreams)), "Не вдалося ізолювати звук програми")
        try HAL.check(AudioDeviceStart(aggregateID, ioProc), "Не вдалося запустити аудіопотік")
        started = true
    }

    private static func isFloatPCM(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM && f.mBitsPerChannel == 32
        && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        && f.mFormatFlags & kAudioFormatFlagIsPacked != 0
    }

    func stop() {
        // Stop/destroy the callback before releasing any memory it can access.
        if let ioProc {
            if started { AudioDeviceStop(aggregateID, ioProc) }
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        started = false
        ioProc = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        if let context { MixerRenderContextDestroy(context) }
        context = nil
    }

    deinit { stop() }
}
