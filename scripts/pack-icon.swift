// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

// Package already-rendered PNGs as an ICNS IconFamilyResource.
// This does not redraw or modify pixels; IconStorage.h defines the big-endian container layout.
guard CommandLine.arguments.count == 3 else {
    print("Usage: pack-icon.swift <iconset-directory> <output.icns>")
    exit(1)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let entries: [(type: String, name: String, pixels: UInt32)] = [
    ("icp4", "icon_16x16.png", 16),
    ("icp5", "icon_32x32.png", 32),
    ("icp6", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128),
    ("ic08", "icon_256x256.png", 256),
    ("ic09", "icon_512x512.png", 512),
    ("ic10", "icon_512x512@2x.png", 1024),
    ("ic11", "icon_16x16@2x.png", 32),
    ("ic12", "icon_32x32@2x.png", 64),
    ("ic13", "icon_128x128@2x.png", 256),
    ("ic14", "icon_256x256@2x.png", 512),
]

func bigEndian(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

func uint32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

do {
    var elements = Data()
    for entry in entries {
        let png = try Data(contentsOf: directory.appendingPathComponent(entry.name))
        guard png.count >= 26,
              png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              uint32(png, at: 16) == entry.pixels,
              uint32(png, at: 20) == entry.pixels,
              png[25] == 6 else {
            throw NSError(domain: "MixerIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid RGBA icon image: \(entry.name)"])
        }
        elements.append(Data(entry.type.utf8))
        elements.append(bigEndian(UInt32(png.count + 8)))
        elements.append(png)
    }
    var icon = Data("icns".utf8)
    icon.append(bigEndian(UInt32(elements.count + 8)))
    icon.append(elements)
    try icon.write(to: destination, options: .atomic)
} catch {
    print("Icon packaging failed: \(error.localizedDescription)")
    exit(1)
}
