//
//  BufferConverter.swift
//  tyto
//
//  Created by Stuart Kuentzel on 8/21/26.
//

import Foundation
import AVFoundation

/// Wraps `AVAudioConverter` for the one job this app has: taking captured audio at
/// the aggregate device's rate and handing it to `SpeechAnalyzer` at whatever rate
/// the analyzer asked for.
///
/// Not thread-safe. `AVAudioConverter` carries resampler state across calls, so one
/// converter belongs to exactly one channel's drain loop.
package nonisolated final class BufferConverter {
    
    package enum Failure: Error, LocalizedError {
        case allocationFailed
        case conversionFailed(Error?)

        package var errorDescription: String? {
            switch self {
            case .allocationFailed:
                "Could not allocate a buffer for audio conversion."
            case .conversionFailed(let underlying):
                "Audio conversion failed\(underlying.map { ": \($0.localizedDescription)" } ?? ".")"
            }
        }
    }
    
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    package init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
    }
    
    /// Returns nil when this call produced no frames — normal for a resampler that
    /// wants more input, not an error.
    package func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        
        if buffer.format == outputFormat { return buffer }

        // Headroom: the ratio alone rounds down, and the resampler may emit the tail
        // of the previous call's filter state along with this call's output.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Failure.allocationFailed
        }
        
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // One input buffer per call. Once it's handed over, tell the converter to
            // stop asking rather than stall waiting for more.
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream:
            return nil
        case .error:
            throw Failure.conversionFailed(error)
        @unknown default:
            throw Failure.conversionFailed(error)
        }
        
    }
    
}
