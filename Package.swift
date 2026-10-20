// swift-tools-version: 6.2
// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
    name: "Mixer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Mixer", targets: ["Mixer"])],
    targets: [
        .target(name: "AudioRealtime", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "MixerCore", dependencies: ["AudioRealtime"]),
        .executableTarget(name: "Mixer", dependencies: ["MixerCore"]),
        .executableTarget(name: "MixerChecks", dependencies: ["MixerCore", "AudioRealtime"], path: "Tests/MixerCoreTests"),
    ]
)
