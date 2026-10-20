// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Synchronization

public enum ResourcePanelPhase: String, Codable, Sendable {
    case hidden, preparing, visible

    public var localizedDescription: String {
        switch self {
        case .hidden: "закрите"
        case .preparing: "створюється"
        case .visible: "відкрите"
        }
    }
}

public enum ResourcePanelBackground: String, Codable, Sendable {
    case nativeMaterial, opaqueDiagnostic

    public var localizedDescription: String {
        switch self {
        case .nativeMaterial: "системна прозорість"
        case .opaqueDiagnostic: "без прозорості (діагностика)"
        }
    }
}

public struct ResourceUIState: Codable, Sendable {
    public fileprivate(set) var panelPhase: ResourcePanelPhase = .hidden
    // Optional so reports recorded before this control experiment remain decodable.
    public fileprivate(set) var panelBackground: ResourcePanelBackground? = nil
    public fileprivate(set) var panelOpenCount: UInt64 = 0
    public fileprivate(set) var panelWidth: Double = 0
    public fileprivate(set) var panelHeight: Double = 0
    public fileprivate(set) var backingScaleFactor: Double = 0
    public fileprivate(set) var iconRenderCount: UInt64 = 0
    public fileprivate(set) var iconCacheHitCount: UInt64 = 0
}

/// Updated only on UI events; read once per diagnostic sample, never on the audio thread.
public final class ResourceUITracker: Sendable {
    private let state = Mutex(ResourceUIState())

    public init() {}

    public func setPanel(phase: ResourcePanelPhase, width: Double = 0, height: Double = 0,
                         backingScaleFactor: Double = 0, background: ResourcePanelBackground? = nil) {
        state.withLock {
            if phase == .preparing && $0.panelPhase == .hidden { $0.panelOpenCount &+= 1 }
            $0.panelPhase = phase
            $0.panelBackground = phase == .hidden ? nil : background
            $0.panelWidth = width
            $0.panelHeight = height
            $0.backingScaleFactor = backingScaleFactor
        }
    }

    public func recordIcon(cacheHit: Bool) {
        state.withLock {
            if cacheHit { $0.iconCacheHitCount &+= 1 }
            else { $0.iconRenderCount &+= 1 }
        }
    }

    public func snapshot() -> ResourceUIState { state.withLock { $0 } }
}
