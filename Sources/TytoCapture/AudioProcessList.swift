//
//  AudioProcessList.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/5/26.
//

import CoreAudio
import Foundation

/// One process object as the audio HAL sees it.
package struct AudioProcess: Identifiable, Hashable, Sendable {
    /// HAL object ID. Valid only while the process lives — never persist this.
    package let id: AudioObjectID
    package let pid: pid_t
    /// Nil for processes with no bundle (daemons, helper tools).
    package let bundleID: String?
    /// True when this process is currently playing audio.
    package let isRunningOutput: Bool
}

package nonisolated enum AudioProcessList {

    /// Every process object the HAL currently knows about.
    package static func current() -> [AudioProcess] {
        let ids: [AudioObjectID] = CoreAudioHAL.array(
            kAudioHardwarePropertyProcessObjectList,
            from: CoreAudioHAL.systemObject
        )
        // A process can exit between listing and describing it, so per-object
        // reads are allowed to fail. That's normal churn, not an error.
        return ids.compactMap(describe)
    }

    /// Processes currently producing output audio — i.e. who is actually making noise.
    package static func producingAudio() -> [AudioProcess] {
        current().filter(\.isRunningOutput)
    }

    /// Every process belonging to an app: the bundle ID itself and its helpers, which
    /// share it as a prefix (com.microsoft.teams2 → com.microsoft.teams2.helper).
    package static func all(bundleIDPrefix prefix: String) -> [AudioProcess] {
        current().filter { $0.bundleID?.hasPrefix(prefix) == true }
    }

    package static func first(bundleID: String) -> AudioProcess? {
        current().first { $0.bundleID == bundleID }
    }
    
    /// Our own process object, so a global tap can leave us out.
    package static func ownProcessObjectID() -> AudioObjectID? {
        CoreAudioHAL.processObject(forPID: getpid())
    }
    
    // MARK: Per-object reads

    private static func describe(_ id: AudioObjectID) -> AudioProcess? {
        guard let pid: pid_t = CoreAudioHAL.value(kAudioProcessPropertyPID, from: id)
        else { return nil }

        let running: UInt32 = CoreAudioHAL.value(kAudioProcessPropertyIsRunningOutput,
                                                 from: id) ?? 0
        return AudioProcess(
            id: id,
            pid: pid,
            bundleID: CoreAudioHAL.string(kAudioProcessPropertyBundleID, from: id),
            isRunningOutput: running != 0
        )
    }
}
