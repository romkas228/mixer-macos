// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ImageIO

/// Reads a bounded icon representation without asking Icon Services to render all sizes.
package enum AppIconThumbnail {
    package static let pixelSize = 64

    package static func load(bundleURL: URL) -> CGImage? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        // CFBundleIconFile may be a legacy fallback for a modern, appearance-aware icon.
        // Leave those to AppKit so the optimization does not replace the system design.
        if bundle.object(forInfoDictionaryKey: "CFBundleIconName") != nil,
           let assets = bundle.resourceURL?.appendingPathComponent("Assets.car"),
           FileManager.default.fileExists(atPath: assets.path) { return nil }
        let names = ["CFBundleIconFile", "CFBundleIconName"].compactMap {
            bundle.object(forInfoDictionaryKey: $0) as? String
        }
        for name in names where !name.isEmpty {
            let file = name as NSString
            let url = file.pathExtension.isEmpty
                ? bundle.url(forResource: name, withExtension: "icns")
                : bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension)
            if let url, let image = decode(url: url) { return image }
        }
        // Asset-catalog/Composer icons remain the system icon loader's responsibility.
        return nil
    }

    package static func decode(url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var selectedIndex = 0
        var selectedSize: Int?
        // ICNS often includes a 1024 px image first. Prefer the smallest representation
        // that meets the 64 px requirement, or the largest one if all are smaller.
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, sourceOptions) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { continue }
            let size = max(width, height)
            let shouldSelect: Bool
            if let previous = selectedSize {
                shouldSelect = previous < pixelSize
                    ? size > previous
                    : size >= pixelSize && size < previous
            } else { shouldSelect = true }
            if shouldSelect { selectedIndex = index; selectedSize = size }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, selectedIndex, options as CFDictionary)
    }
}
