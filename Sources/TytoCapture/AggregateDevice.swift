//
//  AggregateDevice.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/6/26.
//

import CoreAudio
import Foundation
import OSLog

/// A private aggregate device presenting the tap — and the microphone — as
/// one input device with a single IOProc and a single clock.
///
/// The aggregate is what makes the two channels sample-aligned: they arrive on one
/// IO cycle rather than from two independently-clocked devices.
package nonisolated final class AggregateDevice {
    
    package enum Failure: Error, LocalizedError {
        case creationFailed(OSStatus)
        case noClockSource

        package var errorDescription: String? {
            switch self {
            case .creationFailed(let status):
                "Could not create the aggregate device (\(CoreAudioHAL.describe(status)))."
            case .noClockSource:
                "No clock source available."
            }
        }
    }
    
    package private(set) var objectID: AudioObjectID
    package let uid: String

    private let log = Logger(subsystem: "tyto", category: "AggregateDevice")
    
    /// Builds an aggregate containing `tap` and, when given, `inputDeviceID`.
    ///
    /// The microphone is the time source: it's a real member of the aggregate and
    /// runs continuously, so the tap is the side that gets drift correction.
    package init(tap: ProcessTap, inputDeviceID: AudioObjectID? = nil) throws {
        var subDevices: [[String: Any]] = []
        let clockUID: String

        if let inputDeviceID, let inputUID = AudioDevices.uid(of: inputDeviceID) {
            subDevices.append([
                kAudioSubDeviceUIDKey: inputUID,
                // The time source isn't drift-corrected — it *is* the reference.
                kAudioSubDeviceDriftCompensationKey: false,
            ])
            clockUID = inputUID
        } else if let outputID = AudioDevices.defaultOutputID(),
                  let outputUID = AudioDevices.uid(of: outputID) {
            // No microphone. Fall back to the output device, added as a real member
            // so the time source is something the aggregate actually contains.
            subDevices.append([
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceDriftCompensationKey: false,
            ])
            clockUID = outputUID
        } else {
            throw Failure.noClockSource
        }

        let uid = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "tyto",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // false: `true` makes AudioDeviceStart block until some tapped process
            // produces audio — the mic would go dead whenever the remote side is quiet.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var id = CoreAudioHAL.unknownObject
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != CoreAudioHAL.unknownObject else {
            throw Failure.creationFailed(status)
        }

        self.objectID = id
        self.uid = uid

        log.info("""
            aggregate \(id, privacy: .public) created — \
            clock \(clockUID, privacy: .public), tap \(tap.uid, privacy: .public)
            """)
    }
    
    /// Hands the HAL object over to the caller, which becomes responsible for
    /// destroying it, and leaves this wrapper inert so `deinit` won't double-destroy.
    ///
    /// Exists so teardown can move off the main actor: `AudioHardwareDestroyAggregateDevice`
    /// blocks, and an `AudioObjectID` is a plain value that can cross threads where
    /// this class — explicitly not thread-safe — cannot.
    package func relinquish() -> AudioObjectID {
        let id = objectID
        objectID = CoreAudioHAL.unknownObject
        return id
    }

    /// Destroys the aggregate. Idempotent; also runs from deinit.
    package func invalidate() {
        guard objectID != CoreAudioHAL.unknownObject else { return }
        let status = AudioHardwareDestroyAggregateDevice(objectID)
        if status != noErr {
            log.error("aggregate destroy failed: \(CoreAudioHAL.describe(status), privacy: .public)")
        }
        objectID = CoreAudioHAL.unknownObject
    }
    
    /// Logs what the HAL actually built, as opposed to what we asked for.
    /// `AudioHardwareCreateAggregateDevice` returns noErr even when it silently
    /// drops entries it doesn't like.
    package func logComposition() {
        let taps = CoreAudioHAL.strings(kAudioAggregateDevicePropertyTapList, from: objectID)
        let subDevices = CoreAudioHAL.strings(
            kAudioAggregateDevicePropertyFullSubDeviceList,
            from: objectID
        )
        let inputs = CoreAudioHAL.inputChannelCount(of: objectID)
        let names = CoreAudioHAL.inputChannelNames(of: objectID)
        // What the HAL settled on as the time source, which is not necessarily
        // the UID we asked for in the composition dictionary.
        let clock = CoreAudioHAL.string(kAudioAggregateDevicePropertyMainSubDevice, from: objectID)
        let active: [AudioObjectID] = CoreAudioHAL.array(
            kAudioAggregateDevicePropertyActiveSubDeviceList,
            from: objectID
        )
        let activeUIDs = active.compactMap { AudioDevices.uid(of: $0) }

        log.info("""
            aggregate \(self.objectID, privacy: .public) composition — \
            clock \(clock ?? "none", privacy: .public), \
            taps \(taps, privacy: .public), \
            subDevices \(subDevices, privacy: .public), \
            input channels \(inputs, privacy: .public) \(names, privacy: .public), \
            active \(activeUIDs, privacy: .public)
            """)
    }

    
    deinit { invalidate() }
    
}
