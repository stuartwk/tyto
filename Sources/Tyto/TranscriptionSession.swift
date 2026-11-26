//
//  TranscriptionSession.swift
//  tyto
//

import CoreAudio
import Foundation
import OSLog
import TytoCapture

/// Where the remote side of the conversation comes from.
public enum AudioSource: Sendable, Hashable {
    /// Every other app's audio. Right for most calls, including browser-based ones.
    case allApps
    /// One app and its helper processes, matched by bundle ID prefix
    /// (`com.microsoft.teams2` also matches `com.microsoft.teams2.helper`).
    ///
    /// The app doesn't have to be running yet. Core Audio only knows about a process
    /// once it opens audio, so the session waits for it and follows it: processes
    /// that appear later, such as a call window's helper, are added as they appear.
    ///
    /// Browsers play every tab's audio through one shared helper process, so
    /// targeting a browser captures all of its tabs, not just the call.
    case app(bundleID: String)
}

/// Whether the local channel is echo-cancelled.
public enum EchoCancellation: Sendable, Equatable {
    /// Apple's voice processing is removing the remote side from the microphone.
    case active
    /// Voice processing could not start, and the local channel is the raw
    /// microphone. On speakers, the remote side's voice reaches it and may be
    /// transcribed as local speech. Headphones avoid this.
    case unavailable(reason: String)
}

/// One finalised piece of speech, delivered as soon as the recognizer commits to it.
public struct Segment: Identifiable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    /// Seconds on the session timeline, shared by both channels. Nil when the
    /// recognizer attached no timing, which is rare.
    public let start: TimeInterval?
    public let end: TimeInterval?
    /// The recognizer's mean confidence, 0–1. Residual echo tends to score low.
    public let confidence: Double?
}

/// A problem worth surfacing to whoever is relying on the transcript.
public enum TranscriptionWarning: Sendable, Equatable {
    /// The microphone is delivering buffers of digital silence. A real microphone
    /// in a quiet room is never exactly zero, so this almost always means macOS
    /// denied microphone access without reporting an error.
    case microphoneSilent
    /// The microphone delivered no audio at all.
    case microphoneNotDelivering
}

/// Something that happened during a session, in the order tyto learned of it.
public enum TranscriptionEvent: Sendable {
    /// Finalised speech. Segments arrive per channel as each recognizer commits, so
    /// they are not strictly ordered by `start` across speakers.
    case segment(Segment)
    /// Audio that was lost. The text either side of it reads as continuous, so
    /// anything built on the transcript should say what it didn't hear.
    case gap(speaker: Speaker, at: TimeInterval, duration: TimeInterval)
    /// A segment delivered earlier looks like the other speaker's words leaking
    /// into this channel through the speakers: same moment, same distinctive
    /// words, decoded worse. Advisory; tyto never removes text.
    case suspectedBleed(Segment.ID)
    case warning(TranscriptionWarning)
    /// For `.app` sources: how many of the app's processes are now being captured.
    /// Zero until the app first opens audio.
    case sourceProcessesChanged(count: Int)
}

/// Transcribes a conversation as two channels: this Mac's microphone (`local`) and
/// other apps' audio (`remote`), entirely on-device.
///
/// ```swift
/// let session = TranscriptionSession(source: .app(bundleID: "us.zoom.xos"))
/// try await session.start()
/// Task {
///     for await event in session.events {
///         if case .segment(let segment) = event { print(segment.speaker, segment.text) }
///     }
/// }
/// // later
/// let transcript = await session.stop()
/// ```
///
/// The host app needs `NSMicrophoneUsageDescription` and
/// `NSAudioCaptureUsageDescription` in its Info.plist. Audio-capture denial is
/// silent: the remote channel simply receives zeros, which tyto cannot tell apart
/// from nobody talking.
@MainActor
public final class TranscriptionSession {

