//
//  Transcript.swift
//  tyto
//

import CoreMedia
import Foundation

/// Which side of the conversation a channel carries. Attribution comes from where the
/// audio was captured, never from guessing at voices.
public enum Speaker: String, Sendable, CaseIterable, Codable {
    /// This Mac's microphone: the person using it.
    case local
    /// Other apps' audio: whoever is on the other end of the call.
    case remote

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        }
    }
}

/// One speaker's uninterrupted stretch of speech, placed on the session timeline.
public struct Turn: Identifiable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    /// Seconds from the start of this channel's delivered audio.
    public let start: TimeInterval
    public let end: TimeInterval
    /// Mean transcription confidence across the runs that formed this turn, when the
    /// analyzer reported it. Low confidence is the recognizer telling us it was
    /// guessing — which is what residual echo sounds like to it.
    public let confidence: Double?

    public var duration: TimeInterval { max(0, end - start) }

    init(id: UUID = UUID(), speaker: Speaker, text: String, start: TimeInterval,
         end: TimeInterval, confidence: Double?) {
        self.id = id; self.speaker = speaker; self.text = text
        self.start = start; self.end = end; self.confidence = confidence
    }

    public func overlaps(_ other: Turn, tolerance: TimeInterval = 0) -> Bool {
        start - tolerance < other.end && other.start - tolerance < end
    }
}

/// Both channels on one timeline.
///
/// A plain value: tyto never persists a transcript itself. What happens to it is the
/// caller's decision.
public struct Transcript: Sendable {

    /// A hole in one channel's audio, placed on the session timeline.
    ///
    /// Carried all the way to the reader rather than kept in a log. The text either
    /// side of a hole reads as continuous speech, and a note written from it would
    /// inherit that false continuity without anyone being able to notice.
    public struct Hole: Identifiable, Sendable {
        public let id = UUID()
        public let speaker: Speaker
        public let at: TimeInterval
        public let duration: TimeInterval
    }

    /// Anything on the timeline, in order — what a reader actually needs.
    public enum Entry: Identifiable, Sendable {
        case turn(Turn)
        case hole(Hole)

        public var id: UUID {
            switch self {
            case .turn(let turn): turn.id
            case .hole(let hole): hole.id
            }
        }
        public var at: TimeInterval {
            switch self {
            case .turn(let turn): turn.start
            case .hole(let hole): hole.at
            }
        }
    }

    public var turns: [Turn]

    /// Holes in the captured audio, carried through from the channels so a note built
    /// on this can say what it didn't hear rather than presenting a splice as speech.
    public var holes: [Hole]

    public static let empty = Transcript(turns: [], holes: [])

    /// Turns and holes interleaved by time.
    public var entries: [Entry] {
        (turns.map(Entry.turn) + holes.map(Entry.hole)).sorted { $0.at < $1.at }
    }

    /// Audio the conversation lost. Anything built on this transcript should surface it.
    public var lostAudio: TimeInterval { holes.reduce(0) { $0 + $1.duration } }

    public var isEmpty: Bool { turns.isEmpty }

    /// Interleaves both channels into one time-ordered sequence.
    ///
    /// Segments arrive per channel, each carrying the time range the analyzer assigned
    /// it. Consecutive segments from the same speaker are coalesced when the silence
    /// between them is short, so a turn is a stretch of speech rather than whatever
    /// the analyzer happened to finalise in one go.
    /// `@MainActor` because it reads live channel state. The real work is in the
    /// `Source` overload, which takes plain values and can be tested without a running
    /// analyzer.
    @MainActor
    package static func merge(_ channels: [ChannelTranscriber],
                      coalescingGapsUnder threshold: TimeInterval = 1.5) -> Transcript {
        merge(channels.map {
            Source(speaker: $0.speaker, segments: $0.segments, gaps: $0.gaps)
        }, coalescingGapsUnder: threshold)
    }

    /// One channel's finalised output, detached from the object that produced it.
    ///
    /// Exists so merging can be tested against fixtures. Every interesting failure in
    /// this file — ordering, coalescing, bleed — is a failure of text handling, and
    /// needing a microphone to exercise it would mean never exercising it.
    package struct Source: Sendable {
        package let speaker: Speaker
        package let segments: [ChannelTranscriber.Segment]
        package var gaps: [ChannelTranscriber.Gap] = []
        /// Seconds between the session's start and this channel's first sample.
        ///
        /// Each analyzer counts from its own first buffer, and the two capture paths
        /// start milliseconds apart. Without this the channels are offset by an unknown
        /// constant — enough to place an echo *before* the words that produced it,
        /// which is how residual echo escaped detection entirely.
        package var offset: TimeInterval = 0

        package init(speaker: Speaker, segments: [ChannelTranscriber.Segment],
                     gaps: [ChannelTranscriber.Gap] = [], offset: TimeInterval = 0) {
            self.speaker = speaker; self.segments = segments
            self.gaps = gaps; self.offset = offset
        }
    }

