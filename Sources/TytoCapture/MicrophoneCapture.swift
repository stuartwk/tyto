//
//  MicrophoneCapture.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/22/26.
//

import AVFoundation
import Foundation
import OSLog

/// Captures the local speaker's microphone through the system's voice processing unit.
///
/// This exists instead of reading the microphone through the capture aggregate
/// because macOS's echo cancellation lives in an audio unit, not in a device
/// property. An IOProc reading the raw device bypasses the layer that does the
/// cancelling — which is why the remote side's voice came through the speakers, into the
/// microphone, and out the other end labelled as the local speaker.
///
/// The cost is a second clock: this runs on `AVAudioEngine`'s IO thread, not the
/// aggregate's. The two sides are aligned by host time rather than by sample.
/// Thread-safety is by discipline, not by type: every mutation happens on the main
/// actor (`start`/`stop` are called by the owning session, and the configuration
/// observer hops there before touching anything). The tap block deliberately
/// captures only `meter` and the ring, both of which are safe to write from the
/// audio thread.
package nonisolated final class MicrophoneCapture: @unchecked Sendable {
    
    package enum Failure: Error, LocalizedError {
        case voiceProcessingUnavailable(Error)
        case tapInstallFailed(Error)
        case engineStartFailed(Error)

        package var errorDescription: String? {
            switch self {
            case .voiceProcessingUnavailable(let underlying):
                "Could not enable echo cancellation (\(underlying.localizedDescription))."
            case .engineStartFailed(let underlying):
                "Could not start the microphone (\(underlying.localizedDescription))."
            case .tapInstallFailed(let underlying):
                "Could not attach to the microphone (\(underlying.localizedDescription))."
            }
        }
    }
    
    package init() {}

    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "tyto", category: "MicrophoneCapture")

    /// Off the audio path entirely — the signal check logs, and logging must never
    /// queue near the IO thread.
    private static let checkQueue = DispatchQueue(
        label: "tyto.microphone-check", qos: .utility)

    package let meter = ChannelMeter()

    /// Detects holes in the tap's stream and reports what was lost. Created at
    /// `start` because it needs the negotiated sample rate.
    package private(set) var continuity: AudioContinuity?
    
    /// The format the voice processing unit hands us, which is its choice and not
    /// ours — it is usually mono and may not match the aggregate's rate.
    package private(set) var format: AVAudioFormat?
    package private(set) var isRunning = false

    /// Held so the engine can be restarted into the same ring after a configuration
    /// change, without the transcriber noticing anything but a gap.
    private var ring: AudioRingBuffer?
    private var configurationObserver: (any NSObjectProtocol)?
    /// Restarts within the current window, which is what the cap is measured against.
    private var restartCount = 0

    /// Every restart this session. Each one is a hole in the local speaker's audio, so
    /// this is a property of the recording rather than a statistic — kept separately
    /// from `restartCount` because that one resets whenever things go quiet.
    package private(set) var interruptionCount = 0
    /// Restarts allowed within `restartWindow`. A budget over the whole session is
    /// the wrong shape: the voice processing unit churns while it settles and spends
    /// most of the budget in the first minute, leaving a fifty-minute session with no
    /// recovery left for the other forty-nine. What must be caught is *sustained*
    /// thrashing, so the tally resets once things have been quiet.
    private static let maximumRestarts = 10
    private static let restartWindow: TimeInterval = 60
    private var lastRestart: Date?
    
    package func start(into ring: AudioRingBuffer) throws {
        guard !isRunning else { return }
        self.ring = ring
        restartCount = 0
        interruptionCount = 0
        lastRestart = nil
        
        let input = engine.inputNode
        
        // The mixer must exist *before* voice processing is enabled.
        //
        // Voice processing is a duplex unit: it negotiates its input and output buses
        // together, whether or not this app plays anything. Touching mainMixerNode
        // connects it to the output node. Done after enabling, that late graph change
        // makes the output side fail to initialize: engine.start() throws -10875
        // (kAUInitialize on outputNode) on macOS 27.2, every time, in a fresh process.
        // Done before, it starts every time. It worked in the other order on 27.0,
        // so this is an ordering dependency the OS started enforcing, not a fix that
        // was always needed.
        //
        // Deliberately not routing the microphone into the mixer: that would play the
        // local speaker's voice out of the speakers, a feedback loop and a privacy
        // problem.
        _ = engine.mainMixerNode
        engine.mainMixerNode.outputVolume = 0

        // Must precede engine.start(). This one call is the entire reason this type
        // exists: it is the only echo canceller macOS exposes to an app.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw Failure.voiceProcessingUnavailable(error)
        }
        
        // Voice processing ducks other audio whenever the near end speaks, system
        // wide and on by default. Unchanged, that means a note-taking app quietly
        // fades the remote side out every time the local speaker talks, degrading
        // the conversation we are supposed to be transcribing. Turn it down as far as the
        // API allows.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )

        // Read before starting, only so the log can show whether negotiation moved it.
        let negotiatedBeforeStart = input.outputFormat(forBus: 0)

        meter.reset()
        let meter = self.meter   // capture locally — the tap block must not touch self

        // The unit's rate, read before the engine starts, is provisional — but the
        // tap needs a rate now, and a few Hz of error over a 100 ms hole is far below
        // the detection threshold.
        let continuity = AudioContinuity(
            sampleRate: input.outputFormat(forBus: 0).sampleRate)
        self.continuity = continuity

        do {
            // format: nil — take whatever the node settles on. Pinning a format read
            // before the engine starts asks the unit to honour a guess made before it
            // had negotiated anything.
            try input.installAudioTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, when in
                // channelData(0) with stride mirrors what floatChannelData[0] did: a
                // non-interleaved buffer strides by 1, an interleaved one steps over
                // the other channels.
                guard case .float(let samples) = buffer.channelData(0) else { return }
                let frames = buffer.frameLength
                let stride = buffer.stride

                // Before anything else: if the stream stalled, fill the hole so the
                // analyzer's timeline keeps matching elapsed time. Closing it up
                // instead would shift every later timestamp on this channel earlier.
                if when.isHostTimeValid {
                    let missing = continuity.silenceNeeded(
                        hostTime: when.hostTime, frames: frames)
                    if missing > 0 { ring.writeSilence(frames: missing) }
                }

                var peak: Float = 0
                for frame in 0..<frames {
                    peak = max(peak, abs(samples[frame * stride]))
                }
                meter.record(peak: peak, frames: frames)

                samples.withUnsafeBufferPointer { raw in
                    guard let base = raw.baseAddress else { return }
                    ring.write(from: base, frames: frames, stride: stride, offset: 0)
                }
            }
        } catch {
            throw Failure.tapInstallFailed(error)
        }
        
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineStartFailed(error)
        }

        // Only now is this the real answer. Before start() the node reports whatever
        // it had provisionally, which is how a 9-channel value got mistaken for the
        // negotiated format.
        let format = input.outputFormat(forBus: 0)
        self.format = format
        isRunning = true

        // What device the engine actually chose. The AUVPAggregate errors name a
        // device by ID and nothing else, which is unreadable after the fact.
        if let inputID = AudioDevices.defaultInputID() {
            log.info("""
                default input \(AudioDevices.name(of: inputID) ?? "unknown", privacy: .public) \
                (\(inputID, privacy: .public)) — \
                \(CoreAudioHAL.inputChannelCount(of: inputID), privacy: .public) ch
                """)
        }

        log.info("""
            microphone started — \(format.sampleRate, privacy: .public) Hz, \
            \(format.channelCount, privacy: .public) ch \
            (before start: \(negotiatedBeforeStart.sampleRate, privacy: .public) Hz, \
            \(negotiatedBeforeStart.channelCount, privacy: .public) ch), \
            voice processing \(input.isVoiceProcessingEnabled ? "on" : "OFF", privacy: .public)
            """)

        // The channel count says nothing about whether cancellation is running, and
        // an earlier version of this code threw when it wasn't 1 — which rejected a
        // working canceller and fell back to the uncancelled aggregate microphone.
        //
        // Measured on macOS 27.0 (26A5421a) with Diagnostics/aecwithcapture.swift:
        // this unit reports 9 identical channels and still removes 25-30 dB of far-end
        // audio played by another process. The format field and the cancellation are
        // simply unrelated. There is no cheap runtime check for the latter — proving it
        // takes a controlled acoustic measurement — so this logs what it got and trusts
        // the unit it asked for.
        observeConfigurationChanges()
        scheduleSignalCheck()

        if format.channelCount != 1 {
            log.info("""
                voice processing reports \(format.channelCount, privacy: .public) channels \
                rather than 1 — expected on this OS build, and not an indication that \
                cancellation is absent (see Diagnostics/aecwithcapture.swift)
                """)
        }
    }
    
    /// Restarts the engine when the audio configuration changes.
    ///
    /// `AVAudioEngine` stops *itself* when the input or output hardware's channel
    /// count or sample rate changes, and the app is required to restart it. This app
    /// guarantees such a change: enabling voice processing turns the built-in
    /// microphone from a 1-channel device into a 3-channel one. Unhandled, the first
    /// change ends the local speaker's channel for the rest of the session while the
    /// aggregate — a separate IOProc — carries on, so the session looks healthy and
    /// half of it is missing.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Return immediately. This runs on an internal dispatch queue, and the
            // documentation warns that tearing the engine down synchronously here
            // deadlocks.
            Task { @MainActor [weak self] in
                self?.restart()
            }
        }
    }

    /// Restarts the engine and nothing else.
    ///
    /// Emphatically not a full stop/start. Tearing down meant disabling voice
    /// processing, which reverts the microphone from 3 channels to 1, and re-enabling
    /// it puts it back — two more configuration changes, each firing this notification
    /// again. The recovery caused the fault: a two-minute session produced nine
    /// restarts, oscillating 3 ch and 1 ch, one short of giving up entirely.
    ///
    /// The nodes stay attached and the tap stays installed across a configuration
    /// change, so restarting the engine is the whole job.
    @MainActor
    private func restart() {
        guard isRunning else { return }

        // A quiet spell means the unit settled and whatever follows is a new episode.
        if let lastRestart, Date().timeIntervalSince(lastRestart) > Self.restartWindow {
            restartCount = 0
        }
        lastRestart = Date()

        guard restartCount < Self.maximumRestarts else {
            log.error("""
                audio configuration changed \(Self.maximumRestarts, privacy: .public) times in \
                \(Self.restartWindow, privacy: .public)s — the unit is thrashing; not \
                restarting again until it settles
                """)
            return
        }
        restartCount += 1
        interruptionCount += 1

        let previous = format
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.error("""
                audio configuration changed and the engine would not restart: \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        let current = engine.inputNode.outputFormat(forBus: 0)
        format = current

        // The transcriber was told a sample rate at start and converts from it. If the
        // hardware moved, every sample after this point is being resampled from the
        // wrong rate, and the transcript degrades without any other symptom.
        if let previous, previous.sampleRate != current.sampleRate {
            log.error("""
                microphone sample rate changed \(previous.sampleRate, privacy: .public) Hz \
                -> \(current.sampleRate, privacy: .public) Hz mid-session; the transcriber \
                is still converting from the old rate
                """)
        }

        log.error("""
            audio configuration changed — engine restarted \
            (interruption \(self.interruptionCount, privacy: .public)); audio was lost in between
            """)
    }

    /// Two seconds after starting, say whether the unit is actually delivering audio.
    ///
    /// Every API here reports success on a unit that hands back digital silence:
    /// `setVoiceProcessingEnabled` returns, the engine starts, the tap installs and
    /// fires on schedule with correctly-sized buffers of zeros. A session that
    /// transcribes nothing looks identical to a quiet room, and the only evidence
    /// that separates them is the samples — which were being metered and never read.
    private func scheduleSignalCheck() {
        let meter = self.meter
        Self.checkQueue.asyncAfter(deadline: .now() + 2) { [log] in
            let frames = meter.frames
            let peak = meter.peakHold
            switch (frames > 0, peak > 0.0001) {
            case (false, _):
                log.error("""
                    microphone signal check: tap never fired — no audio is reaching the \
                    local speaker's channel
                    """)
            case (true, false):
                log.error("""
                    microphone signal check: \(frames, privacy: .public) frames of near \
                    silence (peak \(peak, privacy: .public)) — voice processing is \
                    delivering nothing
                    """)
            case (true, true):
                log.info("""
                    microphone signal check: audio flowing — \(frames, privacy: .public) \
                    frames, peak \(peak, privacy: .public)
                    """)
            }
        }
    }

    /// Serial queue for teardown, so the blocking Core Audio work never runs on the
    /// main actor. Static because `deinit` has to be able to hand work to it while the
    /// instance is going away.
    ///
    /// Deliberately `.default`, matching the QoS of the `coreaudiod` threads this work
    /// blocks on. At `.userInitiated` the runtime still reported a priority inversion —
    /// the wait had simply moved off the main actor rather than gone away. A faster
    /// thread waiting on a slower one is the inversion; doing the waiting at the speed
    /// of what you are waiting for is the fix.
    private static let teardownQueue = DispatchQueue(
        label: "tyto.microphone-teardown", qos: .default)

    /// Submits teardown at an explicitly pinned QoS.
    ///
    /// `DispatchQueue.async` normally propagates the *caller's* QoS to the work item,
    /// so a call from the main actor would re-raise this to user-interactive and
    /// reintroduce exactly the inversion being avoided. `.enforceQoS` makes the stated
    /// QoS win over the caller's.
    private static func submitTeardown(_ engine: AVAudioEngine,
                                       then completion: (@Sendable () -> Void)? = nil) {
        teardownQueue.async(qos: .default, flags: .enforceQoS) {
            tearDown(engine)
            completion?()
        }
    }

    /// The blocking part. `engine.stop()` and `setVoiceProcessingEnabled(false)` both
    /// wait on Core Audio destroying the voice processing aggregate, which is slow
    /// enough to see.
    private static func tearDown(_ engine: AVAudioEngine) {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // Voice processing builds its own aggregate device around this microphone and
        // keeps it alive while enabled. Turning it off returns the device to the state
        // the next start() expects to negotiate from.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    /// Stops the microphone, doing the blocking teardown off the main actor.
    ///
    /// This used to be synchronous, and the runtime flagged it: a user-interactive
    /// thread waiting on the HAL's default-QoS threads is a priority inversion, and it
    /// blocked the UI for as long as tearing down the aggregate took. Suspending
    /// rather than blocking removes the inversion instead of hiding the warning, and
    /// the caller still gets the ordering guarantee it needs — the microphone has
    /// genuinely stopped writing by the time this returns.
    ///
    /// The awaiting task suspends; it does not block a thread. Nothing of higher QoS
    /// is left waiting on the teardown, which is what actually resolves the warning.
    package nonisolated(nonsending) func stop() async {
        // Guard rather than track a `wasRunning` flag: `engine.inputNode` is lazy, and
        // touching it instantiates the node and registers with the HAL. Phantom
        // instances from SwiftUI's @State would otherwise reach for the microphone.
        guard isRunning else { return }

        // Read before teardown: this is the session's whole answer to "was the
        // local speaker's microphone ever live", and it is unrecoverable afterwards.
        let frames = meter.frames
        let peak = meter.peakHold
        let lost = continuity?.lostSeconds ?? 0

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        // Cleared before suspending so a second stop() can't start a second teardown.
        isRunning = false
        format = nil

        let engine = self.engine
        await withCheckedContinuation { continuation in
            Self.submitTeardown(engine) { continuation.resume() }
        }
        log.info("""
            microphone stopped — \(frames, privacy: .public) frames delivered, \
            peak \(peak, privacy: .public) over the session, \
            \(lost, privacy: .public)s of audio lost to stream holes
            """)
    }

    /// Last resort only. `deinit` cannot await, so this hands the teardown off and
    /// lets it finish on its own — the closure captures the engine, which keeps it
    /// alive long enough to be shut down properly.
    deinit {
        guard isRunning else { return }
        let engine = self.engine
        Self.submitTeardown(engine)
    }
    
}
