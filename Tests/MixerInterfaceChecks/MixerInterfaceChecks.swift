// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import MixerCore

/// Only hidden, in-process fixtures. Never starts audio, registers login items,
/// posts events to macOS, changes user preferences, or activates a window.
@main
private enum MixerInterfaceChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let checks: [(String, @MainActor () throws -> Void)] = [
            ("Nonactivating panel and explicit keyboard loop", panelAndKeyboardLoop),
            ("Keyboard volume steps, limits and unmute", keyboardVolume),
            ("Focus survives disabled outputs and removed rows", dynamicFocus),
            ("Short viewport keeps all rows reachable by keyboard", shortViewport),
            ("Empty mixer retains keyboard access to settings", emptyMixer),
        ]
        var failures = 0
        for (name, check) in checks {
            do { try check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) interface checks passed")
        if failures > 0 { exit(1) }
    }

    @MainActor private static func panelAndKeyboardLoop() throws {
        let content = MixerPanel(iconCache: AppIconCache())
        content.update(snapshot(count: 2))
        let window = MenuBarPanel(content: content, size: content.panelSize)
        defer { window.dismiss() }
        try check(!window.isVisible && window.styleMask.contains(.nonactivatingPanel))
        try check(window.canBecomeKey && !window.canBecomeMain)
        let first = content.initialKeyboardView
        let views = try keyboardLoop(startingAt: first)
        try check(views.count == 7 && first is NSSlider)
        try check(window.makeFirstResponder(first))
        window.selectNextKeyView(nil)
        try check(window.firstResponder === first.nextKeyView)
        window.selectPreviousKeyView(nil)
        try check(window.firstResponder === first)
    }

    @MainActor private static func keyboardVolume() throws {
        let content = MixerPanel(iconCache: AppIconCache())
        content.update(snapshot(count: 1, muted: true))
        let window = MenuBarPanel(content: content, size: content.panelSize)
        defer { window.dismiss() }
        let slider = try require(content.initialKeyboardView as? NSSlider)
        var received: AppPreference?
        content.onPreference = { _, preference in received = preference }
        // Call only this fixture's handler; these events are never sent to the OS.
        slider.keyDown(with: try key(124))
        try check(abs(slider.doubleValue - 0.51) < 0.00001)
        try check(received?.muted == false && abs((received?.volume ?? 0) - 0.51) < 0.00001)
        slider.keyDown(with: try key(123, modifiers: .shift))
        try check(abs(slider.doubleValue - 0.41) < 0.00001)
        slider.keyDown(with: try key(115))
        slider.keyDown(with: try key(123))
        try check(slider.doubleValue == 0 && received?.volume == 0)
        slider.keyDown(with: try key(119))
        slider.keyDown(with: try key(124))
        try check(slider.doubleValue == 1 && received?.volume == 1)
    }

    @MainActor private static func dynamicFocus() throws {
        let content = MixerPanel(iconCache: AppIconCache())
        content.update(snapshot(count: 2))
        let window = MenuBarPanel(content: content, size: content.panelSize)
        defer { window.dismiss() }
        let views = try keyboardLoop(startingAt: content.initialKeyboardView)
        let output = try require(views.first { $0 is NSPopUpButton })
        try check(window.makeFirstResponder(output))
        content.update(snapshot(count: 2, devices: false))
        try check(try keyboardLoop(startingAt: content.initialKeyboardView).count == 5)
        try check(window.firstResponder === content.initialKeyboardView)

        let oldSlider = content.initialKeyboardView
        try check(window.makeFirstResponder(oldSlider))
        content.update(snapshot(count: 1, firstID: 1))
        try check(content.initialKeyboardView !== oldSlider)
        try check(window.firstResponder === content.initialKeyboardView)
        try check(try keyboardLoop(startingAt: content.initialKeyboardView).count == 4)
    }

    @MainActor private static func shortViewport() throws {
        let content = MixerPanel(iconCache: AppIconCache())
        content.update(snapshot(count: 10))
        let window = MenuBarPanel(content: content, size: content.panelSize)
        defer { window.dismiss() }
        window.setPanelFrame(NSRect(x: 0, y: 0, width: 360, height: 260))
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try require(descendants(content).compactMap { $0 as? NSScrollView }.first)
        let document = try require(scroll.documentView)
        if scroll.contentSize.height <= 0 || scroll.contentSize.height >= 440 {
            print("Layout: window=\(window.frame), content=\(content.frame), scroll=\(scroll.frame), viewport=\(scroll.contentSize), document=\(document.frame)")
        }
        try check(scroll.contentSize.height > 0 && scroll.contentSize.height < 440)
        try check(document.frame.height >= 1060)
        let lastSlider = try require(descendants(content).compactMap { $0 as? NSSlider }.last)
        try check(window.makeFirstResponder(lastSlider))
        let target = lastSlider.convert(lastSlider.bounds, to: document)
        try check(scroll.contentView.bounds.contains(target))
    }

    @MainActor private static func emptyMixer() throws {
        let content = MixerPanel(iconCache: AppIconCache())
        content.update(snapshot(count: 0))
        let window = MenuBarPanel(content: content, size: content.panelSize)
        defer { window.dismiss() }
        try check(content.initialKeyboardView is NSButton)
        try check(try keyboardLoop(startingAt: content.initialKeyboardView).count == 1)
        try check(window.makeFirstResponder(content.initialKeyboardView))
    }

    private static func snapshot(count: Int, devices: Bool = true, muted: Bool = false, firstID: Int = 0) -> MixerSnapshot {
        var snapshot = MixerSnapshot()
        snapshot.devices = devices ? [OutputDevice(id: 1, uid: "test-output", name: "Test output", sampleRate: 48_000, channels: 2, transport: 0)] : []
        snapshot.defaultOutputUID = devices ? "test-output" : nil
        snapshot.apps = (firstID..<(firstID + count)).map { index in
            AppSnapshot(app: AudioApp(id: "test.\(index)", name: "Test \(index)", bundleURL: nil,
                                      processIDs: [], isActive: true, isSystemSound: false),
                        preference: AppPreference(volume: 0.5, muted: muted), state: .processing, outputUnavailable: false)
        }
        return snapshot
    }

    @MainActor private static func keyboardLoop(startingAt first: NSView) throws -> [NSView] {
        var result = [first]
        var next = first.nextKeyView
        while let view = next, view !== first {
            try check(result.count < 100 && !result.contains { $0 === view })
            result.append(view)
            next = view.nextKeyView
        }
        try check(next === first)
        return result
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private static func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: code))
    }
    private static func check(_ condition: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
        if !condition { throw Failure(description: "Assertion failed: \(file):\(line)") }
    }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(description: "Missing fixture value") }
        return value
    }
    private struct Failure: Error, CustomStringConvertible { let description: String }
}
