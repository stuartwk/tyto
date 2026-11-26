//
//  ChannelTranscriber.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/21/26.
//

import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech
import TytoCapture

/// Transcribes one side of a conversation: one ring buffer in, one live transcript out.
///
/// One instance per speaker, each with its own `SpeechAnalyzer`. The two sides are
/// never mixed, so they never have to be separated again — attribution comes from
/// the capture channel, not from diarization.
///
/// Audio moves ring buffer → PCM buffer → converter → analyzer and is released at
/// every step. Nothing here writes audio to disk.
@MainActor
@Observable
package final class ChannelTranscriber {
    
    /// Audio the ring buffer dropped before the drain loop could read it.
    ///
    /// A gap is a hole with no other symptom: the text on either side of it reads as
    /// continuous. Recorded so anything built on this transcript can say what it
    /// didn't hear, rather than quietly presenting a splice as speech.
    package struct Gap: Identifiable, Sendable {
        package let id = UUID()
        /// Seconds into this channel's *delivered* audio, so it lines up with the
        /// time ranges the transcriber attaches to its results.
        package let at: TimeInterval
        /// How much audio is missing. The whole point of recording a gap is to
        /// be able to say how much was not heard; a count of dropped blocks
        /// cannot.
        package let duration: TimeInterval
    }
    
    package enum Failure: Error, LocalizedError {
        case localeUnsupported
        case modelUnavailable
        case noAnalyzerFormat
        case sourceFormatUnavailable

        package var errorDescription: String? {
            switch self {
            case .localeUnsupported:
                "Speech recognition isn't available for this language on this Mac."
            case .modelUnavailable:
                "The on-device speech model could not be installed."
            case .noAnalyzerFormat:
                "The speech analyzer did not report an audio format it accepts."
            case .sourceFormatUnavailable:
                "The captured audio format could not be described."
            }
        }
    }
    
    /// One finalised result, with the timing the analyzer assigned it.
    ///
    /// `.audioTimeRange` and `.transcriptionConfidence` were already being requested
    /// and then discarded by appending straight into `finalized`. Keeping them is what
    /// makes a merged, time-ordered transcript possible — and the confidence is what
    /// distinguishes speech from residual echo the recognizer was guessing at.
    package struct Segment: Sendable {
        package let text: String
        /// Seconds into this channel's delivered audio. Nil if the analyzer attached
        /// no time range, which means this segment cannot be placed on the timeline.
        package let start: TimeInterval?
        package let end: TimeInterval?
        package let confidence: Double?

        package init(text: String, start: TimeInterval?, end: TimeInterval?, confidence: Double?) {
            self.text = text; self.start = start; self.end = end; self.confidence = confidence
        }
    }

    package let speaker: Speaker

    /// Called on the main actor with each finalised segment, as it arrives. Times are
    /// relative to this channel's first sample; the owner aligns channels.
    package var onSegment: (@MainActor (Segment) -> Void)?

    /// Called on the main actor when the ring buffer dropped audio before it could be
    /// read. Positioned in this channel's own timeline.
    package var onGap: (@MainActor (Gap) -> Void)?

    /// Finalised results in order, with timing. The source for `Transcript.merge`.
    package private(set) var segments: [Segment] = []

    /// Confirmed text. Grows; never rewritten.
    package private(set) var finalized: AttributedString = ""
    /// The analyzer's current guess at what is being said right now. Replaced
    /// wholesale on each update, folded into `finalized` once confirmed.
    package private(set) var volatile: AttributedString = ""
    package private(set) var gaps: [Gap] = []

    /// Adds holes found upstream of the ring — a capture stream that stalled and
    /// was padded with silence. Positioned in the same timeline as the ring's own
    /// gaps, because the padding kept that timeline honest.
    package func record(holes: [AudioContinuity.Hole]) {
        gaps.append(contentsOf: holes.map { Gap(at: $0.at, duration: $0.duration) })
        gaps.sort { $0.at < $1.at }
    }
    package private(set) var isRunning = false

    package var text: AttributedString { finalized + volatile }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    /// Pulls timing and confidence out of a finalised result.
    ///
    /// The attributes sit on the individual runs, not the string, so a result spanning
    /// several words carries several ranges. The segment takes the outer bounds and the
    /// mean confidence.
    private static func segment(from text: AttributedString) -> Segment {
        var earliest: TimeInterval?
        var latest: TimeInterval?
        var confidenceTotal = 0.0
        var confidenceCount = 0

        for run in text.runs {
            if let range = run.audioTimeRange {
                let start = range.start.seconds
                let end = range.end.seconds
                if start.isFinite { earliest = earliest.map { Swift.min($0, start) } ?? start }
                if end.isFinite { latest = latest.map { Swift.max($0, end) } ?? end }
            }
            if let confidence = run.transcriptionConfidence {
                confidenceTotal += Double(confidence)
                confidenceCount += 1
            }
        }

        return Segment(
            text: String(text.characters),
            start: earliest,
            end: latest,
            confidence: confidenceCount > 0 ? confidenceTotal / Double(confidenceCount) : nil)
    }

    private let log = Logger(subsystem: "tyto", category: "ChannelTranscriber")

    private let requestedLocale: Locale

    package init(speaker: Speaker, locale: Locale = .current) {
        self.speaker = speaker
        self.requestedLocale = locale
    }
    
    /// Starts draining `ring`. `sampleRate` is `CaptureEngine.sampleRate` — the rate
    /// the IOProc wrote at, which is not necessarily the rate the analyzer wants.
    package func start(draining ring: AudioRingBuffer, sampleRate: Double) async throws {
        
        guard !isRunning else { return }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw Failure.localeUnsupported
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        self.transcriber = transcriber

        try await Self.installModel(for: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw Failure.noAnalyzerFormat
        }

         // Mono, non-interleaved, float — exactly what the ring buffer holds, so a
         // read lands straight in the PCM buffer's channel 0 with no shuffling.
         guard let sourceFormat = AVAudioFormat(
             commonFormat: .pcmFormatFloat32,
             sampleRate: sampleRate,
             channels: 1,
             interleaved: false
         ) else {
             throw Failure.sourceFormatUnavailable
         }
        
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    if result.isFinal {
                        self.finalized += result.text
                        let segment = Self.segment(from: result.text)
                        self.segments.append(segment)
                        self.onSegment?(segment)
                        self.volatile = ""
                    } else {
                        self.volatile = result.text
                    }
                }
            } catch is CancellationError {
                // Expected: cancel() tears this down deliberately.
            } catch {
                guard let self else { return }
                self.log.error("""
                    \(self.speaker.rawValue, privacy: .public) results stream failed: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await analyzer.start(inputSequence: stream)

        // Built outside the Task on purpose: a Task closure captures `self` strongly
        // the moment anything inside it names `self`, nested closures included. Hoisting
        // it means the drain holds exactly one reference to this object, and it's weak.
        let reportGap: @Sendable (TimeInterval, TimeInterval) async -> Void = { [weak self] seconds, duration in
            guard let self else { return }
            await self.record(gapAt: seconds, duration: duration)
        }

        drainTask = Task {
            await RingDrain.run(
                ring: ring,
                from: sourceFormat,
                to: analyzerFormat,
                into: continuation,
                onGap: reportGap
            )
        }
        
        isRunning = true
        log.info("""
            \(self.speaker.rawValue, privacy: .public) transcriber started — \
            \(sampleRate, privacy: .public) Hz → \
            \(analyzerFormat.sampleRate, privacy: .public) Hz, \
            locale \(locale.identifier, privacy: .public)
            """)
        
    }
    
    /// Stops, flushes the audio still sitting in the ring, and folds the last
    /// volatile guess into the transcript. Returns only once the text is complete.
    package func finish() async {
        guard isRunning else { return }
        isRunning = false

        drainTask?.cancel()          // cancellation means "flush, then stop" — see RingDrain
        await drainTask?.value
        drainTask = nil

        continuation?.finish()
        continuation = nil

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value     // let it drain before we read the text
        resultsTask = nil

        if !volatile.characters.isEmpty {
            finalized += volatile
            volatile = ""
        }

        analyzer = nil
        transcriber = nil

        log.info("""
            \(self.speaker.rawValue, privacy: .public) transcriber finished — \
            \(self.finalized.characters.count, privacy: .public) characters, \
            \(self.gaps.count, privacy: .public) gap(s)
            """)
    }
    
    /// Stops without flushing or finalizing — for a session being abandoned rather
    /// than written up. Whatever was mid-conversion is dropped with it.
    package func cancel() {
        drainTask?.cancel()
        resultsTask?.cancel()
        continuation?.finish()

        drainTask = nil
        resultsTask = nil
        continuation = nil
        analyzer = nil
        transcriber = nil
        isRunning = false
    }
    
    isolated deinit {
        drainTask?.cancel()
        resultsTask?.cancel()
        continuation?.finish()
    }

    private func record(gapAt seconds: TimeInterval, duration: TimeInterval) {
        let gap = Gap(at: seconds, duration: duration)
        gaps.append(gap)
        onGap?(gap)
        log.error("""
            \(self.speaker.rawValue, privacy: .public) dropped \
            \(duration, privacy: .public)s at \(seconds, privacy: .public)s — \
            the transcript has a gap here
            """)
    }
    
    /// One place that says how a transcriber is configured, so the model we
    /// pre-install is the model both channels actually run.
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            // Time ranges are measured from this analyzer's first input. Both channels
            // start together, so the two transcripts share one zero and can be
            // interleaved into a single timeline later.
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }
    
    /// Resolves the locale and installs the on-device model if it isn't already.
    ///
    /// Call this *before* starting capture. The ring buffer holds two seconds; a
    /// first-launch model download holds it up for rather longer than that.
    package static func prepareModel(locale requested: Locale = .current) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw Failure.localeUnsupported
        }
        try await installModel(for: makeTranscriber(locale: locale))
    }
    
    /// First run downloads the on-device model for this locale. Both channels use
    /// the same one, so the second call returns immediately.
    private static func installModel(for transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw Failure.localeUnsupported
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) else { return }
            try await request.downloadAndInstall()
        @unknown default:
            throw Failure.modelUnavailable
        }
    }
    
}


// MARK: - Ring buffer → analyzer

/// Moves audio out of a realtime ring buffer and into a `SpeechAnalyzer` input
/// stream.
///
/// This is the async half of the realtime boundary. It allocates, converts, and
/// awaits — none of which the IOProc filling the ring is allowed to do.
private nonisolated enum RingDrain {
    
    /// How often to visit the ring. It holds two seconds, so this leaves an order of
    /// magnitude of headroom over a late wake-up.
    private static let interval = Duration.milliseconds(100)
    /// Ceiling on a single read, so a stall can't provoke one enormous allocation.
    private static let maxChunkFrames = 48_000

    private static let log = Logger(subsystem: "tyto", category: "RingDrain")

    
    /// Runs until cancelled. Cancellation means *flush and stop*: whatever is still
    /// in the ring is delivered before returning, so the tail of the conversation — often
    /// often where someone sums up what was decided — isn't lost.
    static func run(
        ring: AudioRingBuffer,
        from sourceFormat: AVAudioFormat,
        to analyzerFormat: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation,
        onGap: @Sendable @escaping (TimeInterval, TimeInterval) async -> Void
    ) async {
        
        guard let converter = BufferConverter(from: sourceFormat, to: analyzerFormat) else {
            log.error("""
                no converter from \(sourceFormat.description, privacy: .public) to \
                \(analyzerFormat.description, privacy: .public) — this channel is dead
                """)
            continuation.finish()
            return
        }

        var delivered = 0
        var seenDropped = ring.droppedFrames
//        var delivered = 0
        
        while true {
            delivered += emit(from: ring, using: converter,
                              format: sourceFormat, into: continuation)

            let dropped = ring.droppedFrames
            if dropped > seenDropped {
                // Positioned against delivered audio rather than wall clock: the
                // analyzer's timeline is short by exactly the frames that were lost,
                // so this is where the hole lands in the transcript.
                await onGap(Double(delivered) / sourceFormat.sampleRate,
                            Double(dropped - seenDropped) / sourceFormat.sampleRate)
                seenDropped = dropped
            }

            if Task.isCancelled {
                while ring.pendingFrames > 0 {
                    let sent = emit(from: ring, using: converter,
                                    format: sourceFormat, into: continuation)
                    guard sent > 0 else { break }   // converter refusing; don't spin
                    delivered += sent
                }
                return
            }

            try? await Task.sleep(for: interval)
        }
        
    }
    
    /// One read. Returns the frames handed to the analyzer.
    private static func emit(
        from ring: AudioRingBuffer,
        using converter: BufferConverter,
        format: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> Int {
        
        let pending = min(ring.pendingFrames, maxChunkFrames)
        guard pending > 0 else { return 0 }

        // A fresh buffer every time, never a reused scratch one: when the capture and
        // analyzer formats already match, the converter passes the same buffer
        // straight through, and the analyzer still holds it after we return.
        guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(pending)),
              let channel = buffer.floatChannelData?[0] else {
            return 0
        }

        let frames = ring.read(into: channel, maxFrames: pending)
        guard frames > 0 else { return 0 }
        buffer.frameLength = AVAudioFrameCount(frames)
        
        do {
            if let converted = try converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            // nil means the resampler produced no frames this round. Normal.
        } catch {
            log.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        return frames
        
    }
    
}