    package static func merge(_ sources: [Source],
                      coalescingGapsUnder threshold: TimeInterval = 1.5) -> Transcript {
        var turns: [Turn] = []

        for channel in sources {
            var pending: (text: String, start: TimeInterval, end: TimeInterval,
                          confidenceTotal: Double, confidenceCount: Int)?

            func flush() {
                guard let current = pending else { return }
                let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    turns.append(Turn(
                        speaker: channel.speaker,
                        text: text,
                        start: current.start,
                        end: current.end,
                        confidence: current.confidenceCount > 0
                            ? current.confidenceTotal / Double(current.confidenceCount)
                            : nil))
                }
                pending = nil
            }

            for segment in channel.segments {
                guard let rawStart = segment.start, let rawEnd = segment.end else {
                    // No timing means it cannot be placed on the timeline. Appending it
                    // to whatever came last would fabricate an ordering, so it joins the
                    // current turn and stops there.
                    if pending != nil { pending?.text += " " + segment.text }
                    continue
                }
                let start = rawStart + channel.offset, end = rawEnd + channel.offset
                if let current = pending, start - current.end <= threshold {
                    pending?.text += " " + segment.text
                    pending?.end = end
                    if let confidence = segment.confidence {
                        pending?.confidenceTotal += confidence
                        pending?.confidenceCount += 1
                    }
                } else {
                    flush()
                    pending = (segment.text, start, end,
                               segment.confidence ?? 0, segment.confidence == nil ? 0 : 1)
                }
            }
            flush()
        }

