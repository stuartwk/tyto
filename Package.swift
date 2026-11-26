// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "tyto",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "Tyto", targets: ["Tyto"]),
        .executable(name: "tyto", targets: ["TytoCLI"]),
    ],
    targets: [
        // Public API: TranscriptionSession, Transcript and friends.
        .target(name: "Tyto", dependencies: ["TytoCapture"]),

        // Core Audio capture. Internal to the package until there is a reason to
        // expose raw audio streams.
        .target(name: "TytoCapture"),

        .executableTarget(
            name: "TytoCLI",
            dependencies: ["Tyto", "TytoCapture"],
            linkerSettings: [
                // A bare binary has no bundle, so macOS has nowhere to read the
                // audio-capture usage string from. Embedding an Info.plist in the
                // __TEXT segment gives it one. Unsafe flags are confined to this
                // target, so depending on the Tyto library is unaffected.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ]),
            ]
        ),

        // Regression check for capture routing. Run after any change to CaptureEngine,
        // AggregateDevice or MicrophoneCapture: `swift run channelmap`.
        .executableTarget(name: "channelmap", dependencies: ["TytoCapture"]),

        .testTarget(name: "TytoCaptureTests", dependencies: ["TytoCapture"]),
        .testTarget(name: "TytoTests", dependencies: ["Tyto"]),
    ]
)
