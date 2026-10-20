// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AudioRealtime
import Foundation
import MixerCore

@main
private enum IconLoadingBenchmark {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count >= 3,
              ["workspace", "cached", "panel", "panel-opaque"].contains(CommandLine.arguments[1]) else {
            fputs("Usage: benchmark-icons.sh workspace|cached|panel|panel-opaque app-path [app-path ...]\n", stderr)
            exit(2)
        }
        let mode = CommandLine.arguments[1]
        let isPanel = mode == "panel" || mode == "panel-opaque"
        let background: ResourcePanelBackground = mode == "panel-opaque" ? .opaqueDiagnostic : .nativeMaterial
        let apps = CommandLine.arguments.dropFirst(2).enumerated().map { index, path in
            AudioApp(id: "benchmark.\(index)", name: "Icon \(index)", bundleURL: URL(fileURLWithPath: path),
                     processIDs: [], isActive: false, isSystemSound: false)
        }
        let cache = AppIconCache()
        let appearance = NSAppearance(named: .aqua)!
        if isPanel { NSApplication.shared.setActivationPolicy(.prohibited) }
        var start = MixerProcessMetrics()
        guard MixerReadOwnProcessMetrics(&start) == 0 else { exit(1) }
        let started = DispatchTime.now().uptimeNanoseconds
        var pixelWidths: [Int] = []
        let openings = 20
        for _ in 0..<openings {
            // Each legacy opening gets its own event-style pool, just like a real UI event.
            // The new mode uses the actual production cache with the same native appearance.
            autoreleasepool {
                appearance.performAsCurrentDrawingAppearance {
                    if isPanel {
                        var snapshot = MixerSnapshot()
                        snapshot.apps = apps.map { AppSnapshot(app: $0, preference: AppPreference(volume: 0.5),
                                                              state: .processing, outputUnavailable: false) }
                        let content = MixerPanel(iconCache: cache)
                        content.update(snapshot)
                        let window = MenuBarPanel(content: content, size: content.panelSize, background: background)
                        guard window.panelBackground == background,
                              (window.contentView is NSVisualEffectView) == (background == .nativeMaterial) else {
                            fputs("The control panel did not use the requested background\n", stderr)
                            exit(1)
                        }
                        window.contentView?.layoutSubtreeIfNeeded()
                        if let view = window.contentView,
                           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                        }
                        // Never order the test window on screen or alter the active application.
                        window.dismiss()
                    }
                    let icons = apps.map { app in
                        mode != "workspace" ? cache.icon(for: app, appearance: appearance) : legacyIcon(app.bundleURL!)
                    }
                    pixelWidths = icons.flatMap(\.representations).map(\.pixelsWide)
                    withExtendedLifetime(icons) {}
                }
            }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        var end = MixerProcessMetrics()
        guard MixerReadOwnProcessMetrics(&end) == 0 else { exit(1) }
        let report: [String: Any] = [
            "scope": isPanel
                ? "Offscreen AppKit panel creation/rendering with fixture snapshots; no WindowServer backdrop, user-process profiling or real audio routes"
                : "Isolated icon loading across simulated panel openings; no actual Mixer panel, audio routes or user-process profiling",
            "mode": mode, "iconCountPerOpening": apps.count, "openings": openings,
            "startFootprintBytes": start.footprintBytes, "endFootprintBytes": end.footprintBytes,
            "lifetimePeakFootprintBytes": MixerBenchmarkPeakFootprint(), "durationSeconds": seconds,
            "maxRetainedPixelWidth": pixelWidths.max() ?? 0,
        ]
        withExtendedLifetime(cache) {
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    @MainActor private static func legacyIcon(_ url: URL) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 32, height: 32)
        let icon = NSImage(size: bitmap.size)
        icon.addRepresentation(bitmap)
        return icon
    }
}
