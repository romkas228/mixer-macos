// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AudioRealtime
import CoreAudio

package enum ProcessIdentity {
    struct Identity {
        let id: String
        let name: String
        let bundleURL: URL?
        let isSystemSound: Bool
    }

    static func resolve(pid: pid_t, audioBundleID: String) -> Identity {
        var current = pid
        for _ in 0..<8 where current > 1 {
            if let running = NSRunningApplication(processIdentifier: current),
               let url = running.bundleURL, let root = outermostApp(url),
               let bundle = Bundle(url: root), let bundleID = bundle.bundleIdentifier {
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? running.localizedName ?? root.deletingPathExtension().lastPathComponent
                return Identity(id: bundleID, name: name, bundleURL: root, isSystemSound: false)
            }
            let parent = MixerParentPID(current)
            if parent == current { break }
            current = parent
        }
        let running = NSRunningApplication(processIdentifier: pid)
        let id = audioBundleID.isEmpty ? "process.\(pid)" : audioBundleID
        let processName = running?.localizedName
        let bundleName = audioBundleID.split(separator: ".").last.map(String.init)
        let isSystemSound = bundleName == "systemsoundserverd" || processName == "systemsoundserverd"
        return Identity(id: id, name: isSystemSound ? "Системний звук" : processName ?? bundleName ?? "Процес \(pid)",
                        bundleURL: running?.bundleURL, isSystemSound: isSystemSound)
    }

    package static func outermostApp(_ url: URL) -> URL? {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if current.pathExtension == "app" { return current }
        }
        return nil
    }
}
