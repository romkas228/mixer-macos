// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import MixerCore

func iconThumbnailSelectsSmallICNSRepresentation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Put the largest image first, as real ICNS files often do. Distinct colors reveal
    // whether the decoder unnecessarily selected the 1024 px image instead of 64 px.
    var chunks = Data()
    for (tag, size, color) in [("ic10", 1024, CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
                               ("icp5", 32, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                               ("icp6", 64, CGColor(red: 0, green: 1, blue: 0, alpha: 1))] {
        let png = try iconPNG(width: size, height: size, color: color)
        chunks.append(contentsOf: tag.utf8)
        chunks.append(bigEndianLength(png.count + 8))
        chunks.append(png)
    }
    var icns = Data("icns".utf8)
    icns.append(bigEndianLength(chunks.count + 8))
    icns.append(chunks)
    let url = directory.appendingPathComponent("AppIcon.icns")
    try icns.write(to: url)
    guard let image = AppIconThumbnail.decode(url: url), image.width == 64, image.height == 64,
          let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data else { throw IconCheckFailure("ICNS thumbnail size/read failed") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = data.assumingMemoryBound(to: UInt8.self)
    guard pixel[1] > 240, pixel[0] < 15, pixel[2] < 15 else {
        throw IconCheckFailure("The small green ICNS representation was not selected")
    }
}

func iconThumbnailBoundsLargeImagesAndRejectsInvalidFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("icon.png")
    try iconPNG(width: 512, height: 256, color: CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)).write(to: url)
    guard let image = AppIconThumbnail.decode(url: url), image.width == 64, image.height == 32 else {
        throw IconCheckFailure("A large icon was not bounded to 64 px with its aspect ratio")
    }
    try Data("not an image".utf8).write(to: url)
    guard AppIconThumbnail.decode(url: url) == nil else { throw IconCheckFailure("An invalid image was accepted") }
}

func iconThumbnailResolvesBundleFileAndPreservesModernIconFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = directory.appendingPathComponent("Fixture.app")
    let contents = app.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let info: [String: Any] = ["CFBundleIdentifier": "test.mixer.icon", "CFBundlePackageType": "APPL",
                               "CFBundleIconFile": "AppIcon.png", "CFBundleIconName": "AppIcon"]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    try iconPNG(width: 64, height: 64, color: CGColor(gray: 0.5, alpha: 1))
        .write(to: resources.appendingPathComponent("AppIcon.png"))
    guard AppIconThumbnail.load(bundleURL: app)?.width == 64 else {
        throw IconCheckFailure("A bundle icon with a filename extension was not loaded")
    }
    // An asset catalog plus CFBundleIconName must keep AppKit's appearance-aware renderer.
    try Data().write(to: resources.appendingPathComponent("Assets.car"))
    guard AppIconThumbnail.load(bundleURL: app) == nil else {
        throw IconCheckFailure("A modern icon was replaced with its legacy fallback")
    }
}

private func iconPNG(width: Int, height: Int, color: CGColor) throws -> Data {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconCheckFailure("Could not create icon fixture")
    }
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw IconCheckFailure("Could not create fixture pixels") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        throw IconCheckFailure("Could not encode fixture")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconCheckFailure("Could not finish fixture") }
    return data as Data
}

private func bigEndianLength(_ size: Int) -> Data {
    var value = UInt32(size).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private struct IconCheckFailure: Error {
    let description: String
    init(_ description: String) { self.description = description }
}