        turns.sort { $0.start < $1.start }
        let holes = sources.flatMap { source in
            source.gaps.map {
                Hole(speaker: source.speaker, at: $0.at + source.offset, duration: $0.duration)
            }
        }
        return Transcript(turns: turns, holes: coalesce(holes.sorted { $0.at < $1.at }))
    }

    /// Plain text, timestamped, one turn per paragraph.
    ///
    /// Flagged turns are marked inline rather than omitted: tyto does not decide what
    /// was said, and a transcript that silently drops material is worse than one that
    /// admits uncertainty.
    public func plainText(flagging suspected: Set<Turn.ID> = []) -> String {
        entries.map { entry in
            let stamp = String(format: "%d:%02d", Int(entry.at) / 60, Int(entry.at) % 60)
            switch entry {
            case .turn(let turn):
                let note = suspected.contains(turn.id) ? "  [may be the other speaker]" : ""
                return "[\(stamp)] \(turn.speaker.displayName)\(note)\n\(turn.text)"
            case .hole(let hole):
                // Marked in the exported text, not just on screen: the copy someone
                // pastes elsewhere must carry the same admission.
                return String(format: "[%@] — %.1fs of %@ audio was not captured —",
                              stamp, hole.duration, hole.speaker.displayName.lowercased())
            }
        }
        .joined(separator: "\n\n")
    }

    /// Merges holes that land close together into one.
    ///
    /// A session can lose the same three seconds as ten separate 0.3s holes or as a
    /// handful of longer ones, and ten markers in a three-minute transcript is enough
    /// visual noise to make a reader stop seeing them. Nothing is hidden: durations
    /// add up, and `lostAudio` is unchanged either way. The point of the marker is
    /// that someone notices it.
    private static func coalesce(_ holes: [Hole],
                                 within window: TimeInterval = 3) -> [Hole] {
        var merged: [Hole] = []
        for hole in holes {
            guard let last = merged.last,
                  last.speaker == hole.speaker,
                  hole.at - (last.at + last.duration) <= window else {
                merged.append(hole)
                continue
            }
            // The sum of what was lost, not the span between the first and last hole:
            // the audio between two nearby holes was captured perfectly well, and
            // claiming it as missing overstates the damage. Coalescing changes how many
            // markers appear, never how much audio the transcript admits losing.
            merged[merged.count - 1] = Hole(
                speaker: last.speaker,
                at: last.at,
                duration: last.duration + hole.duration)
        }
        return merged
    }

    // MARK: Bleed

    /// Turns that look like the other speaker's words leaking into this channel.
    ///
    /// Echo cancellation removes 25–30 dB, not everything, so on speakers the far end
    /// can still reach the near microphone quietly enough to be mangled and loudly
    /// enough to be transcribed. Observed directly: while the remote side said
    /// *"when the Holocaust comes, and it will come… eventually"*, the local channel
    /// produced *"So they will win the Holocaust. Eventually, eventually."*
    ///
    /// That is the signature — same moment, same distinctive words, one version
    /// fluent and one degraded. Detected here rather than in audio because by the time
    /// it reaches text it is a text problem, and because no audio measurement can tell
    /// residual echo from someone genuinely repeating the other side.
    ///
    /// This flags for *review*; it never deletes and never decides. Quoting the other
    /// person back to them is normal conversation, and an earlier version of this
    /// flagged the *original* speaker in that situation — see
    /// TranscriptTests.doesNotFlagAConfidentLocalSpeakerReflectingTheRemote.
    public func suspectedBleed() -> Set<Turn.ID> {
        var flagged: Set<Turn.ID> = []
        for turn in turns where turns.contains(where: { Self.looksLikeBleed(turn, of: $0) }) {
            flagged.insert(turn.id)
        }
        return flagged
    }

    /// Whether `turn` looks like `other`'s words leaking into `turn`'s channel.
    ///
    /// Pairwise so the same judgement runs live, as segments arrive, and over a
    /// finished transcript.
    static func looksLikeBleed(_ turn: Turn, of other: Turn,
                               minimumSimilarity: Double = 0.3,
                               minimumSharedWords: Int = 2,
                               minimumContainment: Double = 0.8,
                               maximumConfidence: Double = 0.6) -> Bool {
        // A small tolerance rather than strict overlap: the echo of a turn's first
        // words is finalised by one analyzer slightly before the other finalises the
        // turn itself, so the two can just miss touching.
        guard other.speaker != turn.speaker,
              other.overlaps(turn, tolerance: 2),
              turn.duration > 0 else { return false }

        // Convergence leakage: a short fragment that is literally the start of what
        // the other speaker said. Checked before the word-overlap rule because these
        // fragments are too short for that rule to see.
        let mine = distinctiveWords(turn.text)
        guard !mine.isEmpty else { return false }
        if isOpening(turn.text, of: other.text) { return true }

        let theirs = distinctiveWords(other.text)
        guard !theirs.isEmpty else { return false }

        // Two shared words minimum: a single common word makes any two English
        // sentences look related, and "about" is not evidence of anything.
        let shared = mine.intersection(theirs).count
        guard shared >= minimumSharedWords else { return false }
        let similarity = Double(shared) / Double(min(mine.count, theirs.count))
        guard similarity >= minimumSimilarity else { return false }

        // Echo exists only while the source is playing, so a leaked turn is almost
        // entirely inside the turn that produced it. Someone reflecting the other
        // side's words back starts late and runs past the end, and that difference
        // is what separates the two.
        let overlap = min(turn.end, other.end) - max(turn.start, other.start)
        guard overlap / turn.duration >= minimumContainment else { return false }

        // Absolute, not relative. Comparing confidences alone flags whichever side
        // is less certain, which in a reflection is the original speaker — their own
        // speech marked as an artifact. Residual echo is genuinely badly decoded, so
        // require that it actually is.
        if let mineConfidence = turn.confidence {
            return mineConfidence < maximumConfidence
                && mineConfidence < (other.confidence ?? 1)
        }
        return turn.text.count < other.text.count / 2
    }

    /// Whether `fragment` is the opening of `full` — the shape residual echo takes
    /// when an adaptive canceller has not yet converged.
    ///
    /// Observed repeatedly: the near channel catches the first words of a far turn and
    /// nothing after, because the filter adapts within a few hundred milliseconds.
    /// "If you're looking for some" against "If you're looking for some quick and easy
    /// lunch ideas"; "To make a class" against "To make a classic cucumber sandwich".
    ///
    /// Word-overlap cannot catch these — the fragments are too short to contain two
    /// distinctive words — but a prefix match catches them exactly, and a person
    /// happening to utter the precise opening of what the other is simultaneously
    /// saying is rare enough to be worth flagging when it does occur.
    private static func isOpening(_ fragment: String, of full: String) -> Bool {
        let short = normalized(fragment)
        let long = normalized(full)
        // Long enough not to match on "I" or "so", and clearly a fragment rather than
        // a paraphrase of comparable length.
        guard short.count >= 8, short.count * 2 <= long.count else { return false }
        return long.hasPrefix(short)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// Words long enough to be worth matching on. Short words are shared by every
    /// pair of English sentences and would make any two turns look alike.
    private static func distinctiveWords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .filter { $0.count >= 5 }
            .map(String.init))
    }
}
