//
//  CoreAudioHAL.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/6/26.
//

import CoreAudio
import Foundation
import OSLog

/// Reads from Core Audio's Hardware Abstraction Layer.
///
/// Every HAL query is the same shape — build an address, ask the size, read the
/// bytes — so it lives here once. A namespace rather than a wrapper type because
/// `AudioObjectID` is a typealias for `UInt32`: extending it would hang audio
/// methods off every integer in the app.
package nonisolated enum CoreAudioHAL {
    
    package static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    package static let unknownObject = AudioObjectID(kAudioObjectUnknown)
    private static let log = Logger(subsystem: "tyto", category: "CoreAudioHAL")
    
    /// A fixed-size, trivially-copyable value (pid_t, UInt32,
    /// AudioStreamBasicDescription, …).
    package static func value<T>(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer -> T? in
            let status = AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
            guard status == noErr else {
                log.debug("""
                    value \(fourCharCode(selector), privacy: .public) on \
                    \(objectID, privacy: .public) failed: \(describe(status), privacy: .public)
                    """)
                return nil
            }
            return buffer.baseAddress!.pointee
        }
    }
    
    /// A CFString property. The HAL returns a +1 reference; binding it to a Swift
    /// `CFString?` lets ARC balance that retain.
    package static func string(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        var address = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: CFString?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            log.debug("""
                string \(fourCharCode(selector), privacy: .public) on \
                \(objectID, privacy: .public) failed: \(describe(status), privacy: .public)
                """)
            return nil
        }
        return result as String?
    }
    
    /// A CFArray-of-CFString property (aggregate tap lists, data source names).
    package static func strings(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [String] {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFArray?>.size)
        
        // A property that isn't CFArray-backed returns a different size; reading it
        // as a CFArray reinterprets raw bytes as a pointer and crashes on release.
        var actualSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &actualSize) == noErr,
              actualSize == size else {
            log.error("""
                strings \(fourCharCode(selector), privacy: .public) on \
                \(objectID, privacy: .public): not a CFArray property
                """)
            return []
        }
        
        var result: CFArray?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            log.debug("""
                strings \(fourCharCode(selector), privacy: .public) on \
                \(objectID, privacy: .public) failed: \(describe(status), privacy: .public)
                """)
            return []
        }
        return result as? [String] ?? []
    }
    
    /// A variable-length array property.
    package static func array<T>(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            log.debug("""
                array \(fourCharCode(selector), privacy: .public) on \
                \(objectID, privacy: .public) failed: \(describe(status), privacy: .public)
                """)
            return []
        }
        guard size > 0 else { return [] }

        return [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.size) {
            buffer, count in
            let status = AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
            count = status == noErr ? Int(size) / MemoryLayout<T>.size : 0
        }
    }
    
    /// Writes a fixed-size value. Returns the status rather than a Bool: when the HAL
    /// refuses a write, *why* is the whole story.
    @discardableResult
    package static func setValue<T>(
        _ value: T,
        _ selector: AudioObjectPropertySelector,
        on objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> OSStatus {
        var address = address(selector, scope: scope)
        var value = value
        return AudioObjectSetPropertyData(
            objectID, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value
        )
    }
    
    /// Writes a CFString property.
    package static func setString(
        _ value: String,
        _ selector: AudioObjectPropertySelector,
        on objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> OSStatus {
        var address = address(selector, scope: scope)
        var cfValue = value as CFString
        return AudioObjectSetPropertyData(
            objectID, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), &cfValue
        )
    }
    
    package static func hasProperty(
        _ selector: AudioObjectPropertySelector,
        on objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = address(selector, scope: scope)
        return AudioObjectHasProperty(objectID, &address)
    }
    
    /// Input channels a device actually presents, summed across its buffers.
    package static func inputChannelCount(of deviceID: AudioObjectID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration,
                              scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    
    /// Names the device gives its input channels, in channel order.
    ///
    /// For an aggregate this is the closest thing the HAL offers to self-describing
    /// channel order — each channel is usually named after the sub-device or tap it
    /// came from. Not every device implements it. An unhelpful name means "unknown",
    /// never proof of a mapping.
    package static func inputChannelNames(of deviceID: AudioObjectID) -> [String] {
        let count = inputChannelCount(of: deviceID)
        guard count > 0 else { return [] }
        // Channel elements are 1-based; element 0 is the device as a whole.
        return (1...count).map { channel in
            string(kAudioObjectPropertyElementName,
                   from: deviceID,
                   scope: kAudioObjectPropertyScopeInput,
                   element: AudioObjectPropertyElement(channel))
                ?? "channel \(channel)"
        }
    }
    
    /// Resolves a process ID to its HAL process object.
    package static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var objectID = unknownObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != unknownObject else {
            return nil
        }
        return objectID
    }
    
    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
    
    /// Core Audio packs selectors and error codes as four ASCII bytes, so
    /// 1852797029 is unreadable but 'nope' isn't.
    package static func fourCharCode(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let text = String(bytes: bytes, encoding: .ascii) else {
            return String(value)
        }
        return "'\(text)'"
    }
    
    package static func describe(_ status: OSStatus) -> String {
        status == noErr ? "ok" : fourCharCode(UInt32(bitPattern: status))
    }
    
}
