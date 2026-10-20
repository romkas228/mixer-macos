// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation

// Mutable state is confined to queue. C atomics are the only bridge into the audio callback.
public final class AudioBackend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.mixer.audio-control", qos: .userInitiated)
    private let deliver: @Sendable (MixerSnapshot) -> Void
    private let defaults: UserDefaults?
    private let uiTracker: ResourceUITracker?
    private var preferences: [String: AppPreference] = [:]
    private var routes: [String: TapRoute] = [:]
    private var failures: [String: (RouteConfiguration, RouteFailure)] = [:]
    private var systemObservations: [HardwareObservation] = []
    private var processObservations: [AudioObjectID: [HardwareObservation]] = [:]
    private var deviceObservations: [AudioObjectID: [HardwareObservation]] = [:]
    private var identities: [pid_t: ProcessIdentity.Identity] = [:]
    private var seenApps: Set<String> = []
    private var refreshWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var isStopped = false
    private var isSleeping = false
    private var lastSnapshot = MixerSnapshot()
    private var resourceMeasurement: ResourceMeasurement?
    private var hardwareRefreshCount: UInt64 = 0
    private var routeStartCount: UInt64 = 0
    private static let preferencesKey = "appPreferences.v1"

    public init(defaults: UserDefaults? = .standard, uiTracker: ResourceUITracker? = nil,
                deliver: @escaping @Sendable (MixerSnapshot) -> Void) {
        self.defaults = defaults
        self.deliver = deliver
        self.uiTracker = uiTracker
    }

    public func start() {
        queue.async { [self] in
            if let data = defaults?.data(forKey: Self.preferencesKey),
               let stored = try? JSONDecoder().decode([String: AppPreference].self, from: data) {
                preferences = stored
            }
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioHardwarePropertyProcessObjectList] {
                if let observation = try? HardwareObservation(HAL.system, selector, queue: queue, changed: { [weak self] in
                    self?.scheduleRefresh()
                }) { systemObservations.append(observation) }
            }
            refreshNow()
        }
    }

    public func setPreference(_ preference: AppPreference, for appID: String) {
        queue.async { [self] in
            guard !isStopped else { return }
            preferences[appID] = AppPreference(volume: preference.volume, muted: preference.muted, outputUID: preference.outputUID)
            failures.removeValue(forKey: appID)
            scheduleSave()
            // Gain changes reuse the route and only store an atomic Float for the audio thread.
            reconcile(apps: lastSnapshot.apps.map(\.app), devices: lastSnapshot.devices,
                      defaultUID: lastSnapshot.defaultOutputUID)
        }
    }

    public func reset() {
        queue.async { [self] in
            preferences.removeAll()
            failures.removeAll()
            routes.removeAll()
            saveNow()
            refreshNow()
        }
    }

    public func retry() {
        queue.async { [self] in
            failures.removeAll()
            refreshNow()
        }
    }

    public func sleep() {
        queue.async { [self] in
            isSleeping = true
            routes.removeAll()
        }
    }

    public func wake() {
        queue.async { [self] in
            isSleeping = false
            failures.removeAll()
            identities.removeAll()
            refreshNow()
        }
    }

    public func stop() {
        queue.sync {
            isStopped = true
            resourceMeasurement?.cancel()
            resourceMeasurement = nil
            refreshWork?.cancel()
            saveWork?.cancel()
            routes.removeAll()
            processObservations.removeAll()
            deviceObservations.removeAll()
            systemObservations.removeAll()
            saveNow()
        }
    }

    public func measureResources(duration: TimeInterval = 30, mode: ResourceProfileMode = .menuBarApp,
                                 completion: @escaping @Sendable (Result<ResourceReport, Error>) -> Void) {
        queue.async { [self] in
            guard !isStopped, !isSleeping else { completion(.failure(ResourceMeasurementError.unavailable)); return }
            guard resourceMeasurement == nil else { completion(.failure(ResourceMeasurementError.alreadyRunning)); return }
            let measurement = ResourceMeasurement(queue: queue, duration: duration, mode: mode, activity: { [self] in
                AudioResourceActivity(visibleAppCount: lastSnapshot.apps.count,
                                      activeAppCount: lastSnapshot.apps.filter { $0.app.isActive }.count,
                                      activeRouteCount: routes.count, outputDeviceCount: lastSnapshot.devices.count,
                                      hardwareRefreshCount: hardwareRefreshCount, routeStartCount: routeStartCount)
            }, uiState: { [uiTracker] in uiTracker?.snapshot() }, completion: { [weak self] result in
                self?.resourceMeasurement = nil
                completion(result)
            })
            resourceMeasurement = measurement
            measurement.start()
        }
    }

    private func scheduleRefresh() {
        guard !isStopped, !isSleeping else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshNow() }
        refreshWork = work
        // Coalesce bursts caused by device connection and aggregate-device creation.
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func refreshNow() {
        guard !isStopped, !isSleeping else { return }
        hardwareRefreshCount &+= 1
        do {
            let devices = try HAL.outputs()
            let defaultID: AudioObjectID = (try? HAL.scalar(HAL.system, kAudioHardwarePropertyDefaultOutputDevice,
                                                         initial: AudioObjectID(kAudioObjectUnknown))) ?? 0
            let defaultUID = devices.first(where: { $0.id == defaultID })?.uid
            let processObjects = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList)
            updateObservations(processes: processObjects, devices: devices)
            let apps = discoverApps(processObjects)
            reconcile(apps: apps, devices: devices, defaultUID: defaultUID)
        } catch {
            // An unreadable process/device list must never leave an obsolete route running.
            routes.removeAll()
            lastSnapshot.apps = lastSnapshot.apps.map {
                AppSnapshot(app: $0.app, preference: $0.preference,
                            state: .failed(RouteFailure(error: error)), outputUnavailable: $0.outputUnavailable)
            }
            lastSnapshot.issue = error.localizedDescription
            deliver(lastSnapshot)
        }
    }

    private func discoverApps(_ objects: [AudioObjectID]) -> [AudioApp] {
        var groups: [String: AudioApp] = [:]
        var currentPIDs: Set<pid_t> = []
        for object in objects {
            guard let pid: pid_t = try? HAL.scalar(object, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            currentPIDs.insert(pid)
            let identity: ProcessIdentity.Identity
            if let cached = identities[pid] { identity = cached }
            else {
                identity = ProcessIdentity.resolve(pid: pid, audioBundleID: (try? HAL.string(object, kAudioProcessPropertyBundleID)) ?? "")
                identities[pid] = identity
            }
            let isActive: UInt32 = (try? HAL.scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            let previous = groups[identity.id]
            groups[identity.id] = AudioApp(id: identity.id, name: identity.name, bundleURL: identity.bundleURL,
                                          processIDs: (previous?.processIDs ?? []) + [object],
                                          isActive: isActive != 0 || previous?.isActive == true,
                                          isSystemSound: identity.isSystemSound)
        }
        identities = identities.filter { currentPIDs.contains($0.key) }
        return groups.values.filter {
            if $0.isActive { seenApps.insert($0.id) }
            return $0.isActive || seenApps.contains($0.id) || preferences[$0.id]?.needsProcessing == true
        }.map {
            AudioApp(id: $0.id, name: $0.name, bundleURL: $0.bundleURL,
                     processIDs: $0.processIDs.sorted(), isActive: $0.isActive, isSystemSound: $0.isSystemSound)
        }.sorted {
            if $0.isSystemSound != $1.isSystemSound { return $0.isSystemSound }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func reconcile(apps: [AudioApp], devices: [OutputDevice], defaultUID: String?) {
        guard !isStopped, !isSleeping else { return }
        let existing = Set(apps.map(\.id))
        for id in Array(routes.keys) where !existing.contains(id) { routes.removeValue(forKey: id) }
        failures = failures.filter { existing.contains($0.key) }
        var snapshots: [AppSnapshot] = []
        for app in apps {
            let preference = preferences[app.id] ?? AppPreference()
            let output = RoutingPolicy.output(for: preference, devices: devices, defaultUID: defaultUID)
            let unavailable = preference.outputUID.map { uid in !devices.contains(where: { $0.uid == uid }) } ?? false
            let state: RouteState
            if !preference.needsProcessing || !app.isActive {
                routes.removeValue(forKey: app.id)
                failures.removeValue(forKey: app.id)
                state = preference.needsProcessing ? .waiting : .bypassed
            } else if let output {
                let configuration = RouteConfiguration(processes: app.processIDs, output: output)
                if routes[app.id]?.configuration != configuration { routes.removeValue(forKey: app.id) }
                if let route = routes[app.id] {
                    route.setGain(preference.gain)
                    state = .processing
                } else if let failure = failures[app.id], failure.0 == configuration {
                    state = .failed(failure.1)
                } else {
                    do {
                        routes[app.id] = try TapRoute(configuration: configuration, gain: preference.gain, name: app.name)
                        routeStartCount &+= 1
                        failures.removeValue(forKey: app.id)
                        state = .processing
                    } catch {
                        let failure = RouteFailure(error: error)
                        failures[app.id] = (configuration, failure)
                        state = .failed(failure)
                    }
                }
            } else {
                routes.removeValue(forKey: app.id)
                state = .failed(RouteFailure(message: "Немає доступного аудіовиходу. Під’єднай навушники або динаміки."))
            }
            snapshots.append(AppSnapshot(app: app, preference: preference, state: state, outputUnavailable: unavailable))
        }
        lastSnapshot = MixerSnapshot()
        lastSnapshot.apps = snapshots
        lastSnapshot.devices = devices
        lastSnapshot.defaultOutputUID = defaultUID
        deliver(lastSnapshot)
    }

    private func updateObservations(processes: [AudioObjectID], devices: [OutputDevice]) {
        let processSet = Set(processes)
        for id in Array(processObservations.keys) where !processSet.contains(id) { processObservations.removeValue(forKey: id) }
        for id in processes where processObservations[id] == nil {
            processObservations[id] = [
                (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
                (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
            ].compactMap { selector, scope in
                try? HardwareObservation(id, selector, scope: scope, queue: queue, changed: { [weak self] in self?.scheduleRefresh() })
            }
        }
        let deviceSet = Set(devices.map(\.id))
        for id in Array(deviceObservations.keys) where !deviceSet.contains(id) { deviceObservations.removeValue(forKey: id) }
        for device in devices where deviceObservations[device.id] == nil {
            deviceObservations[device.id] = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive,
                                           kAudioDevicePropertyStreamConfiguration].compactMap { selector in
                let scope = selector == kAudioDevicePropertyStreamConfiguration
                    ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal
                return try? HardwareObservation(device.id, selector, scope: scope, queue: queue,
                                                changed: { [weak self] in self?.scheduleRefresh() })
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func saveNow() {
        guard let defaults else { return }
        let stored = preferences.filter { !$0.value.isDefault && !$0.key.hasPrefix("process.") }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.preferencesKey) }
    }
}
