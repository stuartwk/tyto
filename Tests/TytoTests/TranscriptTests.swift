//
//  TranscriptTests.swift
//  TytoTests
//

import Testing
@testable import Tyto

/// Merging and bleed detection, exercised without audio.
///
/// These are the failures a recorded conversation is worst at finding: they need specific
/// timings and specific word overlaps, and reproducing one by talking takes minutes
/// and may not reproduce at all. Every case here came from a real recording or from a
/// property the app must not violate.
struct TranscriptTests {

    private func segment(_ text: String, _ start: Double, _ end: Double,
                         confidence: Double? = nil) -> ChannelTranscriber.Segment {
        ChannelTranscriber.Segment(text: text, start: start, end: end, confidence: confidence)
    }

    // MARK: Merging

    @Test func interleavesChannelsByTime() {
        let transcript = Transcript.merge([
            .init(speaker: .local, segments: [segment("first", 0, 1), segment("third", 10, 11)]),
            .init(speaker: .remote, segments: [segment("second", 5, 6)]),
        ])

        #expect(transcript.turns.map(\.text) == ["first", "second", "third"])
        #expect(transcript.turns.map(\.speaker) == [.local, .remote, .local])
    }

    @Test func coalescesSegmentsSeparatedByShortSilence() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment("Hello there", 0, 2), segment("how are you", 2.5, 4)]),
        ])

        #expect(transcript.turns.count == 1)
        #expect(transcript.turns[0].text == "Hello there how are you")
        #expect(transcript.turns[0].end == 4)
    }

    @Test func splitsSegmentsSeparatedByLongSilence() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment("Hello there", 0, 2), segment("Sorry, I was thinking", 30, 32)]),
        ])

        #expect(transcript.turns.count == 2)
    }

    /// A segment the analyzer gave no time range cannot be placed on the timeline.
    /// It must not be positioned by guesswork — an invented ordering in a
    /// transcript is worse than an admitted one.
    @Test func untimedSegmentJoinsTheCurrentTurnRatherThanBeingPlaced() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [
                segment("I was saying", 0, 2),
                ChannelTranscriber.Segment(text: "and then", start: nil, end: nil, confidence: nil),
            ]),
        ])

        #expect(transcript.turns.count == 1)
        #expect(transcript.turns[0].text == "I was saying and then")
    }

    @Test func emptyChannelsProduceAnEmptyTranscript() {
        #expect(Transcript.merge([Transcript.Source]()).isEmpty)
        #expect(Transcript.merge([.init(speaker: .remote, segments: [])]).isEmpty)
    }

    // MARK: Bleed
    //
    // The fixture is verbatim from a real recording on 2026-08-31: a James Baldwin
    // interview playing on speakers while the local channel picked up a degraded
    // copy through the microphone, 25-30 dB down and still transcribable.

    @Test func flagsResidualEchoInTheNearChannel() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment(
                "when the Holocaust comes, and it will come, you know, eventually, no matter "
                + "how simple black and white terms may be today", 10, 20, confidence: 0.9)]),
            .init(speaker: .local, segments: [segment(
                "So they will win the Holocaust. Eventually, eventually.", 11, 18, confidence: 0.4)]),
        ])

        let flagged = transcript.suspectedBleed()
        let localTurn = try! #require(transcript.turns.first { $0.speaker == .local })
        let remoteTurn = try! #require(transcript.turns.first { $0.speaker == .remote })

        #expect(flagged.contains(localTurn.id))
        // The clean original must never be flagged — that would move the real speech
        // out of the way and leave the echo standing.
        #expect(!flagged.contains(remoteTurn.id))
    }

    @Test func doesNotFlagTurnsThatMerelySharePlainWords() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment("I think about my mother sometimes", 0, 5, confidence: 0.9)]),
            .init(speaker: .local, segments: [segment("Tell me about school instead", 1, 4, confidence: 0.9)]),
        ])

        #expect(transcript.suspectedBleed().isEmpty)
    }

    @Test func doesNotFlagWhenTurnsDoNotOverlapInTime() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment("the Holocaust, eventually, terrible", 0, 5, confidence: 0.9)]),
            .init(speaker: .local, segments: [segment("the Holocaust, eventually, terrible", 60, 65, confidence: 0.4)]),
        ])

        #expect(transcript.suspectedBleed().isEmpty)
    }

    /// Reflecting the other side's words back is ordinary conversation, and it looks
    /// exactly like echo to this heuristic. The tie-break is confidence: genuine
    /// speech is decoded cleanly, residual echo is not.
    @Test func doesNotFlagAConfidentLocalSpeakerReflectingTheRemote() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment(
                "everything feels completely overwhelming lately", 0, 5, confidence: 0.85)]),
            .init(speaker: .local, segments: [segment(
                "everything feels completely overwhelming, you said", 3, 8, confidence: 0.95)]),
        ])

        #expect(transcript.suspectedBleed().isEmpty)
    }

    // MARK: Export

    @Test func plainTextMarksFlaggedTurnsRatherThanRemovingThem() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment(
                "when the Holocaust comes, eventually, no matter how simple", 10, 20, confidence: 0.9)]),
            .init(speaker: .local, segments: [segment(
                "So they will win the Holocaust. Eventually, eventually.", 11, 18, confidence: 0.4)]),
        ])
        let flagged = transcript.suspectedBleed()
        let text = transcript.plainText(flagging: flagged)

        #expect(text.contains("[0:11]"))
        #expect(text.contains("may be the other speaker"))
        // Present, not deleted: the app does not decide what was said.
        #expect(text.contains("So they will win the Holocaust"))
    }
}

