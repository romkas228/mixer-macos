// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound

    /// Pending approval is still a registration the user can turn off.
    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
package protocol LaunchAtLoginService: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() async throws
}

/// Reads the OS state on demand. No polling, cached preference, or automatic registration.
@MainActor
public final class LaunchAtLogin {
    private let service: any LaunchAtLoginService

    public init() { service = SystemLoginItemService() }
    package init(service: any LaunchAtLoginService) { self.service = service }

    public var status: LaunchAtLoginStatus { service.status }

    public func setEnabled(_ enabled: Bool) async throws {
        let current = service.status
        if enabled {
            guard !current.isRegistered else { return }
            // A failed status lookup must not prevent a user-initiated registration attempt.
            // register() provides the actionable OS error if registration is unavailable.
            do { try service.register() }
            catch {
                // Registration may succeed but execution require approval in System Settings.
                guard service.status == .requiresApproval else { throw error }
            }
            guard service.status.isRegistered else { throw ServiceError.registrationUnconfirmed }
        } else if current.isRegistered {
            try await service.unregister()
        }
    }

    private enum ServiceError: LocalizedError {
        case registrationUnconfirmed
        var errorDescription: String? {
            "macOS не підтвердила реєстрацію Mixer. Перевір «Об’єкти входу» в системних параметрах."
        }
    }
}

@MainActor
private final class SystemLoginItemService: LaunchAtLoginService {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}
