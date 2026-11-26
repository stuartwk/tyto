import Foundation
import Tyto

let usage = """
    usage: tyto <command> [options]

    commands:
      listen  Transcribe your microphone and other apps' audio as two channels.
              --app <bundle-id>   only this app (and its helpers), e.g. us.zoom.xos
              --seconds N         stop after N seconds (default: until Ctrl-C)
              --format jsonl|text output format (default: jsonl)

      apps    List running apps and their bundle IDs, for --app. Apps that
              haven't used audio yet are listed too: listen waits for them.

      probe   Check that real audio arrives from the mic and other apps.
              --seconds N         how long to listen (default 6)
    """

var args = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("tyto: \(message)\n\n\(usage)\n".utf8))
    exit(64)
}

guard let command = args.first else { print(usage); exit(64) }
args.removeFirst()

switch command {
case "listen":
    var seconds: Int?
    if let raw = option("--seconds") {
        guard let n = Int(raw), n > 0 else { fail("--seconds needs a positive whole number") }
        seconds = n
    }
    let formatName = option("--format") ?? "jsonl"
    guard let format = Listen.Format(rawValue: formatName) else { fail("unknown format '\(formatName)'") }
    exit(await Listen.run(appBundleID: option("--app"), seconds: seconds, format: format))
case "apps":
    let apps = AudioApps.running()
    let width = min(max(apps.map(\.bundleID.count).max() ?? 0, 9), 48)
    print("STATE      " + "BUNDLE ID".padding(toLength: width + 2, withPad: " ", startingAt: 0) + "NAME")
    for app in apps {
        let state = switch app.state {
        case .playing: "playing"
        case .audioOpen: "audio open"
        case .notUsingAudio: "-"
        }
        print(state.padding(toLength: 11, withPad: " ", startingAt: 0)
              + app.bundleID.padding(toLength: width + 2, withPad: " ", startingAt: 0) + app.name)
    }
case "probe":
    let seconds = option("--seconds").flatMap(Int.init) ?? 6
    exit(Probe.run(seconds: max(seconds, 1)))
case "-h", "--help", "help":
    print(usage)
default:
    fail("unknown command '\(command)'")
}
