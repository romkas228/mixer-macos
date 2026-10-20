// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import MixerCore

/// A transient menu-bar panel that takes keyboard input without activating Mixer.
/// The nonactivating style must be set at initialization, not patched onto a popover window.
@MainActor
final class MenuBarPanel: NSPanel, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    private weak var anchor: NSStatusBarButton?
    private weak var mixerContent: MixerPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0
    private var isDismissing = false
    private var requestedSize: NSSize
    let panelBackground: ResourcePanelBackground = .nativeMaterial

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(content: NSView, size: NSSize) {
        requestedSize = size
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        mixerContent = content as? MixerPanel
        // Keep the WindowServer device deferred until show(), after the final size and
        // screen position are known. Building a hidden panel needs no intermediate backing.
        title = "Mixer — Мікшер звуку"
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        autorecalculatesKeyViewLoop = false
        delegate = self

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        // A menu stays visually active while its owning app remains in the background.
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard button.window != nil else { return }
        anchor = button
        button.highlight(true)
        position(size: requestedSize)
        installDismissalHandlers()
        // NSPanel's nonactivating style preserves the frontmost app and its main window.
        // Becoming key here makes controls ready on the first click and supports keyboard navigation.
        makeKeyAndOrderFront(nil)
        if let initialFirstResponder { makeFirstResponder(initialFirstResponder) }
    }

    func resize(to size: NSSize) {
        guard requestedSize != size else { return }
        requestedSize = size
        if anchor == nil { setContentSize(size); return }
        position(size: size)
    }

    private func position(size: NSSize) {
        guard let anchor, let anchorWindow = anchor.window else { return }
        let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let center = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? anchorWindow.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let frame = MenuPanelGeometry.frame(requestedSize: size, anchor: anchorRect, visibleFrame: available)
        setPanelFrame(frame)
    }

    func setPanelFrame(_ frame: NSRect) {
        mixerContent?.constrainContentHeight(to: frame.height)
        setFrame(frame, display: isVisible)
        // A deferred, hidden NSPanel can retain the old content size until first display.
        // Keep the borderless content and its scroll viewport in sync before ordering front.
        contentView?.setFrameSize(frame.size)
        contentView?.layoutSubtreeIfNeeded()
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        removeDismissalHandlers()
        // Closing a nonactivating key panel returns key input to the previous app automatically.
        close()
        contentView = nil
        anchor?.highlight(false)
        anchor = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func selectNextKeyView(_ sender: Any?) {
        if let mixerContent { mixerContent.moveKeyboardFocus(backwards: false) }
        else { super.selectNextKeyView(sender) }
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        if let mixerContent { mixerContent.moveKeyboardFocus(backwards: true) }
        else { super.selectPreviousKeyView(sender) }
    }

    private var isMouseOverAnchor: Bool {
        guard let anchor, let window = anchor.window else { return false }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Native pop-up menus temporarily take key focus. Allow their tracking notifications
        // to arrive before deciding that focus has moved somewhere else.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isDismissing, self.menuTrackingDepth == 0 else { return }
            // A click on the menu-bar button belongs to its toggle action, not click-away.
            if NSEvent.pressedMouseButtons != 0 && self.isMouseOverAnchor { return }
            if !self.isKeyWindow { self.dismiss() }
        }
    }

    private func installDismissalHandlers() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // AppKit invokes event monitor handlers on the main thread.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isMouseOverAnchor else { return }
                // macOS may report a status-item click through the global monitor as well.
                self.dismiss()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [mouseEvents, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, !self.isDismissing else { return false }
                if event.type == .keyDown {
                    guard event.window === self, self.menuTrackingDepth == 0 else { return false }
                    // Let Escape close a native dropdown first, then the panel on the next press.
                    if event.keyCode == 53 {
                        self.dismiss()
                        return true
                    }
                    if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                        if event.modifierFlags.contains(.shift) { self.selectPreviousKeyView(nil) }
                        else { self.selectNextKeyView(nil) }
                        return true
                    }
                    return false
                }
                // The status button handles its own toggle. Closing here would reopen the panel.
                if self.isMouseOverAnchor { return false }
                if event.window !== self && self.menuTrackingDepth == 0 { self.dismiss() }
                return false
            }
            return consumed ? nil : event
        }

        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
        })
        appObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
            }
        })
        appObservers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        if let anchorWindow = anchor?.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                appObservers.append(center.addObserver(forName: name, object: anchorWindow, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isDismissing else { return }
                        self.position(size: self.requestedSize)
                    }
                })
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }

    private func removeDismissalHandlers() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.removeAll()
        workspaceObservers.removeAll()
        menuTrackingDepth = 0
    }
}