    public enum Failure: Error, LocalizedError {
        case alreadyStarted
        case localeUnsupported(Locale)
        case captureFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted:
                "This session has already been started. Create a new one for each conversation."
            case .localeUnsupported(let locale):
                "On-device speech recognition isn't available for \(locale.identifier)."
            case .captureFailed(let reason):
                reason
            }
        }
    }

    public let source: AudioSource
    public let locale: Locale

    /// Everything that happens, from `start()` until `stop()` or `cancel()` finishes it.
    /// Single consumer: iterate it from one place.
    public let events: AsyncStream<TranscriptionEvent>

    /// Known once `start()` returns.
    public private(set) var echoCancellation: EchoCancellation?

    private let eventSink: AsyncStream<TranscriptionEvent>.Continuation
    private let local: ChannelTranscriber
    private let remote: ChannelTranscriber
    private let engine = CaptureEngine()
    private let microphone = MicrophoneCapture()
    private var microphoneBuffer: AudioRingBuffer?
    private var phase = Phase.idle
    private var silenceCheck: Task<Void, Never>?
    private var processWatcher: AudioProcessWatcher?
    private var capturedProcesses: Set<AudioObjectID> = []

    /// Recent timed segments, for judging bleed as they arrive.
    private var recent: [Turn] = []
    private var flagged: Set<UUID> = []

    private enum Phase { case idle, running, finished }

    /// Two seconds at 48 kHz, matching CaptureEngine.
    private static let ringFrames = 96_000
    /// How far back a new segment is compared for bleed. Echo is simultaneous, so
    /// this only has to cover finalisation lag between the two recognizers.
    private static let bleedWindow: TimeInterval = 30
    private let log = Logger(subsystem: "tyto", category: "TranscriptionSession")

    public init(source: AudioSource = .allApps, locale: Locale = .current) {
        self.source = source
        self.locale = locale
        local = ChannelTranscriber(speaker: .local, locale: locale)
        remote = ChannelTranscriber(speaker: .remote, locale: locale)
        (events, eventSink) = AsyncStream<TranscriptionEvent>.makeStream()
    }

    /// Downloads the on-device speech model for `locale` if it isn't installed.
    ///
    /// `start()` does this too, but a first-run download can take a while; calling
    /// this early lets an app show progress before the microphone opens.
    public static func prepare(locale: Locale = .current) async throws {
        do {
            try await ChannelTranscriber.prepareModel(locale: locale)
        } catch ChannelTranscriber.Failure.localeUnsupported {
            throw Failure.localeUnsupported(locale)
        }
    }

    /// Opens the microphone and the process tap and starts transcribing.
    ///
    /// Echo cancellation is attempted and, if it fails, the session continues on the
    /// raw microphone; check `echoCancellation` afterwards.
    public func start() async throws {
        guard phase == .idle else { throw Failure.alreadyStarted }

        switch source {
        case .allApps:
            engine.tapTargets = nil
        case .app(let bundleID):
            // Possibly empty: the tap starts silent and is retargeted once the app
            // opens audio.
            capturedProcesses = Set(AudioProcessList.all(bundleIDPrefix: bundleID).map(\.id))
            engine.tapTargets = Array(capturedProcesses)
        }

        do {
            // Before the mic opens, not after: the ring buffers hold two seconds, and
            // a first-run model download takes longer than that.
            try await Self.prepare(locale: locale)
            try engine.start()

            guard let aggregateMic = engine.localBuffer,
                  let tapBuffer = engine.remoteBuffer else {
                throw Failure.captureFailed("Capture started but produced no audio buffers.")
            }
            let rate = engine.sampleRate

            for channel in [local, remote] {
                let speaker = channel.speaker
                channel.onSegment = { [weak self] in self?.publish($0, from: speaker) }
                channel.onGap = { [weak self] gap in
                    guard let self else { return }
                    self.eventSink.yield(.gap(speaker: speaker,
                                              at: gap.at + self.offset(for: speaker),
                                              duration: gap.duration))
                }
            }

            try await startLocal(fallingBackTo: aggregateMic, aggregateRate: rate)
            try await remote.start(draining: tapBuffer, sampleRate: rate)
            phase = .running
            scheduleSilenceCheck()
            followApp()
        } catch {
            await tearDown()
            phase = .finished
            eventSink.finish()
            if error is Failure { throw error }
            throw Failure.captureFailed(error.localizedDescription)
        }
    }

    /// Echo-cancelled microphone when voice processing starts, the aggregate's raw
    /// microphone channel when it doesn't.
    private func startLocal(fallingBackTo aggregateBuffer: AudioRingBuffer,
                            aggregateRate: Double) async throws {
        let processedBuffer = AudioRingBuffer(minimumFrames: Self.ringFrames)
        do {
            try microphone.start(into: processedBuffer)
            guard let format = microphone.format else {
                throw Failure.captureFailed("The microphone started but reported no audio format.")
            }
            microphoneBuffer = processedBuffer
            echoCancellation = .active
            // Its own rate: the voice processing unit picks a format and is under no
            // obligation to match the aggregate's.
            try await local.start(draining: processedBuffer, sampleRate: format.sampleRate)
        } catch {
            await microphone.stop()
            microphoneBuffer = nil
            echoCancellation = .unavailable(reason: error.localizedDescription)
            log.error("""
                local channel: falling back to the raw microphone — \
                \(error.localizedDescription, privacy: .public)
                """)
            try await local.start(draining: aggregateBuffer, sampleRate: aggregateRate)
        }
    }

    /// Stops capture, flushes buffered audio, finishes `events`, and returns the
    /// merged transcript.
    public func stop() async -> Transcript {
        guard phase == .running else { return .empty }
        phase = .finished
        silenceCheck?.cancel()
        processWatcher?.stop()
        processWatcher = nil

        // Capture has to stop writing before the channels flush, or the flush chases
        // a moving target. Voice processing first: it mutates the built-in microphone
        // (1 → 3 channels), and letting the device settle before destroying the
        // aggregate that merely reads it keeps the HAL quiet.
        await microphone.stop()
        await engine.stop()
        await local.finish()
        await remote.finish()

        if let holes = microphone.continuity?.recorded, !holes.isEmpty {
            local.record(holes: holes)
            for hole in holes {
                eventSink.yield(.gap(speaker: .local, at: hole.at + offset(for: .local),
                                     duration: hole.duration))
            }
        }
        if microphone.interruptionCount > 0 {
            log.error("""
                local audio was interrupted \(self.microphone.interruptionCount, privacy: .public) \
                time(s) by audio configuration changes
                """)
        }
        microphoneBuffer = nil

        let transcript = Transcript.merge([
            .init(speaker: .local, segments: local.segments, gaps: local.gaps,
                  offset: offset(for: .local)),
            .init(speaker: .remote, segments: remote.segments, gaps: remote.gaps,
                  offset: offset(for: .remote)),
        ])
        eventSink.finish()
        return transcript
    }

    /// Abandons the session without flushing and finishes `events`.
    public func cancel() async {
        guard phase == .running else { return }
        phase = .finished
        await tearDown()
        eventSink.finish()
    }

    private func tearDown() async {
        silenceCheck?.cancel()
        processWatcher?.stop()
        processWatcher = nil
        await microphone.stop()
        await engine.stop()
        local.cancel()
        remote.cancel()
        microphoneBuffer = nil
    }

    // MARK: Following an app

    /// For `.app` sources, keeps the tap pointed at every process of the app as they
    /// open audio and exit.
    private func followApp() {
        guard case .app(let bundleID) = source else { return }
        eventSink.yield(.sourceProcessesChanged(count: capturedProcesses.count))
        let watcher = AudioProcessWatcher { [weak self] in
            Task { @MainActor [weak self] in self?.refreshTargets(bundleID: bundleID) }
        }
        processWatcher = watcher
        watcher.start()
        // The app may have opened audio between reading the list and installing the
        // listener; one refresh closes that window.
        refreshTargets(bundleID: bundleID)
    }

    private func refreshTargets(bundleID: String) {
        guard phase == .running else { return }
        let current = Set(AudioProcessList.all(bundleIDPrefix: bundleID).map(\.id))
        guard current != capturedProcesses else { return }
        capturedProcesses = current
        engine.retargetTap(to: Array(current))
        eventSink.yield(.sourceProcessesChanged(count: current.count))
    }

    // MARK: Timeline

    /// Host time of each channel's first sample. The local channel comes from the
    /// voice processing unit when it is in use, otherwise from the aggregate.
    private func origin(for speaker: Speaker) -> UInt64? {
        switch speaker {
        case .local:
            echoCancellation == .active ? microphone.continuity?.origin.value : engine.origin.value
        case .remote:
            engine.origin.value
        }
    }

    /// Seconds between the earliest first sample and this channel's. Each recognizer
    /// counts from its own first buffer, and the two capture paths start
    /// milliseconds apart; without this an echo can land before its source.
    private func offset(for speaker: Speaker) -> TimeInterval {
        let origins = [origin(for: .local), origin(for: .remote)].compactMap { $0 }
        guard let earliest = origins.min(), let mine = origin(for: speaker) else { return 0 }
        return HostClock.seconds(from: earliest, to: mine)
    }

    // MARK: Live events

    private func publish(_ raw: ChannelTranscriber.Segment, from speaker: Speaker) {
        let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let shift = offset(for: speaker)
        let segment = Segment(id: UUID(), speaker: speaker, text: text,
                              start: raw.start.map { $0 + shift },
                              end: raw.end.map { $0 + shift },
                              confidence: raw.confidence)
        eventSink.yield(.segment(segment))
        checkBleed(segment)
    }

    /// Compares a new segment with recent ones from the other channel, in both
    /// directions: the new one may be the echo, or it may be the source of an echo
    /// that was finalised first.
    private func checkBleed(_ segment: Segment) {
        guard let start = segment.start, let end = segment.end else { return }
        let turn = Turn(id: segment.id, speaker: segment.speaker, text: segment.text,
                        start: start, end: end, confidence: segment.confidence)

        for other in recent where other.speaker != turn.speaker {
            if Transcript.looksLikeBleed(turn, of: other) { flag(turn.id) }
            if Transcript.looksLikeBleed(other, of: turn) { flag(other.id) }
        }

        recent.append(turn)
        let horizon = recent.map(\.end).max().map { $0 - Self.bleedWindow } ?? 0
        recent.removeAll { $0.end < horizon }
    }

    private func flag(_ id: UUID) {
        guard flagged.insert(id).inserted else { return }
        eventSink.yield(.suspectedBleed(id))
    }

    /// Three seconds in, check the microphone delivered real samples. macOS reports
    /// success at every step when access is denied and hands over zeros.
    private func scheduleSilenceCheck() {
        silenceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.phase == .running else { return }
            let meter = self.echoCancellation == .active ? self.microphone.meter : self.engine.meters[0]
            if meter.frames == 0 {
                self.eventSink.yield(.warning(.microphoneNotDelivering))
            } else if meter.peakHold <= 0.000_01 {
                self.eventSink.yield(.warning(.microphoneSilent))
            }
        }
    }
}
