// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import MixerCore
import ServiceManagement
import Synchronization

@main
enum MixerApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnostics") {
            do { print(try AudioDiagnostics.json()) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--profile-resources") {
            let argument = CommandLine.arguments.dropFirst(index + 1).first
            let duration = argument.flatMap(Double.init) ?? (argument == nil ? 30 : .nan)
            guard duration.isFinite, (5...120).contains(duration) else {
                fputs("Вкажи тривалість від 5 до 120 секунд.\n", stderr); exit(2)
            }
            // No menu, onboarding, capture routes or changes to the user's preferences.
            let backend = AudioBackend(defaults: nil) { _ in }
            let result = Mutex<Result<ResourceReport, Error>?>(nil)
            let finished = DispatchSemaphore(value: 0)
            backend.start()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                backend.measureResources(duration: duration, mode: .headlessBypass) { report in
                    result.withLock { $0 = report }
                    finished.signal()
                }
            }
            finished.wait()
            backend.stop()
            do {
                guard let report = result.withLock({ $0 }) else { exit(1) }
                let data = try report.get().jsonData()
                print(String(decoding: data, as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuBarPanel?
    private var panel: MixerPanel?
    private let uiTracker = ResourceUITracker()
    private lazy var iconCache = AppIconCache(uiTracker: uiTracker)
    private var snapshot = MixerSnapshot()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isRequestingAudioAccess = false
    private let launchAtLogin = LaunchAtLogin()
    private var isChangingLaunchAtLogin = false
    // This tracks onboarding only. It is never treated as the OS authorization status.
    private static let didRequestAudioAccessKey = "didRequestSystemAudioAccess.v1"
    private lazy var backend = AudioBackend(uiTracker: uiTracker) { [weak self] snapshot in
        Task { @MainActor [weak self] in self?.receive(snapshot) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Мікшер звуку")
            button.image?.isTemplate = true
            button.toolTip = "Mixer — гучність програм"
            button.target = self
            button.action = #selector(togglePanel(_:))
            // Toggle on mouse-down, before focus-loss/click-away handlers can close the panel.
            // Do not handle the matching mouse-up, which would toggle it a second time.
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Завершити Mixer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.backend.sleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.backend.wake() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            Task { @MainActor [weak self] in self?.backend.retry() }
        })
        backend.start()
        if !UserDefaults.standard.bool(forKey: Self.didRequestAudioAccessKey) {
            // Also runs once for existing installations upgrading from the initial prototype.
            DispatchQueue.main.async { [weak self] in self?.requestAudioAccess() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuPanel?.dismiss()
        backend.stop()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func receive(_ snapshot: MixerSnapshot) {
        self.snapshot = snapshot
        // Do not create icons, rows, or layout work while the panel is closed.
        if menuPanel?.isVisible == true { updatePanel() }
    }

    private func updatePanel() {
        guard let panel else { return }
        panel.update(snapshot)
        menuPanel?.resize(to: panel.panelSize)
        if menuPanel?.isVisible == true { recordPanelState() }
    }

    private func recordPanelState() {
        guard let menuPanel, menuPanel.isVisible else { uiTracker.setPanel(phase: .hidden); return }
        uiTracker.setPanel(phase: .visible, width: menuPanel.frame.width, height: menuPanel.frame.height,
                           backingScaleFactor: menuPanel.backingScaleFactor, background: menuPanel.panelBackground)
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let event = NSApp.currentEvent {
            menuPanel?.dismiss()
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: sender)
            return
        }
        if menuPanel?.isVisible == true { menuPanel?.dismiss(); return }
        uiTracker.setPanel(phase: .preparing, background: .nativeMaterial)
        if panel == nil {
            let panel = MixerPanel(iconCache: iconCache)
            panel.onPreference = { [weak self] id, preference in self?.backend.setPreference(preference, for: id) }
            panel.onMenu = { [weak self] button in
                self?.makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            }
            // Resolve row heights before attaching the content to a window. The initial
            // window then gets the actual snapshot size rather than a placeholder size.
            panel.update(snapshot)
            self.panel = panel
            let menuPanel = MenuBarPanel(content: panel, size: panel.panelSize)
            menuPanel.initialFirstResponder = panel.initialKeyboardView
            menuPanel.onDismiss = { [weak self] in
                // Release views and monitors; keep only the bounded small-icon cache.
                self?.panel = nil
                self?.menuPanel = nil
                self?.uiTracker.setPanel(phase: .hidden)
            }
            self.menuPanel = menuPanel
        } else {
            updatePanel()
        }
        menuPanel?.show(relativeTo: sender)
        recordPanelState()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let about = menu.addItem(withTitle: "Про Mixer", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(.separator())
        let launchStatus = launchAtLogin.status
        let launch = menu.addItem(withTitle: "Запускати разом із macOS", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        switch launchStatus {
        case .enabled: launch.state = .on
        case .requiresApproval:
            launch.state = .mixed
            launch.toolTip = "Автозапуск зареєстровано; потрібен дозвіл у системних параметрах."
            let approve = menu.addItem(withTitle: "Дозволити автозапуск…", action: #selector(openLoginItemSettings), keyEquivalent: "")
            approve.target = self
        case .notRegistered: launch.state = .off
        case .notFound:
            launch.state = .off
            launch.toolTip = "Натисни, щоб спробувати ввімкнути автозапуск Mixer."
        }
        menu.addItem(.separator())
        let retry = menu.addItem(withTitle: "Оновити та повторити підключення", action: #selector(retryAudio), keyEquivalent: "")
        retry.target = self
        let permissions = menu.addItem(withTitle: "Доступ до системного звуку…", action: #selector(openAudioAccessDialog), keyEquivalent: "")
        permissions.target = self
        permissions.isEnabled = !isRequestingAudioAccess
        let reset = menu.addItem(withTitle: "Скинути налаштування звуку", action: #selector(resetAudio), keyEquivalent: "")
        reset.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершити Mixer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func retryAudio() { backend.retry() }
    @objc private func resetAudio() { backend.reset() }

    @objc private func toggleLaunchAtLogin() {
        guard !isChangingLaunchAtLogin else { return }
        let enable = !launchAtLogin.status.isRegistered
        isChangingLaunchAtLogin = true
        menuPanel?.dismiss()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isChangingLaunchAtLogin = false }
            do {
                try await self.launchAtLogin.setEnabled(enable)
                if enable && self.launchAtLogin.status == .requiresApproval {
                    let alert = NSAlert()
                    alert.messageText = "Дозволь запуск Mixer разом із macOS"
                    alert.informativeText = "У системних параметрах відкрий «Об’єкти входу» та дозволь автозапуск Mixer."
                    alert.addButton(withTitle: "Відкрити системні параметри")
                    alert.addButton(withTitle: "Пізніше")
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn { self.openLoginItemSettings() }
                }
            } catch {
                let systemError = error as NSError
                NSLog("Mixer: login item change failed (%@/%ld): %@", systemError.domain, systemError.code, systemError.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "Не вдалося змінити автозапуск"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Готово")
                alert.addButton(withTitle: "Відкрити системні параметри")
                NSApp.activate()
                if alert.runModal() == .alertSecondButtonReturn { self.openLoginItemSettings() }
            }
        }
    }

    @objc private func openLoginItemSettings() {
        menuPanel?.dismiss()
        SMAppService.openSystemSettingsLoginItems()
    }

    private func requestAudioAccess() {
        guard !isRequestingAudioAccess else { return }
        isRequestingAudioAccess = true
        UserDefaults.standard.set(true, forKey: Self.didRequestAudioAccessKey)
        menuPanel?.dismiss()
        NSApp.activate()
        SystemAudioAccess.request { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRequestingAudioAccess = false
                self.backend.retry()
                if case .failure = result { self.showAudioAccessHelp(requestFailed: true) }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin) {
            return !isChangingLaunchAtLogin
        }
        return menuItem.action != #selector(openAudioAccessDialog) || !isRequestingAudioAccess
    }

    @objc private func openAudioAccessDialog() { showAudioAccessHelp(requestFailed: false) }

    private func showAudioAccessHelp(requestFailed: Bool) {
        menuPanel?.dismiss()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Доступ до системного звуку"
        let introduction = requestFailed
            ? "Не вдалося відкрити системний запит. "
            : "Щоб змінювати гучність і вихід програм, Mixer потрібен доступ до системного звуку. "
        alert.informativeText = introduction
            + "Натисни «Запросити доступ» і дозволь його у вікні macOS.\n\n"
            + "Якщо ти вже відхилив запит, відкрий системні параметри й увімкни Mixer у нижньому розділі «Тільки записування системного звуку». Потім повернися до Mixer; якщо macOS попросить — перезапусти застосунок.\n\n"
            + "Звук обробляється лише на цьому Mac, без запису у файли та передавання."
        if requestFailed {
            alert.addButton(withTitle: "Відкрити системні параметри")
            alert.addButton(withTitle: "Пізніше")
            if alert.runModal() == .alertFirstButtonReturn { openPermissions() }
        } else {
            alert.addButton(withTitle: "Запросити доступ")
            alert.addButton(withTitle: "Відкрити системні параметри")
            alert.addButton(withTitle: "Пізніше")
            switch alert.runModal() {
            case .alertFirstButtonReturn: requestAudioAccess()
            case .alertSecondButtonReturn: openPermissions()
            default: break
            }
        }
    }

    private func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func showAbout() {
        menuPanel?.dismiss()
        NSApp.activate()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Mixer",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.18",
            .credits: NSAttributedString(string: "Нативний мікшер звуку для macOS."),
        ]
        // Load only when About is opened, and bypass a stale system placeholder icon cache.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            options[.applicationIcon] = image
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
