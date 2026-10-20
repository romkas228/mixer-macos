// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio

// Optional must never conform: its discriminator changes the C storage size.
// In a `try?` / optional-binding context an unconstrained generic can infer T as Optional.
package protocol NativeAudioPropertyValue {}
extension UInt32: NativeAudioPropertyValue {}
extension Int32: NativeAudioPropertyValue {}
extension Double: NativeAudioPropertyValue {}
extension AudioStreamBasicDescription: NativeAudioPropertyValue {}

package enum NativeAudioProperty {
    package enum ReadError: Error, Equatable {
        case unexpectedSize(expected: UInt32, actual: UInt32)
    }

    package static func read<T: NativeAudioPropertyValue>(
        initial: T, fill: (UnsafeMutableRawPointer, inout UInt32) throws -> Void
    ) throws -> T {
        var value = initial
        let expected = UInt32(MemoryLayout<T>.size)
        var size = expected
        try withUnsafeMutablePointer(to: &value) {
            try fill(UnsafeMutableRawPointer($0), &size)
        }
        guard size == expected else { throw ReadError.unexpectedSize(expected: expected, actual: size) }
        return value
    }
}
