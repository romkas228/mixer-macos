// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation

public enum AudioDiagnostics {
    // Read-only: no taps, playback, permissions prompt, or preferences access.
    public static func json() throws -> String {
        let outputs = try HAL.outputs()
        let objects = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList)
        let active = objects.filter {
            let value: UInt32 = (try? HAL.scalar($0, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return value != 0
        }
        let report: [String: Any] = [
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "audioProcessCount": objects.count,
            "activeOutputProcessCount": active.count,
            "outputs": outputs.map { ["name": $0.name, "sampleRate": $0.sampleRate, "channels": $0.channels] as [String: Any] },
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
