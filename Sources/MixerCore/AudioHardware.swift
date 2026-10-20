// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation

package struct HardwareError: LocalizedError {
    package let operation: String
    package let status: OSStatus
    package init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }
    package var errorDescription: String? { "\(operation) (Core Audio: \(status))." }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw HardwareError(operation: operation, status: status) }
    }

    static func scalar<T: NativeAudioPropertyValue>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          initial: T) throws -> T {
        var address = address(selector, scope: scope)
        return try NativeAudioProperty.read(initial: initial) { data, size in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, data),
                      "Не вдалося прочитати властивість аудіо")
        }
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Не вдалося отримати список аудіооб’єктів")
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "Не вдалося прочитати список аудіооб’єктів")
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Не вдалося прочитати назву аудіооб’єкта")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func channels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> UInt32 {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Не вдалося прочитати канали")
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory), "Не вдалося прочитати канали")
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    static func outputs() throws -> [OutputDevice] {
        try objects(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("local.mixer.aggregate."),
                  let channels = try? channels(id, scope: kAudioObjectPropertyScopeOutput), channels > 0,
                  let alive: UInt32 = try? scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)), alive != 0,
                  let rate: Double = try? scalar(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)), rate > 0
            else { return nil }
            return OutputDevice(id: id, uid: uid,
                                name: (try? string(id, kAudioObjectPropertyName)) ?? "Аудіовихід",
                                sampleRate: rate, channels: channels,
                                transport: (try? scalar(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// Created, invoked and removed exclusively on AudioBackend's serial queue.
final class HardwareObservation {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue, changed: @escaping @Sendable () -> Void) throws {
        self.object = object
        self.address = HAL.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in changed() }
        try HAL.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Не вдалося підписатися на зміни аудіо")
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
}
