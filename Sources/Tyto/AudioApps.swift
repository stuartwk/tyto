//
//  AudioApps.swift
//  tyto
//

import AppKit
import CoreAudio
import TytoCapture

/// A running app that could be passed to `AudioSource.app(bundleID:)`.
public struct AudioApp: Sendable, Hashable {
    public enum State: Int, Sendable, Comparable {
        /// Playing audio right now.
        case playing = 0
        /// Has an audio connection open but is not playing.
        case audioOpen = 1
        /// Running, but has never opened audio. It can still be chosen: a session
        /// waits for it.
        case notUsingAudio = 2

        public static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let name: String
    public let bundleID: String
    public let state: State
}

public enum AudioApps {

    /// Apps the user could pick from: every app in the Dock, plus background apps
    /// that have audio open. Playing apps first.
    ///
    /// The Dock list comes from the system rather than Core Audio, because Core Audio
    /// only knows an app once it has opened audio, and the usual flow is to start
    /// transcribing before the call app makes any sound.
    @MainActor
    public static func running() -> [AudioApp] {
        let processes = AudioProcessList.current()

        func state(for bundleID: String) -> AudioApp.State {
            let mine = processes.filter { $0.bundleID?.hasPrefix(bundleID) == true }
            if mine.contains(where: \.isRunningOutput) { return .playing }
            return mine.isEmpty ? .notUsingAudio : .audioOpen
        }

        var seen = Set<String>()
        var apps: [AudioApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, seen.insert(bundleID).inserted,
                  app.processIdentifier != getpid() else { continue }
            let appState = state(for: bundleID)
            // Background-only apps are only worth listing when they have audio.
            guard app.activationPolicy == .regular || appState != .notUsingAudio else { continue }
            apps.append(AudioApp(name: app.localizedName ?? bundleID, bundleID: bundleID, state: appState))
        }
        // Fold helpers into their app: `.app(bundleID:)` already matches them by
        // prefix, and the app takes the most active state among them.
        let parents = apps.filter { app in
            !apps.contains { $0.bundleID != app.bundleID && app.bundleID.hasPrefix($0.bundleID + ".") }
        }
        let folded = parents.map { parent in
            let family = apps.filter { $0.bundleID == parent.bundleID || $0.bundleID.hasPrefix(parent.bundleID + ".") }
            return AudioApp(name: parent.name, bundleID: parent.bundleID,
                            state: family.map(\.state).min() ?? parent.state)
        }
        return folded.sorted { ($0.state, $0.name.lowercased()) < ($1.state, $1.name.lowercased()) }
    }
}
