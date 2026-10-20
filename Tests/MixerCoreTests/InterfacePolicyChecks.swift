// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MixerCore

@MainActor
private final class FakeLoginService: LaunchAtLoginService {
    var status: LaunchAtLoginStatus = .notRegistered
    var registrations = 0
    var unregistrations = 0
    var registrationNeedsApproval = false
    var registrationLeavesStatusUnchanged = false
    var fails = false

    func register() throws {
        registrations += 1
        if fails { throw PolicyCheckError.expectedFailure }
        if registrationLeavesStatusUnchanged { return }
        status = registrationNeedsApproval ? .requiresApproval : .enabled
        if registrationNeedsApproval { throw PolicyCheckError.expectedFailure }
    }
    func unregister() async throws {
        unregistrations += 1
        if fails { throw PolicyCheckError.expectedFailure }
        status = .notRegistered
    }
}

@MainActor
func loginItemReadsActualStateWithoutRegistering() throws {
    let service = FakeLoginService()
    let controller = LaunchAtLogin(service: service)
    try policyExpect(controller.status == .notRegistered)
    try policyExpect(service.registrations == 0 && service.unregistrations == 0)
    // Simulate changes made in System Settings; no cached Boolean may override them.
    service.status = .enabled
    try policyExpect(controller.status == .enabled)
    service.status = .requiresApproval
    try policyExpect(controller.status == .requiresApproval && controller.status.isRegistered)
    service.status = .notRegistered
    try policyExpect(!controller.status.isRegistered)
}

@MainActor
func loginItemHandlesRegistrationApprovalAndRemoval() async throws {
    let service = FakeLoginService()
    let controller = LaunchAtLogin(service: service)
    try await controller.setEnabled(true)
    try policyExpect(controller.status == .enabled && service.registrations == 1)
    try await controller.setEnabled(true)
    try policyExpect(service.registrations == 1)
    try await controller.setEnabled(false)
    try policyExpect(controller.status == .notRegistered && service.unregistrations == 1)
    try await controller.setEnabled(false)
    try policyExpect(service.unregistrations == 1)

    service.registrationNeedsApproval = true
    try await controller.setEnabled(true)
    try policyExpect(controller.status == .requiresApproval && service.registrations == 2)
    try await controller.setEnabled(true)
    try policyExpect(service.registrations == 2)
    try await controller.setEnabled(false)
    try policyExpect(controller.status == .notRegistered && service.unregistrations == 2)
}

@MainActor
func loginItemPropagatesErrorsWithoutInventingEnabledState() async throws {
    let service = FakeLoginService()
    let controller = LaunchAtLogin(service: service)
    service.fails = true
    do { try await controller.setEnabled(true); throw PolicyCheckError.unexpectedSuccess }
    catch PolicyCheckError.expectedFailure { }
    try policyExpect(controller.status == .notRegistered)
    service.status = .enabled
    do { try await controller.setEnabled(false); throw PolicyCheckError.unexpectedSuccess }
    catch PolicyCheckError.expectedFailure { }
    try policyExpect(controller.status == .enabled)
    service.status = .notFound
    let previousCalls = service.registrations + service.unregistrations
    do { try await controller.setEnabled(true); throw PolicyCheckError.unexpectedSuccess }
    catch PolicyCheckError.expectedFailure { }
    try policyExpect(service.registrations + service.unregistrations == previousCalls + 1)
    try policyExpect(controller.status == .notFound)
}

@MainActor
func loginItemCanRecoverFromNotFoundWithoutReportingUnconfirmedSuccess() async throws {
    let service = FakeLoginService()
    service.status = .notFound
    let controller = LaunchAtLogin(service: service)
    try await controller.setEnabled(true)
    try policyExpect(service.registrations == 1 && controller.status == .enabled)
    try await controller.setEnabled(false)
    try policyExpect(service.unregistrations == 1 && controller.status == .notRegistered)

    // register() returning without an error must not fabricate an enabled state.
    service.status = .notFound
    service.registrationLeavesStatusUnchanged = true
    do { try await controller.setEnabled(true); throw PolicyCheckError.unexpectedSuccess }
    catch PolicyCheckError.unexpectedSuccess { throw PolicyCheckError.unexpectedSuccess }
    catch { }
    try policyExpect(service.registrations == 2 && controller.status == .notFound)
}

func menuPanelStaysWithinPrimaryDisplayEdges() throws {
    let visible = CGRect(x: 0, y: 24, width: 1440, height: 850)
    for x in [CGFloat(0), 700, 1418] {
        let anchor = CGRect(x: x, y: visible.maxY, width: 22, height: 24)
        let frame = MenuPanelGeometry.frame(requestedSize: CGSize(width: 360, height: 528), anchor: anchor, visibleFrame: visible)
        try policyExpect(visible.insetBy(dx: 8, dy: 8).contains(frame))
        try policyExpect(frame.width == 360 && frame.height == 528)
        try policyExpect(frame.maxY <= anchor.minY - 6)
    }
}

func menuPanelSupportsNegativeAndVerticallyArrangedDisplays() throws {
    let screens = [CGRect(x: -1920, y: 24, width: 1920, height: 1032),
                   CGRect(x: 300, y: -1440, width: 2560, height: 1416),
                   CGRect(x: 0, y: 1080, width: 1440, height: 876),
                   CGRect(x: 1920, y: 200, width: 1280, height: 696)]
    for visible in screens {
        let anchor = CGRect(x: visible.maxX - 40, y: visible.maxY, width: 22, height: 24)
        let frame = MenuPanelGeometry.frame(requestedSize: CGSize(width: 360, height: 528), anchor: anchor, visibleFrame: visible)
        try policyExpect(visible.insetBy(dx: 8, dy: 8).contains(frame))
        try policyExpect(frame.width == 360 && frame.height == 528)
        try policyExpect(frame.minX == visible.maxX - 8 - frame.width)
    }
}

func menuPanelFitsShortAndNarrowDisplays() throws {
    let visible = CGRect(x: -500, y: -200, width: 300, height: 260)
    let anchor = CGRect(x: -490, y: visible.maxY, width: 22, height: 24)
    let frame = MenuPanelGeometry.frame(requestedSize: CGSize(width: 360, height: 528), anchor: anchor, visibleFrame: visible)
    try policyExpect(visible.insetBy(dx: 8, dy: 8).contains(frame))
    try policyExpect(frame.width == 284 && frame.height == 244)
    try policyExpect(frame.minX == visible.minX + 8 && frame.minY == visible.minY + 8)
}

private enum PolicyCheckError: Error { case expectedFailure, unexpectedSuccess, failedAssertion }
private func policyExpect(_ condition: Bool) throws {
    if !condition { throw PolicyCheckError.failedAssertion }
}
