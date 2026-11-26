//
//  ProcessTap.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/6/26.
//

import CoreAudio
import Foundation
import OSLog

/// A Core Audio process tap: a virtual input stream carrying other processes'
/// *output* audio. In tyto, this is the remote side of a call.
///
/// Global-with-exclusions by default. Per-app targeting is available, but browsers
/// isolate audio in shared helper processes (Safari → com.apple.WebKit.GPU, Chromium
/// → its audio service), so targeting a browser carries every tab's audio, not just
/// the call.
///
/// Not thread-safe. Own one from a single place.
package nonisolated final class ProcessTap {
    
    package enum Failure: Error, LocalizedError {
        case creationFailed(OSStatus)
        case formatUnavailable
        case unsupportedFormat

        package var errorDescription: String? {
            switch self {
            case .creationFailed(let status):
                "Could not create the audio tap (\(CoreAudioHAL.describe(status)))."
            case .formatUnavailable:
                "The audio tap did not report a stream format."
            case .unsupportedFormat:
                "The audio tap's stream format is not supported by this app."
            }
        }
    }
    
    /// Live HAL object ID, or `unknownObject` once invalidated.
    package private(set) var objectID: AudioObjectID

    /// Stable UID — how the aggregate device will refer to this tap.
    package let uid: String

    /// The tap's stream format, for the converter feeding SpeechAnalyzer.
    package let format: AudioStreamBasicDescription
    
    /// Plain accessors so callers don't need CoreAudio types just to show the format.
    package var sampleRate: Double { format.mSampleRate }
    package var channelCount: UInt32 { format.mChannelsPerFrame }

    private let log = Logger(subsystem: "tyto", category: "ProcessTap")
    
    /// - Parameters:
    ///   - including: when given, tap only these process objects (one app's
    ///     processes). Nil taps everything except `excluding` and this process.
    ///   - excluding: extra process objects to leave out of a global tap.
    package init(including targets: [AudioObjectID]? = nil,
                 excluding extraExclusions: [AudioObjectID] = []) throws {
        // Mono: SpeechAnalyzer wants mono, and attribution is per channel, not per
        // speaker within a channel.
        let description: CATapDescription
        let excluded: [AudioObjectID]
        if let targets {
            excluded = []
            description = CATapDescription(monoMixdownOfProcesses: targets)
        } else {
            var list = extraExclusions
            if let own = AudioProcessList.ownProcessObjectID() { list.append(own) }
            excluded = list
            description = CATapDescription(monoGlobalTapButExcludeProcesses: list)
        }
        description.name = "tyto"
        description.isPrivate = true         // keeps it out of other apps' device lists
        description.muteBehavior = .unmuted  // never change what the user hears

        var id = CoreAudioHAL.unknownObject
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != CoreAudioHAL.unknownObject else {
            throw Failure.creationFailed(status)
        }
        self.objectID = id

        guard let format: AudioStreamBasicDescription =
                CoreAudioHAL.value(kAudioTapPropertyFormat, from: id) else {
            AudioHardwareDestroyProcessTap(id)
            throw Failure.formatUnavailable
        }
        
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            AudioHardwareDestroyProcessTap(id)
            throw Failure.unsupportedFormat
        }
        
        self.format = format
        self.uid = CoreAudioHAL.string(kAudioTapPropertyUID, from: id)
            ?? description.uuid.uuidString
        
        

        log.info("""
            tap \(id, privacy: .public) created — \
            \(format.mSampleRate, privacy: .public) Hz, \
            \(format.mChannelsPerFrame, privacy: .public) ch, \
            \(targets.map { "targeting \($0.count)" } ?? "excluding \(excluded.count)", privacy: .public) process(es)
            """)
    }
    
    /// Changes which processes a targeted tap captures, while it runs.
    ///
    /// Lets a tap be created before the app it is for has opened audio (with an
    /// empty list) and follow it as its processes come and go, without rebuilding
    /// the aggregate. Verified on macOS 27.2: an empty tap retargeted to a playing
    /// process starts delivering that process's audio immediately.
    @discardableResult
    package func retarget(to targets: [AudioObjectID]) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var current: CATapDescription?
        var size = UInt32(MemoryLayout<CATapDescription?>.size)
        var status = withUnsafeMutablePointer(to: &current) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let description = current else {
            log.error("tap retarget: description unreadable (\(CoreAudioHAL.describe(status), privacy: .public))")
            return status
        }
        // Modify the tap's own description rather than building a new one: its UUID
        // is what the aggregate's composition refers to.
        description.processes = targets
        var updated: CATapDescription? = description
        status = withUnsafeMutablePointer(to: &updated) {
            AudioObjectSetPropertyData(objectID, &address, 0, nil, size, $0)
        }
        log.info("""
            tap \(self.objectID, privacy: .public) retargeted to \(targets.count, privacy: .public) \
            process(es): \(CoreAudioHAL.describe(status), privacy: .public)
            """)
        return status
    }

    /// Hands the HAL object over to the caller, which becomes responsible for
    /// destroying it, and leaves this wrapper inert so `deinit` won't double-destroy.
    ///
    /// Exists so teardown can move off the main actor: `AudioHardwareDestroyProcessTap`
    /// blocks, and an `AudioObjectID` is a plain value that can cross threads where
    /// this class — explicitly not thread-safe — cannot.
    package func relinquish() -> AudioObjectID {
        let id = objectID
        objectID = CoreAudioHAL.unknownObject
        return id
    }

    /// Destroys the tap. Idempotent; also runs from deinit.
    package func invalidate() {
        guard objectID != CoreAudioHAL.unknownObject else { return }
        let status = AudioHardwareDestroyProcessTap(objectID)
        if status != noErr {
            log.error("tap destroy failed: \(CoreAudioHAL.describe(status), privacy: .public)")
        }
        objectID = CoreAudioHAL.unknownObject
    }
    
    deinit { invalidate() }
    
}
