import Foundation
import Tyto

/// `tyto listen`: transcribe the microphone and other apps' audio as two channels,
/// writing each finalised segment to stdout as it arrives.
///
/// JSON Lines by default, one object per line, so the output can be piped into
/// anything. Status and errors go to stderr, keeping stdout machine-readable.
/// Segments arrive per channel as each analyzer finalises them, so lines are not
/// strictly time-ordered across speakers; sort by `start` if that matters.
@MainActor
enum Listen {

    enum Format: String { case jsonl, text }

    static func run(appBundleID: String?, seconds: Int?, format: Format) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when piped

        let session = TranscriptionSession(source: appBundleID.map { .app(bundleID: $0) } ?? .allApps)
        do {
            status("preparing the speech model (downloads on first run)…")
            try await TranscriptionSession.prepare()
            try await session.start()
        } catch {
            status("error: \(error.localizedDescription)")
            return 1
        }

        switch session.echoCancellation {
        case .unavailable(let reason):
            status("listening — echo cancellation OFF (\(reason)): on speakers, the remote side may also appear as local")
        default:
            status("listening — echo cancellation on")
        }
        if let appBundleID, !AudioApps.running().contains(where: { $0.bundleID.hasPrefix(appBundleID) || appBundleID.hasPrefix($0.bundleID) }) {
            status("\(appBundleID) isn't running; waiting for it (see `tyto apps` for bundle IDs)")
        }
        status(seconds.map { "stopping after \($0)s, or press Ctrl-C" } ?? "press Ctrl-C to stop")

        let printer = Task { @MainActor in
            for await event in session.events { emit(event, format: format) }
        }

        await waitForStop(seconds: seconds)
        status("finishing — flushing buffered audio…")
        let transcript = await session.stop()
        await printer.value

        if format == .jsonl {
            write(Line(type: "end", turns: transcript.turns.count,
                       lostAudio: rounded(transcript.lostAudio),
                       echoCancellation: session.echoCancellation == .active))
        }
        if transcript.lostAudio > 0 {
            status(String(format: "%.1fs of audio was lost and is missing from the transcript", transcript.lostAudio))
        }
        return 0
    }

    // MARK: Output

    /// One line of JSON output. Optional fields are omitted rather than null.
    private struct Line: Encodable {
        var type: String
        var id: String?
        var speaker: String?
        var text: String?
        var start: Double?
        var end: Double?
        var confidence: Double?
        var at: Double?
        var duration: Double?
        var turns: Int?
        var lostAudio: Double?
        var echoCancellation: Bool?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Segment ids are shortened to eight hex digits: unique enough within one
    /// session, and short enough to read.
    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private static func emit(_ event: TranscriptionEvent, format: Format) {
        switch (event, format) {
        case let (.segment(segment), .jsonl):
            write(Line(type: "segment", id: shortID(segment.id), speaker: segment.speaker.rawValue,
                       text: segment.text, start: segment.start.map(rounded),
                       end: segment.end.map(rounded), confidence: segment.confidence.map(rounded)))
        case let (.gap(speaker, at, duration), .jsonl):
            write(Line(type: "gap", speaker: speaker.rawValue,
                       at: rounded(at), duration: rounded(duration)))
        case let (.suspectedBleed(id), .jsonl):
            write(Line(type: "suspected_bleed", id: shortID(id)))
        case let (.warning(warning), _):
            status("warning: \(describe(warning))")
        case let (.sourceProcessesChanged(count), _):
            status(count == 0
                   ? "waiting for the app to open audio…"
                   : "capturing the app (\(count) process\(count == 1 ? "" : "es"))")
        case let (.segment(segment), .text):
            print("[\(timestamp(segment.start))] \(segment.speaker.displayName): \(segment.text)")
        case let (.gap(speaker, at, duration), .text):
            print(String(format: "[%@] — %.1fs of %@ audio was not captured —",
                         timestamp(at), duration, speaker.displayName.lowercased()))
        case (.suspectedBleed, .text):
            // Text mode has already printed the line; say so, without pretending to
            // know which one beyond its id.
            print("        (the previous lines may include echo of the other speaker)")
        }
    }

    private static func describe(_ warning: TranscriptionWarning) -> String {
        switch warning {
        case .microphoneSilent:
            "the microphone is delivering digital silence; macOS may have denied microphone access to your terminal app"
        case .microphoneNotDelivering:
            "the microphone has delivered no audio"
        }
    }

    private static func write(_ line: Line) {
        guard let data = try? encoder.encode(line) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    private static func timestamp(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "--:--" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    static func status(_ message: String) {
        FileHandle.standardError.write(Data("tyto: \(message)\n".utf8))
    }

    // MARK: Stopping

    /// Returns on Ctrl-C, or after `seconds` when given.
    private static func waitForStop(seconds: Int?) async {
        signal(SIGINT, SIG_IGN)   // let the dispatch source see it instead of dying
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resume = { @MainActor in
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            source.setEventHandler { MainActor.assumeIsolated { resume() } }
            source.resume()
            if let seconds {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    resume()
                }
            }
        }
        source.cancel()
        signal(SIGINT, SIG_DFL)   // a second Ctrl-C during the flush quits immediately
    }
}
