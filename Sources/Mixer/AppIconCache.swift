// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import MixerCore

/// Keeps small, appearance-specific rasters across panel openings, never source images.
@MainActor
final class AppIconCache {
    private let images = NSCache<NSString, NSImage>()
    private let uiTracker: ResourceUITracker?

    init(uiTracker: ResourceUITracker? = nil) {
        self.uiTracker = uiTracker
        images.countLimit = 32
        images.totalCostLimit = 512 * 1024
    }

    func icon(for app: AudioApp, appearance: NSAppearance) -> NSImage {
        let key = "\(app.id)|\(appearance.name.rawValue)" as NSString
        if let cached = images.object(forKey: key) {
            uiTracker?.recordIcon(cacheHit: true)
            return cached
        }
        uiTracker?.recordIcon(cacheHit: false)
        var result: NSImage?
        // Drain temporary AppKit/Icon Services objects after each icon, not after all rows.
        autoreleasepool {
            appearance.performAsCurrentDrawingAppearance {
                result = makeIcon(for: app)
            }
        }
        let icon = result ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        let cost = icon.representations.compactMap { $0 as? NSBitmapImageRep }
            .reduce(0) { $0 + $1.bytesPerRow * $1.pixelsHigh }
        images.setObject(icon, forKey: key, cost: cost)
        return icon
    }

    private func makeIcon(for app: AudioApp) -> NSImage? {
        if app.isSystemSound {
            let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Системний звук")?
                .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            symbol?.isTemplate = true
            return symbol
        }
        if let url = app.bundleURL, let thumbnail = AppIconThumbnail.load(bundleURL: url) {
            let bitmap = NSBitmapImageRep(cgImage: thumbnail)
            let scale = 32 / CGFloat(max(thumbnail.width, thumbnail.height))
            bitmap.size = NSSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
            let icon = NSImage(size: bitmap.size)
            icon.addRepresentation(bitmap)
            return icon
        }
        // Preserve system rendering for asset-catalog/Composer icons and unknown bundles.
        let source = app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
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