/// Holes in the captured audio, which are the whole reason `Gap` exists: the text
/// either side of lost audio reads as continuous speech, and a note written from it
/// would inherit that false continuity silently.
struct TranscriptHoleTests {

    private func segment(_ text: String, _ start: Double, _ end: Double) -> ChannelTranscriber.Segment {
        ChannelTranscriber.Segment(text: text, start: start, end: end, confidence: 0.9)
    }

    private func hole(_ at: Double, _ duration: Double) -> ChannelTranscriber.Gap {
        ChannelTranscriber.Gap(at: at, duration: duration)
    }

    @Test func holesLandBetweenTheTurnsTheyInterrupt() {
        let transcript = Transcript.merge([
            .init(speaker: .local,
                  segments: [segment("before the hole", 0, 5), segment("after the hole", 20, 25)],
                  gaps: [hole(12, 0.4)]),
        ])

        let order = transcript.entries.map { entry -> String in
            switch entry {
            case .turn(let turn): turn.text
            case .hole: "HOLE"
            }
        }
        #expect(order == ["before the hole", "HOLE", "after the hole"])
    }

    @Test func lostAudioSumsEveryHole() {
        let transcript = Transcript.merge([
            .init(speaker: .local, segments: [segment("hello", 0, 1)],
                  gaps: [hole(2, 0.4), hole(9, 1.1)]),
            .init(speaker: .remote, segments: [segment("hi", 3, 4)], gaps: [hole(5, 0.5)]),
        ])

        #expect(abs(transcript.lostAudio - 2.0) < 0.0001)
    }

    /// The exported copy is what gets pasted into a chart. If the admission only
    /// exists on screen, it does not exist where it matters.
    @Test func exportedTextAdmitsTheHole() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment("I was saying", 0, 5)],
                  gaps: [hole(7, 0.6)]),
        ])
        let text = transcript.plainText()

        #expect(text.contains("not captured"))
        #expect(text.contains("0.6s"))
    }

    @Test func aTranscriptWithNoHolesClaimsNoLostAudio() {
        let transcript = Transcript.merge([
            .init(speaker: .remote, segments: [segment("all present", 0, 5)]),
        ])
        #expect(transcript.lostAudio == 0)
        #expect(transcript.entries.count == 1)
        #expect(!transcript.plainText().contains("not captured"))
    }
}

/// Residual echo as it actually appears, taken verbatim from recordings on 2026-08-31.
///
/// An adaptive canceller needs a few hundred milliseconds to converge on a new echo
/// path, so what leaks is the *opening* of the far speaker's turn and nothing after.
/// Every fragment here is too short to contain two distinctive words, which is why
/// word-overlap alone never saw them.
struct ConvergenceLeakTests {

    private func segment(_ text: String, _ start: Double, _ end: Double,
                         confidence: Double? = 0.5) -> ChannelTranscriber.Segment {
        ChannelTranscriber.Segment(text: text, start: start, end: end, confidence: confidence)
    }

    /// `localConfidence` defaults low because that is what leaked echo looks like:
    /// the recognizer guessing at something 25-30 dB down. Genuine speech comes back
    /// high, and tests about genuine speech must say so — supplying 0.5 for a turn the
    /// local really spoke would be handing the detector the exact signal that
    /// means "this was badly decoded" and then objecting when it believes it.
    private func transcript(local: (String, Double, Double),
                            remote: (String, Double, Double),
                            localConfidence: Double = 0.5) -> Transcript {
        Transcript.merge([
            .init(speaker: .local,
                  segments: [segment(local.0, local.1, local.2,
                                     confidence: localConfidence)]),
            .init(speaker: .remote,
                  segments: [segment(remote.0, remote.1, remote.2, confidence: 0.9)]),
        ])
    }

    @Test func flagsTheOpeningWordsOfARemoteTurnLeakingIntoTheLocalChannel() {
        let merged = transcript(
            local: ("If you're looking for some.", 9, 10),
            remote: ("If you're looking for some quick and easy lunch ideas, you could try "
                     + "making a chickpea salad sandwich.", 10, 27))

        let flagged = merged.suspectedBleed()
        let leak = try! #require(merged.turns.first { $0.speaker == .local })
        let real = try! #require(merged.turns.first { $0.speaker == .remote })
        #expect(flagged.contains(leak.id))
        #expect(!flagged.contains(real.id))
    }

