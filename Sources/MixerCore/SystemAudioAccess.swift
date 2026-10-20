// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AudioRealtime
import CoreAudio
import Foundation

public enum SystemAudioAccess {
    /// Requests system-audio access through the public Core Audio capture path.
    /// Success means the request path ran, not that the user granted permission.
    public static func request(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Result { try performRequest() })
        }
    }

    package static func tapDescription() -> CATapDescription {
        // No source app needs to be playing. An unmuted tap leaves ordinary playback alone.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Mixer — доступ до системного звуку"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    package static func aggregateDescription(tapUID: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Mixer — запит доступу",
            kAudioAggregateDeviceUIDKey: "local.mixer.aggregate.permission.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            // Input-only. Do not open physical output or microphone devices.
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
    }

    private static func performRequest() throws {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProc: AudioDeviceIOProcID?
        var started = false
        defer {
            if let ioProc {
                if started { AudioDeviceStop(aggregateID, ioProc) }
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
            if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        }
        try HAL.check(AudioHardwareCreateProcessTap(tapDescription(), &tapID), "Не вдалося підготувати запит доступу до звуку")
        let tapUID = try HAL.string(tapID, kAudioTapPropertyUID)
        try HAL.check(AudioHardwareCreateAggregateDevice(aggregateDescription(tapUID: tapUID) as CFDictionary, &aggregateID),
                      "Не вдалося підготувати запит доступу до звуку")
        try HAL.check(MixerCreatePermissionIOProc(aggregateID, &ioProc), "Не вдалося підготувати запит доступу до звуку")
        guard let ioProc else {
            throw HardwareError(operation: "Не вдалося підготувати запит доступу до звуку", status: kAudioHardwareUnspecifiedError)
        }
        // Apple triggers the system-audio consent prompt on the first start of a tap input.
        // Always release this temporary input after the call, including denial/failure.
        try HAL.check(AudioDeviceStart(aggregateID, ioProc), "Не вдалося відкрити системний запит доступу до звуку")
        started = true
    }
}
