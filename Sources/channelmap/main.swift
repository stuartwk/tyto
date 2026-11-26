import CoreAudio
import Foundation
import TytoCapture

// Is the remote buffer really fed by the process tap, and only by it?
//
// It went wrong once, in the app tyto was extracted from. CaptureEngine mapped
// flattened channel indices, and enabling voice processing turns the built-in
// microphone from a 1-channel device into a 3-channel one *while the aggregate is
// running*. The IO cycle went from [mic, tap] to [mic0, mic1, mic2, tap], channel 1
// stopped being the tap, and the remote transcript was silently fed the raw
// microphone: the local speaker's words attributed to the other side.
//
// The fix routes by aggregate member (one AudioBuffer each) instead of by flattened
// channel, because a member's buffer index is stable when its channel count is not.
// This verifies that end to end, through the ring buffers a transcriber drains.
//
// Output is muted throughout. A process tap sees a process's audio before the
// device volume applies, so the stimulus reaches the tap and never the microphone.
// Nobody has to speak and nothing has to be judged by ear. Your volume is restored
// afterwards.

func osascript(_ script: String) -> String {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Drains `ring` for `seconds` and returns its peak. Draining throughout keeps the
/// ring from overrunning and dropping audio mid-window.
nonisolated func peak(of ring: AudioRingBuffer, seconds: Double) async -> Float {
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    defer { scratch.deallocate() }
    var highest: Float = 0
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let read = ring.read(into: scratch, maxFrames: 4096)
        if read == 0 { try? await Task.sleep(for: .milliseconds(5)); continue }
        for index in 0..<read { highest = max(highest, abs(scratch[index])) }
    }
    return highest
}

/// Peaks of both aggregate buffers over the same window.
func measure(_ local: AudioRingBuffer, _ remote: AudioRingBuffer,
             seconds: Double) async -> (local: Float, remote: Float) {
    async let l = Task.detached { await peak(of: local, seconds: seconds) }.value
    async let r = Task.detached { await peak(of: remote, seconds: seconds) }.value
    return await (l, r)
}

let originalVolume = Int(osascript("output volume of (get volume settings)")) ?? 31

let engine = CaptureEngine()
do { try engine.start() } catch { print("CaptureEngine failed: \(error.localizedDescription)"); exit(1) }

let micID = AudioDevices.defaultInputID()
func micChannels() -> Int { micID.map { CoreAudioHAL.inputChannelCount(of: $0) } ?? -1 }
print("\nmicrophone before voice processing: \(micChannels()) ch")

// Voice processing is what changes the microphone's channel count underneath the
// aggregate, so it has to be running for this check to mean anything.
let mic = MicrophoneCapture()
let micRing = AudioRingBuffer(minimumFrames: 96_000)
do { try mic.start(into: micRing) } catch { print("MicrophoneCapture failed: \(error.localizedDescription)") }
let micDrain = Task.detached { _ = await peak(of: micRing, seconds: 30) }
try await Task.sleep(for: .seconds(1))
print("microphone after  voice processing: \(micChannels()) ch  (the change that broke the old map)")

guard let local = engine.localBuffer, let remote = engine.remoteBuffer else {
    print("no buffers"); exit(1)
}

_ = osascript("set volume output volume 0")
try await Task.sleep(for: .seconds(1))

print("\nquiet: nothing playing, output muted")
let quiet = await measure(local, remote, seconds: 2)
print(String(format: "  local %.6f   remote %.6f", quiet.local, quiet.remote))

print("speaking through a muted output: only the tap can see this")
let speaker = Process()
speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
speaker.arguments = ["This is the channel map check. One, two, three, four, five, six."]
try? speaker.run()
try await Task.sleep(for: .milliseconds(500))
let playing = await measure(local, remote, seconds: 2.5)
speaker.terminate()
print(String(format: "  local %.6f   remote %.6f", playing.local, playing.remote))

micDrain.cancel()
_ = osascript("set volume output volume \(originalVolume)")
await mic.stop()
await engine.stop()

let remoteGotIt = playing.remote > max(quiet.remote * 4, 0.01)
let localStayedClean = playing.local < max(quiet.local * 4, 0.01)
print("""

  remote buffer receives the tap : \(remoteGotIt ? "YES" : "NO")
  local buffer stays clean       : \(localStayedClean ? "YES" : "NO")
  \(remoteGotIt && localStayedClean ? "→ routing is correct" : "→ ROUTING IS WRONG")
""")
exit(remoteGotIt && localStayedClean ? 0 : 1)
