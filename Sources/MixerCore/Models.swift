// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import CoreAudio

public struct AppPreference: Codable, Equatable, Sendable {
    public var volume: Double
    public var muted: Bool
    public var outputUID: String?

    public init(volume: Double = 1, muted: Bool = false, outputUID: String? = nil) {
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1
        self.muted = muted
        self.outputUID = outputUID
    }

    public var gain: Float {
        guard !muted else { return 0 }
        let level = volume.isFinite ? min(1, max(0, volume)) : 1
        // Audio taper: 50% is -12 dB, instead of the old linear-amplitude -6 dB.
        // Keep the slider/persisted percentage unchanged; compute outside the audio callback.
        return Float(level * level)
    }
    public var needsProcessing: Bool { gain < 1 || outputUID != nil }
    public var isDefault: Bool { !needsProcessing }

    // Preferences are untrusted input; also sanitize values read from older builds.
    private enum CodingKeys: String, CodingKey { case volume, muted, outputUID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
                  muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                  outputUID: try c.decodeIfPresent(String.self, forKey: .outputUID))
    }
}

public struct OutputDevice: Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let channels: UInt32
    public let transport: UInt32

    package init(id: AudioObjectID, uid: String, name: String, sampleRate: Double, channels: UInt32, transport: UInt32) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.channels = channels
        self.transport = transport
    }
}

public struct AudioApp: Sendable {
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let processIDs: [AudioObjectID]
    public let isActive: Bool
    package let isSystemSound: Bool

    package init(id: String, name: String, bundleURL: URL?, processIDs: [AudioObjectID],
                 isActive: Bool, isSystemSound: Bool) {
        self.id = id
        self.name = name
        self.bundleURL = bundleURL
        self.processIDs = processIDs
        self.isActive = isActive
        self.isSystemSound = isSystemSound
    }
}

public struct RouteFailure: Equatable, Sendable {
    public let message: String
    public let details: String

    package init(message: String, details: String? = nil) {
        self.message = message
        self.details = details ?? message
    }

    package init(error: Error) {
        details = error.localizedDescription
        if let hardware = error as? HardwareError {
            message = hardware.status == kAudioDevicePermissionsError
                ? "macOS не надала доступ до системного звуку. Перевір дозвіл для Mixer."
                : hardware.operation
        } else if error is NativeAudioProperty.ReadError {
            message = "Не вдалося прочитати дані аудіопристрою. Повтори підключення в меню ⚙︎."
        } else {
            message = error.localizedDescription
        }
    }
}

public enum RouteState: Equatable, Sendable {
    case bypassed
    case processing
    case waiting
    case failed(RouteFailure)
}

public struct AppSnapshot: Sendable {
    public let app: AudioApp
    public let preference: AppPreference
    public let state: RouteState
    public let outputUnavailable: Bool

    package init(app: AudioApp, preference: AppPreference, state: RouteState, outputUnavailable: Bool) {
        self.app = app
        self.preference = preference
        self.state = state
        self.outputUnavailable = outputUnavailable
    }
}

public struct MixerSnapshot: Sendable {
    public var apps: [AppSnapshot] = []
    public var devices: [OutputDevice] = []
    public var defaultOutputUID: String?
    public var issue: String?
    public init() {}
}

public enum RoutingPolicy {
    public static func output(for preference: AppPreference, devices: [OutputDevice],
                              defaultUID: String?) -> OutputDevice? {
        if let uid = preference.outputUID, let pinned = devices.first(where: { $0.uid == uid }) {
            return pinned
        }
        return devices.first(where: { $0.uid == defaultUID })
    }
}
