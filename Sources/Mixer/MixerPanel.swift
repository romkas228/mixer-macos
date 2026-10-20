// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import MixerCore

@MainActor
final class MixerPanel: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onPreference: ((String, AppPreference) -> Void)?
    var onMenu: ((NSButton) -> Void)?
    private let subtitle = NSTextField(labelWithString: "")
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let list = FlippedStackView()
    private let empty = NSStackView()
    private let gear = KeyboardButton()
    private var keyboardViews: [NSView] = []
    private var rows: [String: AppRow] = [:]
    private var orderedIDs: [String] = []
    private let iconCache: AppIconCache
    private var listHeight: NSLayoutConstraint!
    private var scrollHeight: NSLayoutConstraint!
    private var emptyHeight: NSLayoutConstraint!
    private var maximumHeight: CGFloat?
    var panelSize = NSSize(width: 360, height: 260)
    var initialKeyboardView: NSView { orderedIDs.first.flatMap { rows[$0]?.initialKeyboardView } ?? gear }

    func constrainContentHeight(to height: CGFloat) {
        maximumHeight = height
        updateViewportHeight()
    }

    private func updateViewportHeight() {
        let bodyHeight = max(0, (maximumHeight ?? panelSize.height) - 88 - (issue.isHidden ? 0 : 44))
        scrollHeight.constant = min(440, listHeight.constant, bodyHeight)
        emptyHeight.constant = min(160, bodyHeight)
    }

    func moveKeyboardFocus(backwards: Bool) {
        guard let window else { return }
        guard let current = keyboardViews.firstIndex(where: { $0 === window.firstResponder }) else {
            window.makeFirstResponder(initialKeyboardView)
            return
        }
        let direction = backwards ? -1 : 1
        for distance in 1...keyboardViews.count {
            let index = (current + direction * distance + keyboardViews.count) % keyboardViews.count
            let view = keyboardViews[index]
            guard !view.isHiddenOrHasHiddenAncestor else { continue }
            if let control = view as? NSControl, !control.isEnabled { continue }
            if window.makeFirstResponder(view) { return }
        }
    }

    init(iconCache: AppIconCache) {
        self.iconCache = iconCache
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "Мікшер")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Налаштування")!
        gear.target = self
        gear.action = #selector(showMenu(_:))
        gear.bezelStyle = .accessoryBarAction
        gear.isBordered = false
        gear.focusRingType = .exterior
        gear.toolTip = "Налаштування Mixer"
        let header = NSStackView(views: [title, NSView(), gear])
        header.alignment = .centerY
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        issue.font = .systemFont(ofSize: 11)
        issue.textColor = .systemOrange
        issue.isHidden = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        listHeight = list.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        // Let the viewport shrink on short displays; the document retains its full height.
        scrollHeight.priority = NSLayoutConstraint.Priority(749)

        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 10
        let icon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let emptyTitle = NSTextField(labelWithString: "Поки немає аудіопрограм")
        emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let emptyDetail = NSTextField(wrappingLabelWithString: "Увімкни музику або відео — програма з’явиться тут.")
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        empty.addArrangedSubview(icon)
        empty.addArrangedSubview(emptyTitle)
        empty.addArrangedSubview(emptyDetail)
        emptyHeight = empty.heightAnchor.constraint(equalToConstant: 160)

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [header, subtitle, issue, separator, scroll, empty])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            issue.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            // Only the scroll view reaches the panel edges; its rows keep their own padding.
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            emptyHeight,
            emptyDetail.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -20),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listHeight, scrollHeight,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: MixerSnapshot) {
        let previousFocus = window?.firstResponder as? NSView
        let ownedFocus = previousFocus?.isDescendant(of: self) == true
        let output = snapshot.devices.first { $0.uid == snapshot.defaultOutputUID }
        subtitle.stringValue = "Системний вихід: \(output?.name ?? "не під’єднано")"
        subtitle.toolTip = subtitle.stringValue
        issue.stringValue = snapshot.issue ?? ""
        issue.isHidden = snapshot.issue == nil
        let ids = snapshot.apps.map { $0.app.id }
        if ids != orderedIDs {
            for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
            rows = rows.filter { ids.contains($0.key) }
            for item in snapshot.apps {
                let row = rows[item.app.id] ?? AppRow()
                row.onPreference = { [weak self] preference in self?.onPreference?(item.app.id, preference) }
                rows[item.app.id] = row
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -32).isActive = true
            }
            orderedIDs = ids
        }
        var height: CGFloat = 0
        for item in snapshot.apps {
            guard let row = rows[item.app.id] else { continue }
            row.update(item, devices: snapshot.devices, icon: iconCache.icon(for: item.app, appearance: effectiveAppearance))
            height += row.rowHeight
        }
        let emptyList = snapshot.apps.isEmpty
        empty.isHidden = !emptyList
        scroll.isHidden = emptyList
        listHeight.constant = height
        panelSize = NSSize(width: 360, height: 88 + (emptyList ? 160 : min(440, height)) + (snapshot.issue == nil ? 0 : 44))
        updateViewportHeight()
        rebuildKeyboardLoop(previousFocus: ownedFocus ? previousFocus : nil)
    }

    private func rebuildKeyboardLoop(previousFocus: NSView?) {
        let views = [gear as NSView] + orderedIDs.flatMap { rows[$0]?.keyboardViews ?? [] }
        if views.map(ObjectIdentifier.init) != keyboardViews.map(ObjectIdentifier.init) {
            keyboardViews.forEach { $0.nextKeyView = nil }
            for (index, view) in views.enumerated() { view.nextKeyView = views[(index + 1) % views.count] }
            keyboardViews = views
        }
        window?.initialFirstResponder = initialKeyboardView
        if let previousFocus, !views.contains(where: { $0 === previousFocus }) {
            window?.makeFirstResponder(initialKeyboardView)
        }
    }

    @objc private func showMenu(_ sender: NSButton) { onMenu?(sender) }
}

