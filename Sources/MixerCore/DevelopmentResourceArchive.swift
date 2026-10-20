// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

package enum DevelopmentResourceArchive {
    package static func directory(appBundleURL: URL) -> URL? {
        guard appBundleURL.isFileURL, appBundleURL.pathExtension == "app" else { return nil }
        let build = appBundleURL.deletingLastPathComponent()
        let project = build.deletingLastPathComponent()
        guard build.lastPathComponent == "build",
              FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path) else {
            return nil
        }
        return build.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Only local project builds get an automatic copy, and only after an explicit measurement.
    /// One file is replaced, so diagnostic runs do not accumulate an unbounded archive.
    package static func save(_ report: ResourceReport, appBundleURL: URL) throws -> URL? {
        guard let directory = directory(appBundleURL: appBundleURL) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("latest-resources.json")
        try report.jsonData().write(to: url, options: .atomic)
        return url
    }
}
