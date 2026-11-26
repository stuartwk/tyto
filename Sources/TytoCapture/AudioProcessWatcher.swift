//
//  AudioProcessWatcher.swift
//  tyto
//

import CoreAudio
import Foundation
import OSLog

/// Reports when the set of processes Core Audio knows about changes.
///
/// An app gets a process object only once it opens an audio connection, so an app
/// launched after capture starts, or a helper it spawns mid-call, appears here
/// later. Watching this list is how a per-app tap follows its app.
package final class AudioProcessWatcher: @unchecked Sendable {

    private let queue = DispatchQueue(label: "tyto.process-watcher")
    private let onChange: @Sendable () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private let log = Logger(subsystem: "tyto", category: "AudioProcessWatcher")

    /// - Parameter onChange: called on a private queue whenever the list changes.
    package init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    package func start() {
        guard listener == nil else { return }
        let onChange = self.onChange
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(CoreAudioHAL.systemObject, &address, queue, block)
        if status == noErr {
            listener = block
        } else {
            log.error("process list listener failed: \(CoreAudioHAL.describe(status), privacy: .public)")
        }
    }

    package func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(CoreAudioHAL.systemObject, &address, queue, listener)
        self.listener = nil
    }

    deinit { stop() }
}
