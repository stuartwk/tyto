//
//  AudioRingBuffer.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/9/26.
//

import Foundation
import Synchronization

/// Single-producer, single-consumer float ring buffer.
///
/// The producer is the realtime IOProc: no allocation, no locks, no waiting. The
/// consumer is an ordinary task that drains it into AVAudioPCMBuffers for
/// SpeechAnalyzer. This handoff is the boundary between realtime and async — the
/// IOProc cannot allocate, and everything the analyzer needs does.
///
/// `@unchecked Sendable`: the storage pointer isn't Sendable, but access is
/// disciplined by the atomic read/write indices below.
package nonisolated final class AudioRingBuffer: @unchecked Sendable {
    
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let mask: UInt64

    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let overruns = Atomic<UInt64>(0)
    /// Frames discarded, so a gap can be reported with a real duration rather
    /// than an event count that says nothing about how much was lost.
    private let dropped = Atomic<UInt64>(0)
    
    /// Rounds up to a power of two so index wrapping is a mask rather than a modulo.
    package init(minimumFrames: Int) {
        var size = 1
        while size < minimumFrames { size <<= 1 }
        capacity = size
        mask = UInt64(size - 1)
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: size)
        storage.initialize(repeating: 0)
    }
    
    deinit { storage.deallocate() }

    /// Realtime-safe. Pulls one channel out of an interleaved source.
    ///
    /// On overflow the whole block is dropped rather than partially written —
    /// a gap is recoverable, interleaved garbage is not. Overflows are counted.
    package func write(from source: UnsafePointer<Float>, frames: Int, stride: Int, offset: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        guard frames <= capacity - Int(w &- r) else {
            overruns.wrappingAdd(1, ordering: .relaxed)
            dropped.wrappingAdd(UInt64(frames), ordering: .relaxed)
            return
        }
        for i in 0..<frames {
            storage[Int((w &+ UInt64(i)) & mask)] = source[offset + i * stride]
        }
        writeIndex.store(w &+ UInt64(frames), ordering: .releasing)
    }
    
    /// Writes `frames` of silence. Realtime-safe: no source buffer, no allocation.
    ///
    /// Used to fill a hole left by a stalled capture stream. Inserting silence rather
    /// than closing the hole is what keeps the analyzer's timeline equal to elapsed
    /// time — without it, every later timestamp on this channel is early by the
    /// duration of everything that was lost.
    package func writeSilence(frames: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        guard frames <= capacity - Int(w &- r) else {
            overruns.wrappingAdd(1, ordering: .relaxed)
            dropped.wrappingAdd(UInt64(frames), ordering: .relaxed)
            return
        }
        for i in 0..<frames {
            storage[Int((w &+ UInt64(i)) & mask)] = 0
        }
        writeIndex.store(w &+ UInt64(frames), ordering: .releasing)
    }
    
    /// Consumer side. Returns how many frames were actually available.
    package func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(Int(w &- r), maxFrames)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            destination[i] = storage[Int((r &+ UInt64(i)) & mask)]
        }
        readIndex.store(r &+ UInt64(n), ordering: .releasing)
        return n
    }
    
    package var overrunCount: UInt64 { overruns.load(ordering: .relaxed) }
    package var droppedFrames: UInt64 { dropped.load(ordering: .relaxed) }

    package var pendingFrames: Int {
        Int(writeIndex.load(ordering: .relaxed) &- readIndex.load(ordering: .relaxed))
    }
    
}
