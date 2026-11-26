//
//  CaptureEngine.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/6/26.
//

import CoreAudio
import CoreAudioTypes
import Foundation
import OSLog

/// Owns the capture chain: tap → aggregate device → IOProc.
///
/// The aggregate carries two input channels: the process tap (remote) and the
/// microphone sub-device (local). Per-channel samples land in ring buffers
/// for the transcription layer to drain.
package nonisolated final class CaptureEngine {
    
    package enum Failure: Error, LocalizedError {
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
        case noMicrophone

        package var errorDescription: String? {
            switch self {
            case .ioProcFailed(let status):
                "Could not create the IO proc (\(CoreAudioHAL.describe(status)))."
            case .startFailed(let status):
                "Could not start the device (\(CoreAudioHAL.describe(status)))."
            case .noMicrophone:
                "No microphone is available to capture your side of the session."
            }
        }
    }

    package private(set) var isRunning = false

    package init() {}

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var procID: AudioDeviceIOProcID?

    private let ioQueue = DispatchQueue(label: "tyto.audio-io",
                                        qos: .userInitiated)
    /// Separate from `ioQueue`, which the IOProc block is dispatched on — the
    /// signal check logs, and logging must not queue behind or ahead of audio.
    private let checkQueue = DispatchQueue(label: "tyto.audio-check")
    private let log = Logger(subsystem: "tyto", category: "CaptureEngine")
    
    package static let maxChannels = 8
    /// One meter per aggregate input channel, preallocated — the IOProc indexes
    /// into this and must never allocate.
    package let meters: [ChannelMeter] = (0..<CaptureEngine.maxChannels).map { _ in ChannelMeter() }

    /// Host time of the aggregate's first IO cycle, for aligning this channel's
    /// timeline against the microphone's.
    package let origin = StreamOrigin()

    /// How many of `meters` are actually backed by a channel.
    package private(set) var channelCount = 0
    
    /// The rate the aggregate settled on — what the ring buffers hold, and what the
    /// transcriber converts from. Read once at start: a running aggregate can't
    /// change rate underneath us.
    package private(set) var sampleRate: Double = 0
    
    /// Which *buffer* of the IO cycle carries which speaker.
    ///
    /// Buffer index, deliberately not channel index. The HAL presents one
    /// `AudioBuffer` per aggregate member — sub-devices first, then taps — and that
    /// structure holds even when a member's channel count changes.
    ///
    /// This used to map flattened channel indices, local 0 and remote 1, and that
    /// was correct exactly until voice processing started working. Enabling it turns
    /// the built-in microphone from a 1-channel device into a 3-channel one *while the
    /// aggregate is running*, so the cycle goes from `[mic, tap]` to
    /// `[mic0, mic1, mic2, tap]`. Channel 1 stopped being the tap and became the
    /// microphone's second channel, and the remote side's transcript was fed the raw
    /// microphone — the local speaker's own voice, attributed to the remote side. Measured
    /// with Diagnostics/channelmap.swift.
    package struct SourceMap: Sendable {
        /// Microphone sub-device. Only used when voice processing is unavailable;
        /// otherwise MicrophoneCapture supplies the local speaker's channel.
        package var local: Int
        /// Process tap — the remote side's side of the call.
        package var remote: Int

        /// One sub-device then one tap, which is what `AggregateDevice` always builds.
        package static let `default` = SourceMap(local: 0, remote: 1)
    }

    package var sourceMap: SourceMap = .default

    /// Process objects to tap, or nil for every other process. Read at `start()`.
    package var tapTargets: [AudioObjectID]?

    /// How many members the aggregate presents. Small and fixed: one microphone, one
    /// tap. Sized separately from `maxChannels`, which counts channels.
    package static let maxSources = 4
    
    /// Two seconds at 48 kHz — generous. The consumer drains far faster than this.
    private static let ringFrames = 96_000

    package private(set) var localBuffer: AudioRingBuffer?
    package private(set) var remoteBuffer: AudioRingBuffer?

    /// Changes which processes the running tap captures. No effect on a global tap.
    package func retargetTap(to targets: [AudioObjectID]) {
        guard tapTargets != nil else { return }
        tapTargets = targets
        tap?.retarget(to: targets)
    }

    package func start() throws {
        guard !isRunning else { return }
        
        // Both sides or nothing: a one-sided aggregate puts the remote side's audio on
        // channel 0, where the channel map expects the local speaker.
        guard let inputDeviceID = AudioDevices.defaultInputID() else {
            throw Failure.noMicrophone
        }

        let tap = try ProcessTap(including: tapTargets)
        self.tap = tap

        let aggregate = try AggregateDevice(tap: tap, inputDeviceID: inputDeviceID)
        self.aggregate = aggregate

        channelCount = CoreAudioHAL.inputChannelCount(of: aggregate.objectID)
        
        guard channelCount >= 2 else {
            abandon()
            throw Failure.noMicrophone
        }
        
        sampleRate = AudioDevices.sampleRate(of: aggregate.objectID) ?? tap.sampleRate
        
        aggregate.logComposition()
        
        let localBuffer = AudioRingBuffer(minimumFrames: Self.ringFrames)
        let remoteBuffer = AudioRingBuffer(minimumFrames: Self.ringFrames)
        self.localBuffer = localBuffer
        self.remoteBuffer = remoteBuffer

        // Preallocated per-source sinks — the IOProc indexes, never allocates.
        var sinks = [AudioRingBuffer?](repeating: nil, count: Self.maxSources)
        if sourceMap.local < sinks.count { sinks[sourceMap.local] = localBuffer }
        if sourceMap.remote < sinks.count { sinks[sourceMap.remote] = remoteBuffer }
        let capturedSinks = sinks

        meters.forEach { $0.reset() }
        let meters = self.meters   // capture locally — never touch self from the IOProc
        let origin = self.origin

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            aggregate.objectID,
            ioQueue
        ) { inNow, inputData, inInputTime, _, _ in
            origin.noteIfFirst(inInputTime.pointee.mHostTime != 0
                               ? inInputTime.pointee.mHostTime
                               : inNow.pointee.mHostTime)
            Self.process(inputData, meters: meters, sinks: capturedSinks)
        }
        guard createStatus == noErr, let newProcID else {
            abandon()
            throw Failure.ioProcFailed(createStatus)
        }
        procID = newProcID

        let startStatus = AudioDeviceStart(aggregate.objectID, newProcID)
        guard startStatus == noErr else {
            abandon()
            throw Failure.startFailed(startStatus)
        }

        isRunning = true
        log.info("capture started on aggregate \(aggregate.objectID, privacy: .public)")
        
        scheduleSignalCheck()
    }
    
    /// Serial queue for teardown, at `.default` to match the `coreaudiod` threads this
    /// work blocks on. A higher QoS here is a priority inversion: a fast thread waiting
    /// on a slow one. See MicrophoneCapture for the same reasoning.
    private static let teardownQueue = DispatchQueue(
        label: "tyto.capture-teardown", qos: .default)

    /// The blocking part, taking plain HAL handles rather than the wrapper objects —
    /// `AggregateDevice` and `ProcessTap` are not `Sendable` and must not cross here.
    private static func tearDown(aggregate: AudioObjectID?,
                                 tap: AudioObjectID?,
                                 procID: AudioDeviceIOProcID?,
                                 log: Logger) {
        if let aggregate, aggregate != CoreAudioHAL.unknownObject {
            if let procID {
                AudioDeviceStop(aggregate, procID)
                AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            // Aggregate before tap: the aggregate's composition references the tap's
            // UID, and destroying the tap first leaves it holding a dangling member.
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if status != noErr {
                log.error("aggregate destroy failed: \(CoreAudioHAL.describe(status), privacy: .public)")
            }
        }
        if let tap, tap != CoreAudioHAL.unknownObject {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status != noErr {
                log.error("tap destroy failed: \(CoreAudioHAL.describe(status), privacy: .public)")
            }
        }
    }

    /// Pins the QoS explicitly: `DispatchQueue.async` otherwise propagates the caller's
    /// QoS, so a call from the main actor would re-raise this work to user-interactive
    /// and reintroduce the inversion on a queue that claims to be `.default`.
    private static func submitTeardown(_ handles: Handles,
                                       log: Logger,
                                       then completion: (@Sendable () -> Void)? = nil) {
        teardownQueue.async(qos: .default, flags: .enforceQoS) {
            tearDown(aggregate: handles.aggregate, tap: handles.tap,
                     procID: handles.procID, log: log)
            completion?()
        }
    }

    /// HAL handles, detached from their wrappers so they can be torn down elsewhere.
    private struct Handles {
        var aggregate: AudioObjectID?
        var tap: AudioObjectID?
        var procID: AudioDeviceIOProcID?
        var isEmpty: Bool { aggregate == nil && tap == nil }
    }

    /// Drops every reference and returns the HAL handles. After this the engine is
    /// fully reset and the caller owns what remains to be destroyed.
    private func release() -> Handles {
        let handles = Handles(aggregate: aggregate?.relinquish(),
                              tap: tap?.relinquish(),
                              procID: procID)
        procID = nil
        aggregate = nil
        tap = nil

        remoteBuffer = nil
        localBuffer = nil

        channelCount = 0
        sampleRate = 0
        isRunning = false
        return handles
    }

    /// Stops capture, doing the blocking HAL teardown off the main actor.
    ///
    /// `AudioDeviceStop`, `AudioDeviceDestroyIOProcID` and destroying the aggregate all
    /// block on `coreaudiod`. Running them on the main actor blocked the UI and the
    /// runtime reported it as a priority inversion. Awaiting suspends the task instead
    /// of holding a thread, so the ordering the transcriber depends on is
    /// preserved — capture has genuinely stopped when this returns — without anything
    /// of higher QoS waiting.
    package nonisolated(nonsending) func stop() async {
        // Nothing torn down means nothing to say: SwiftUI builds and discards @State
        // objects eagerly, and every discarded one runs deinit → teardown.
        let wasRunning = isRunning
        let handles = release()
        guard !handles.isEmpty else { return }

        await withCheckedContinuation { continuation in
            Self.submitTeardown(handles, log: log) { continuation.resume() }
        }
        if wasRunning { log.info("capture stopped") }
    }

    /// Teardown with nothing waiting on it — for `start()`'s error paths and `deinit`,
    /// where no ordering guarantee is owed and `deinit` cannot await regardless.
    private func abandon() {
        let handles = release()
        guard !handles.isEmpty else { return }
        Self.submitTeardown(handles, log: log)
    }

    deinit { abandon() }
    
    // MARK: Realtime

    /// Runs on the realtime audio thread. No allocation, no locks, no logging, no `self`.
    ///
    /// Meters are recorded per flattened channel; audio is *routed* per buffer. Those
    /// are deliberately different — see `SourceMap`.
    private static func process(_ input: UnsafePointer<AudioBufferList>, meters: [ChannelMeter], sinks: [AudioRingBuffer?]) {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        var channelOffset = 0

        for (source, buffer) in list.enumerated() {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frames = total / channels
            let samples = data.bindMemory(to: Float.self, capacity: total)

            // Meters stay per flattened channel: they are diagnostics, and seeing a
            // member grow from one channel to three is exactly what they are for.
            for ch in 0..<channels {
                let index = channelOffset + ch
                var peak: Float = 0
                var i = ch
                while i < total {
                    peak = max(peak, abs(samples[i]))
                    i += channels
                }
                if index < meters.count {
                    meters[index].record(peak: peak, frames: frames)
                }
            }
            channelOffset += channels

            // Routing goes by member, and always takes that member's first channel.
            // The microphone's extra channels appear and disappear with voice
            // processing; which buffer it is does not.
            if source < sinks.count, let sink = sinks[source] {
                sink.write(from: samples, frames: frames, stride: channels, offset: 0)
            }
        }
    }
    
    /// Two seconds after starting, say what we actually have.
    ///
    /// Every API in this file returns noErr when the tap is unauthorized — the IO
    /// proc runs at the right rate with right-sized buffers full of zeros. The only
    /// evidence that distinguishes "denied" from "working" is the samples.
    private func scheduleSignalCheck() {
        let meters = self.meters
        checkQueue.asyncAfter(deadline: .now() + 2) { [log] in
            // Every channel that actually arrived, not the count read at start. Voice
            // processing turns the microphone into a 3-channel device *after* the
            // aggregate is built, so a fixed count reports two quiet microphone
            // channels and silently omits the tap — which is exactly how a working
            // remote channel came to look silent in the logs.
            let readings = (0..<Self.maxChannels)
                .map { (frames: meters[$0].frames, peak: meters[$0].peakHold) }
                .filter { $0.frames > 0 }
            let cycling = readings.contains { $0.frames > 0 }
            let audible = readings.contains { $0.peak > 0.0001 }
            let detail = readings.enumerated()
                .map { "ch\($0.offset) \($0.element.frames)f peak \($0.element.peak)" }
                .joined(separator: ", ")

            switch (cycling, audible) {
            case (false, _):
                log.error("signal check: IO proc never fired — \(detail, privacy: .public)")
            case (true, false):
                log.error("""
                    signal check: IO cycles running, every channel silent — \
                    permission denied or source muted — \(detail, privacy: .public)
                    """)
            case (true, true):
                log.info("signal check: audio flowing — \(detail, privacy: .public)")
            }
        }
    }
    
}
