//
//  AudioContinuity.swift
//  tyto
//

import Darwin
import Foundation
import Synchronization

/// Detects holes in a capture stream by host time, so lost audio can be filled and
/// recorded rather than silently closed up.
///
/// A tap that stops and resumes leaves no trace in the samples: the buffer after the
/// hole follows the one before it as if nothing happened. `SpeechAnalyzer` timestamps
/// against the audio it was fed, so an unfilled hole doesn't leave a space in the
/// transcript — it shifts everything after it earlier, permanently, and the shift
/// accumulates. Ten engine restarts in one session is ten compounding errors, which
/// is why the local speaker's words landed two seconds before the remote side's echo of them.
///
/// Host time is the only continuous reference available: it keeps running while the
/// engine is stopped, and sample counts do not.
package nonisolated final class AudioContinuity: @unchecked Sendable {

    package struct Hole: Sendable {
        /// Seconds into this channel's audio, counting the silence inserted for
        /// earlier holes — so it matches the analyzer's timeline.
        package let at: TimeInterval
        package let duration: TimeInterval
    }

    /// Below this, a late buffer is scheduling jitter rather than lost audio. One
    /// tap interval at 4096 frames / 44100 Hz is ~93 ms; half that is comfortably
    /// above jitter and well below anything a listener would notice.
    private static let threshold: TimeInterval = 0.05

    /// Fixed capacity, preallocated: this is written from the audio thread, where
    /// allocation is forbidden. A session with more holes than this has problems
    /// that a longer list would not help with.
    private static let capacity = 128

    private let sampleRate: Double
    private let holes: UnsafeMutablePointer<Hole>
    private let count = Atomic<Int>(0)
    private let lostFrames = Atomic<Int>(0)

    /// Audio-thread only. No atomics needed: one writer, never read from elsewhere.
    private var nextExpectedHostTime: UInt64 = 0
    private var framesWritten = 0

    private static var secondsPerTick: Double { HostClock.secondsPerTick }

    /// Host time of the first buffer, so this channel's audio can be placed against
    /// another channel's. Each analyzer counts from its own first sample, and the two
    /// streams do not start together.
    package let origin = StreamOrigin()

    package init(sampleRate: Double) {
        self.sampleRate = sampleRate
        holes = UnsafeMutablePointer<Hole>.allocate(capacity: Self.capacity)
    }

    deinit { holes.deallocate() }

    /// Called from the audio thread for every buffer. Returns how many frames of
    /// silence to insert *before* this buffer to keep the stream continuous.
    ///
    /// Realtime-safe: no allocation, no locks, no logging.
    package func silenceNeeded(hostTime: UInt64, frames: Int) -> Int {
        origin.noteIfFirst(hostTime)
        defer {
            framesWritten += frames
            nextExpectedHostTime = hostTime
                + UInt64(Double(frames) / sampleRate / Self.secondsPerTick)
        }

        // First buffer establishes the origin; there is nothing to be late relative to.
        guard nextExpectedHostTime != 0, hostTime > nextExpectedHostTime else { return 0 }

        let late = Double(hostTime - nextExpectedHostTime) * Self.secondsPerTick
        guard late >= Self.threshold else { return 0 }

        let missing = Int(late * sampleRate)
        let index = count.load(ordering: .relaxed)
        if index < Self.capacity {
            holes[index] = Hole(at: Double(framesWritten) / sampleRate, duration: late)
            count.store(index + 1, ordering: .releasing)
        }
        lostFrames.wrappingAdd(missing, ordering: .relaxed)
        framesWritten += missing
        return missing
    }

    package var recorded: [Hole] {
        let total = count.load(ordering: .acquiring)
        return (0..<total).map { holes[$0] }
    }

    package var lostSeconds: TimeInterval {
        Double(lostFrames.load(ordering: .relaxed)) / sampleRate
    }

    package func reset() {
        count.store(0, ordering: .relaxed)
        lostFrames.store(0, ordering: .relaxed)
        nextExpectedHostTime = 0
        framesWritten = 0
    }
}


/// Mach host time, which keeps running when audio does not.
package nonisolated enum HostClock {
    package static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Seconds from `start` to `end`, negative if `end` came first.
    package static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        end >= start
            ? Double(end - start) * secondsPerTick
            : -Double(start - end) * secondsPerTick
    }
}

/// The host time of a stream's first buffer, recorded once.
///
/// Two capture paths start milliseconds apart and each analyzer timestamps from its
/// own first sample, so without a shared origin the two transcripts are offset by an
/// unknown constant — enough to put an echo *before* the words that caused it.
package nonisolated final class StreamOrigin: Sendable {
    private let hostTime = Atomic<UInt64>(0)

    /// Realtime-safe, and only the first call has any effect.
    package func noteIfFirst(_ time: UInt64) {
        guard time != 0 else { return }
        _ = hostTime.compareExchange(expected: 0, desired: time,
                                     successOrdering: .relaxed, failureOrdering: .relaxed)
    }

    package var value: UInt64? {
        let time = hostTime.load(ordering: .relaxed)
        return time == 0 ? nil : time
    }
}
