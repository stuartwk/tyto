//
//  ChannelMeter.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/6/26.
//

import Foundation
import Synchronization

/// Lock-free level metering: the IOProc writes, the UI reads.
///
/// Everything here is atomic because the writer runs on the realtime audio thread,
/// where allocation, locks, and logging are all forbidden. The UI polls whenever
/// it likes; a torn read just means one stale frame on a meter.
package nonisolated final class ChannelMeter: Sendable {
    
    package init() {}

    private let peakBits = Atomic<UInt32>(0)
    /// Running maximum, never overwritten downward until `reset()`.
    private let peakHoldBits = Atomic<UInt32>(0)
    private let frameCount = Atomic<UInt64>(0)
    private let cycleCount = Atomic<UInt64>(0)
    
    /// Called from the audio thread. Must stay allocation-free.
    package func record(peak: Float, frames: Int) {
        peakBits.store(peak.bitPattern, ordering: .relaxed)

        // Compare-exchange rather than store: this is the only value that can answer
        // "did any speech arrive during this session", and a plain store reports
        // whatever the last buffer held — silence, if the session ended with someone
        // reaching for the Stop button.
        var current = peakHoldBits.load(ordering: .relaxed)
        while Float(bitPattern: current) < peak {
            let (exchanged, seen) = peakHoldBits.compareExchange(
                expected: current, desired: peak.bitPattern, ordering: .relaxed)
            if exchanged { break }
            current = seen
        }
        frameCount.wrappingAdd(UInt64(frames), ordering: .relaxed)
        cycleCount.wrappingAdd(1, ordering: .relaxed)
    }
    
    /// The most recent buffer's peak. For a live meter, where decay is the point.
    package var peak: Float { Float(bitPattern: peakBits.load(ordering: .relaxed)) }

    /// The loudest sample since `reset()`. For diagnostics, where a single instant
    /// says nothing.
    package var peakHold: Float { Float(bitPattern: peakHoldBits.load(ordering: .relaxed)) }
    package var frames: UInt64 { frameCount.load(ordering: .relaxed) }
    package var cycles: UInt64 { cycleCount.load(ordering: .relaxed) }
    
    package func reset() {
        peakBits.store(0, ordering: .relaxed)
        peakHoldBits.store(0, ordering: .relaxed)
        frameCount.store(0, ordering: .relaxed)
        cycleCount.store(0, ordering: .relaxed)
    }
    
}