@MainActor
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TrackingSlider: NSSlider {
    var isTracking = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        let step = event.modifierFlags.contains(.shift) ? 0.10 : 0.01
        let value: Double
        switch event.keyCode {
        case 123, 125: value = doubleValue - step
        case 124, 126: value = doubleValue + step
        case 115: value = minValue
        case 119: value = maxValue
        default: super.keyDown(with: event); return
        }
        doubleValue = min(maxValue, max(minValue, value))
        sendAction(action, to: target)
    }
    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event)
        isTracking = false
    }
}

@MainActor
private final class KeyboardButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds) }
        return accepted
    }
}

@MainActor
private final class KeyboardPopUpButton: NSPopUpButton {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds) }
        return accepted
    }
}

@MainActor
private final class AppRow: NSView {
    var onPreference: ((AppPreference) -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let percentage = NSTextField(labelWithString: "100%")
    private let mute = KeyboardButton()
    private let slider = TrackingSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let output = KeyboardPopUpButton(frame: .zero, pullsDown: false)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var preference = AppPreference()
    private var height: NSLayoutConstraint!
    private var outputSignature: [String] = []
    private var appName = ""
    var rowHeight: CGFloat = 106
    var initialKeyboardView: NSView { slider }
    var keyboardViews: [NSView] { [mute, slider] + (output.isEnabled ? [output] : []) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        percentage.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentage.textColor = .secondaryLabelColor
        percentage.alignment = .right
        mute.isBordered = false
        mute.setButtonType(.pushOnPushOff)
        mute.bezelStyle = .accessoryBarAction
        mute.focusRingType = .exterior
        mute.target = self
        mute.action = #selector(toggleMute)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changeVolume)
        output.controlSize = .small
        output.font = .systemFont(ofSize: 11)
        output.target = self
        output.action = #selector(changeOutput)
        message.font = .systemFont(ofSize: 10)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2
        message.isHidden = true
        let divider = NSBox()
        divider.boxType = .separator
        for view in [icon, title, percentage, mute, slider, output, message, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        height = heightAnchor.constraint(equalToConstant: rowHeight)
        NSLayoutConstraint.activate([
            height,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: percentage.leadingAnchor, constant: -8),
            percentage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            percentage.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            percentage.widthAnchor.constraint(equalToConstant: 38),
            mute.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: -3),
            mute.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            mute.widthAnchor.constraint(equalToConstant: 24),
            mute.heightAnchor.constraint(equalToConstant: 22),
            slider.leadingAnchor.constraint(equalTo: mute.trailingAnchor, constant: 5),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.centerYAnchor.constraint(equalTo: mute.centerYAnchor),
            output.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: -3),
            output.trailingAnchor.constraint(equalTo: trailingAnchor),
            output.topAnchor.constraint(equalTo: mute.bottomAnchor, constant: 4),
            message.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: trailingAnchor),
            message.topAnchor.constraint(equalTo: output.bottomAnchor, constant: 3),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: AppSnapshot, devices: [OutputDevice], icon image: NSImage) {
        if !slider.isTracking { preference = snapshot.preference; slider.doubleValue = preference.volume }
        icon.image = image
        icon.contentTintColor = snapshot.app.isSystemSound ? .labelColor : nil
        title.stringValue = snapshot.app.name
        appName = snapshot.app.name
        title.toolTip = snapshot.app.name
        slider.setAccessibilityLabel("Гучність: \(snapshot.app.name)")
        output.setAccessibilityLabel("Аудіовихід: \(snapshot.app.name)")
        updateVolumeAppearance()
        let signature = devices.map { "\($0.uid)|\($0.name)" } + [preference.outputUID ?? ""]
        if signature != outputSignature {
            output.removeAllItems()
            output.addItem(withTitle: "Системний вихід")
            for device in devices {
                output.addItem(withTitle: device.name)
                output.lastItem?.representedObject = device.uid
            }
            if let uid = preference.outputUID, !devices.contains(where: { $0.uid == uid }) {
                output.addItem(withTitle: "Вихід від’єднано")
                output.lastItem?.representedObject = uid
            }
            outputSignature = signature
        }
        if let uid = preference.outputUID,
           let item = output.itemArray.first(where: { $0.representedObject as? String == uid }) { output.select(item) }
        else { output.selectItem(at: 0) }
        output.isEnabled = !devices.isEmpty
        let text: String
        message.toolTip = nil
        switch snapshot.state {
        case .failed(let failure):
            text = failure.message
            message.toolTip = failure.details
        case .waiting: text = snapshot.outputUnavailable ? "Вихід від’єднано; використаємо системний." : ""
        default: text = snapshot.outputUnavailable ? "Вихід від’єднано; використовується системний." : ""
        }
        message.stringValue = text
        if message.toolTip == nil && !text.isEmpty { message.toolTip = text }
        message.isHidden = text.isEmpty
        if case .failed = snapshot.state { message.textColor = .systemOrange }
        else { message.textColor = .secondaryLabelColor }
        rowHeight = text.isEmpty ? 106 : 134
        height.constant = rowHeight
    }

    private func updateVolumeAppearance() {
        percentage.stringValue = preference.muted ? "Вимк." : "\(Int((preference.volume * 100).rounded()))%"
        let symbol = preference.muted || preference.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        mute.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        mute.contentTintColor = preference.muted ? .secondaryLabelColor : .labelColor
        mute.toolTip = preference.muted ? "Увімкнути звук" : "Вимкнути звук"
        slider.alphaValue = preference.muted ? 0.45 : 1
        mute.state = preference.muted ? .on : .off
        mute.setAccessibilityLabel("\(preference.muted ? "Увімкнути" : "Вимкнути") звук: \(appName)")
        let value = "\(Int((preference.volume * 100).rounded()))%"
        slider.setAccessibilityValueDescription(preference.muted ? "Звук вимкнено; \(value)" : value)
    }

    @objc private func changeVolume() {
        preference.volume = slider.doubleValue
        preference.muted = false
        updateVolumeAppearance()
        onPreference?(preference)
    }
    @objc private func toggleMute() {
        preference.muted.toggle()
        updateVolumeAppearance()
        onPreference?(preference)
    }
    @objc private func changeOutput() {
        preference.outputUID = output.selectedItem?.representedObject as? String
        onPreference?(preference)
    }
}
