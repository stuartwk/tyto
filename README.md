# tyto

On-device, two-channel transcription for macOS: your microphone and other apps'
audio are captured as separate channels, so who said what comes from where the
audio came from rather than from guessing.

Early, but working end to end: `tyto listen` streams a two-speaker transcript as
JSON Lines, entirely on this Mac (Core Audio process taps, Apple's voice
processing for echo cancellation, and `SpeechAnalyzer`).

## Build

Needs macOS 27 and Xcode-beta (Swift 6.2+):

```
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build
swift test
```

## Library

```swift
// Package.swift
.package(url: "https://github.com/stuartwk/tyto", branch: "main")
// target dependency
.product(name: "Tyto", package: "tyto")
```

```swift
import Tyto

let session = TranscriptionSession(source: .app(bundleID: "us.zoom.xos"))
try await session.start()

Task {
    for await event in session.events {
        switch event {
        case .segment(let segment):  print(segment.speaker, segment.text)
        case .suspectedBleed(let id): markAsPossibleEcho(id)
        case .gap(let speaker, let at, let duration): noteMissingAudio(speaker, at, duration)
        case .warning(let warning):  show(warning)
        }
    }
}

// later
let transcript = await session.stop()
print(transcript.plainText(flagging: transcript.suspectedBleed()))
```

- `TranscriptionSession(source:locale:)`: `.allApps` or `.app(bundleID:)`, and
  any locale `SpeechTranscriber` supports on-device. An `.app` source waits for
  the app to open audio and follows its processes (`.sourceProcessesChanged`).
- `AudioApps.running()` lists apps for a picker, including ones that haven't
  used audio yet.
- `TranscriptionSession.prepare(locale:)` downloads the speech model up front;
  `start()` does it too, but a first download takes a while.
- `echoCancellation` is `.active` or `.unavailable(reason:)` after `start()`.
  When unavailable, the local channel is the raw microphone and the remote side
  can bleed into it on speakers.
- `events` delivers `segment`, `gap`, `suspectedBleed` (a segment already
  delivered looks like echo of the other speaker: advisory, never removed) and
  `warning` (e.g. `.microphoneSilent`, which almost always means macOS denied
  microphone access without an error).
- `stop()` flushes buffered audio and returns the merged `Transcript`: turns,
  holes, `lostAudio`, `plainText()`, `suspectedBleed()`.

## `tyto listen`

```
swift run tyto listen                    # until Ctrl-C
swift run tyto listen --app us.zoom.xos  # only one app (and its helpers)
swift run tyto apps                      # bundle IDs to pass to --app
swift run tyto listen --format text      # human-readable
```

Each finalised segment is one line on stdout:

```json
{"confidence":0.929,"end":7.86,"id":"2abfef10","speaker":"remote","start":5.46,"text":"This sentence should survive the interrupt.","type":"segment"}
```

- `speaker`: `local` (this Mac's microphone) or `remote` (other apps' audio).
  Attribution comes from which channel the audio arrived on, not from voices.
- `start` and `end`: seconds on one timeline shared by both channels. Lines arrive
  as each channel finalises, so they are not strictly ordered across speakers.
- `type: "suspected_bleed"` names the `id` of an earlier segment that looks like
  echo of the other speaker. Advisory: decide for yourself whether to drop it.
- `type: "gap"` marks audio that was lost (`at`, `duration`). The text either
  side of a gap otherwise reads as continuous.
- The last line is `type: "end"`, with `echo_cancellation`: if that's `false`,
  the remote side can bleed into the `local` channel on speakers.

Status and errors go to stderr. Ctrl-C flushes buffered audio before exiting.

`--app` doesn't need the app to be running. Core Audio only knows an app once it
opens audio, so tyto waits for it and follows it: start `tyto listen --app
us.zoom.xos`, then join the call. Helper processes that appear mid-call are
picked up too. `tyto apps` lists every running app, including ones that haven't
used audio yet.

Avoid `--app` for browser calls: browsers play every tab through one shared
helper process, so you'd capture all tabs anyway. The default (all apps) is
simpler.

## Permissions

- **Command line:** macOS asks your terminal app (Terminal, iTerm, VS Code) for
  microphone and audio-capture permission the first time, and remembers it there.
- **In your own app:** the app holds the permissions. Add
  `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` to its
  Info.plist (and `com.apple.security.device.audio-input` if sandboxed).
- A denied audio-capture permission is *silent*: everything reports success and
  the samples are zeros. `tyto probe` checks for real signal.

## `tyto probe`

```
swift run tyto probe --seconds 6
```

Captures the microphone and a global process tap for a few seconds and reports
whether real signal arrived on each. Play something while it runs.

Core Audio reports success at every step when capture is not permitted: taps are
created, devices start, and every buffer is zeros. "SILENT" therefore means either
nothing made sound or permission was denied, and the probe can't tell which.

## Layout

- `Sources/TytoCapture`: process tap, aggregate device, voice-processed
  microphone, ring buffers, stream continuity. Internal for now.
- `Sources/Tyto`: the public library. `TranscriptionSession`, `Transcript`, one
  `SpeechAnalyzer` per channel, live and after-the-fact echo-bleed detection.
- `Sources/TytoCLI`: the `tyto` command.
- `Sources/channelmap`: regression check that the remote channel is fed by the
  tap and only the tap. Run after touching capture: `swift run channelmap`
  (mutes output for a few seconds, then restores your volume).


- The CLI's Info.plist (`Support/Info.plist`) is linked into
  the binary's `__TEXT,__info_plist` section, since a bare executable has no
  bundle for macOS to read usage strings from.