    @Test func flagsAFragmentCutMidWord() {
        let merged = transcript(
            local: ("To make a class.", 56, 57),
            remote: ("To make a classic cucumber sandwich, you will need a few simple "
                     + "ingredients.", 56, 75))
        #expect(merged.suspectedBleed().count == 1)
    }

    /// Too short to be evidence. "If you." opens an enormous number of sentences, and
    /// flagging on it would train the local to ignore the flag.
    @Test func ignoresFragmentsTooShortToMeanAnything() {
        let merged = transcript(
            local: ("If you.", 164, 165),
            remote: ("If you are shopping at a Japanese grocery store, Shokupan is the "
                     + "best choice.", 164, 180))
        #expect(merged.suspectedBleed().isEmpty)
    }

    /// Agreeing with someone is not echo. The local repeating a phrase that merely
    /// *starts* the same way, at comparable length, is ordinary conversation.
    @Test func doesNotFlagAComparablyLongTurnThatMerelyStartsAlike() {
        let merged = transcript(
            local: ("I think that sounds like a really good plan for you", 10, 15),
            remote: ("I think that sounds like a really good plan, yes", 10, 16),
            localConfidence: 0.9)
        #expect(merged.suspectedBleed().isEmpty)
    }

    /// The channels start milliseconds apart and each analyzer counts from its own
    /// first sample. Without a shared origin the echo lands *before* the words that
    /// caused it and no overlap rule can see it.
    @Test func channelOffsetsPlaceBothChannelsOnOneTimeline() {
        let merged = Transcript.merge([
            .init(speaker: .local, segments: [segment("second", 0, 1)], offset: 10),
            .init(speaker: .remote, segments: [segment("first", 5, 6)], offset: 0),
        ])
        #expect(merged.turns.map(\.text) == ["first", "second"])
        #expect(merged.turns[1].start == 10)
    }
}

/// Holes cluster: one interruption often shows up as two or three nearby drops. Ten
/// markers in a three-minute transcript stops being information and starts being
/// wallpaper, so nearby holes merge — without changing how much audio was lost.
struct HoleCoalescingTests {

    private func gap(_ at: Double, _ duration: Double) -> ChannelTranscriber.Gap {
        ChannelTranscriber.Gap(at: at, duration: duration)
    }

    @Test func nearbyHolesInTheSameChannelBecomeOne() {
        let transcript = Transcript.merge([
            .init(speaker: .local, segments: [], gaps: [gap(34, 0.4), gap(36, 0.3)]),
        ])
        #expect(transcript.holes.count == 1)
        #expect(transcript.holes[0].at == 34)
    }

    @Test func coalescingPreservesTotalLostAudio() {
        let scattered = Transcript.merge([
            .init(speaker: .local, segments: [],
                  gaps: [gap(30, 0.4), gap(34, 0.4), gap(36, 0.3)]),
        ])
        // 0.4 + 0.4 + 0.3, whether they appear as three markers or one. Merging must
        // not span the audio between holes, which was captured fine.
        #expect(abs(scattered.lostAudio - 1.1) < 0.0001)
    }

    @Test func distantHolesStaySeparate() {
        let transcript = Transcript.merge([
            .init(speaker: .local, segments: [], gaps: [gap(10, 0.3), gap(90, 0.3)]),
        ])
        #expect(transcript.holes.count == 2)
    }

    /// Two channels lose audio independently; merging across them would attribute one
    /// channel's loss to the other.
    @Test func holesInDifferentChannelsNeverMerge() {
        let transcript = Transcript.merge([
            .init(speaker: .local, segments: [], gaps: [gap(10, 0.3)]),
            .init(speaker: .remote, segments: [], gaps: [gap(11, 0.3)]),
        ])
        #expect(transcript.holes.count == 2)
    }
}

/// The pairwise judgement live flagging relies on. It has to be directional: the
/// echo is flagged as bleed of its source, never the source as bleed of its echo.
struct LiveBleedTests {

    // Verbatim from a tyto run on 2026-11-26: `say` through the speakers, with voice
    // processing on, still leaked the end of the sentence into the local channel.
    private let source = Turn(speaker: .remote, text: "This sentence should survive the interrupt.",
                              start: 5.34, end: 7.8, confidence: 0.919)
    private let echo = Turn(speaker: .local, text: "Should survive.",
                            start: 6.26, end: 8.0, confidence: 0.385)

    @Test func flagsTheEchoAsBleedOfItsSource() {
        #expect(Transcript.looksLikeBleed(echo, of: source))
    }

    @Test func neverFlagsTheSourceAsBleedOfItsEcho() {
        #expect(!Transcript.looksLikeBleed(source, of: echo))
    }

    @Test func neverComparesAChannelWithItself() {
        let sameSide = Turn(speaker: .remote, text: echo.text, start: echo.start,
                            end: echo.end, confidence: echo.confidence)
        #expect(!Transcript.looksLikeBleed(sameSide, of: source))
    }
}
