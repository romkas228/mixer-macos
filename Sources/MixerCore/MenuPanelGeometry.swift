// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Screen coordinates may have negative origins or be above/below the primary display.
public enum MenuPanelGeometry {
    public static func frame(requestedSize: CGSize, anchor: CGRect, visibleFrame: CGRect) -> CGRect {
        let margin = min(CGFloat(8), max(0, min(visibleFrame.width, visibleFrame.height) / 2))
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let top = min(max(anchor.minY - 6, bounds.minY), bounds.maxY)
        let width = min(max(0, requestedSize.width), bounds.width)
        // Fit below the menu-bar button, including on small or vertically arranged screens.
        let height = min(max(0, requestedSize.height), top - bounds.minY)
        let x = min(max(anchor.midX - width / 2, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
