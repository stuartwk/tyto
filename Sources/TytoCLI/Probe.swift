import CoreAudio
import Foundation
import TytoCapture

/// Answers one question: does this binary actually receive audio?
///
/// Core Audio reports success at every step when audio capture is not permitted:
/// the tap is created, the aggregate starts, the IO proc runs on schedule, and every
/// buffer is zeros. So the only verdict worth giving comes from the samples.
///
/// `nonisolated` throughout: the IO block runs on a dispatch queue, and a closure
/// formed in main-actor code would carry a main-actor assumption that traps there.
nonisolated enum Probe {

    /// Aggregate members in buffer order: sub-devices first, then taps.
    private static let memberNames = ["microphone", "other apps"]

    static func run(seconds: Int) -> Int32 {
        let embedded = Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") != nil
        print("Info.plist embedded: \(embedded ? "yes" : "NO — audio capture will be refused")")
        print("Bundle identifier:   \(Bundle.main.bundleIdentifier ?? "none")")

        guard let micID = AudioDevices.defaultInputID() else {
            print("No default input device.")
            return 1
        }
        print("Microphone:          \(AudioDevices.name(of: micID) ?? "unknown")")

        let tap: ProcessTap
        let aggregate: AggregateDevice
        do {
            tap = try ProcessTap()
            aggregate = try AggregateDevice(tap: tap, inputDeviceID: micID)
        } catch {
            print("Setup failed: \(error.localizedDescription)")
            return 1
        }

        let meters = memberNames.map { _ in ChannelMeter() }
        let queue = DispatchQueue(label: "tyto.probe.io", qos: .userInitiated)
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.objectID, queue) {
            _, input, _, _, _ in
            record(input, into: meters)
        }
        guard status == noErr, let procID else {
            print("IO proc failed: \(CoreAudioHAL.describe(status))")
            return 1
        }
        defer {
            AudioDeviceStop(aggregate.objectID, procID)
            AudioDeviceDestroyIOProcID(aggregate.objectID, procID)
            // Aggregate before tap: the aggregate references the tap by UID.
            aggregate.invalidate()
            tap.invalidate()
        }

        status = AudioDeviceStart(aggregate.objectID, procID)
        guard status == noErr else {
            print("Start failed: \(CoreAudioHAL.describe(status))")
            return 1
        }

        print("\nListening for \(seconds)s. Play audio in another app and say something.\n")
        for second in 1...seconds {
            Thread.sleep(forTimeInterval: 1)
            let line = zip(memberNames, meters)
                .map { name, meter in "\(name) \(bar(meter.peak))" }
                .joined(separator: "   ")
            print(String(format: "%3ds  ", second) + line)
        }

        print("")
        var allGood = true
        for (name, meter) in zip(memberNames, meters) {
            let verdict: String
            if meter.cycles == 0 {
                verdict = "no IO cycles: the device never ran"
                allGood = false
            } else if meter.peakHold <= 0.0001 {
                verdict = "SILENT. Either nothing made sound, or permission was denied (macOS reports success either way)"
                allGood = false
            } else {
                verdict = String(format: "signal (peak %.3f)", meter.peakHold)
            }
            print("\(name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(verdict)")
        }
        return allGood ? 0 : 2
    }

    /// Realtime thread: no allocation, no locks, no printing.
    private static func record(_ input: UnsafePointer<AudioBufferList>, into meters: [ChannelMeter]) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for (member, buffer) in list.enumerated() where member < meters.count {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: total)
            var peak: Float = 0
            var i = 0
            while i < total {   // first channel of each member, as CaptureEngine routes
                peak = max(peak, abs(samples[i]))
                i += channels
            }
            meters[member].record(peak: peak, frames: total / channels)
        }
    }

    private static func bar(_ peak: Float) -> String {
        let width = 16
        let db = peak > 0 ? 20 * log10(peak) : -100
        let filled = Int(((db + 60) / 60 * Float(width)).rounded()).clamped(0, width)
        return "[" + String(repeating: "#", count: filled)
            + String(repeating: " ", count: width - filled) + "]"
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}
