import AppKit

/// Tracks playback state that apps broadcast as distributed notifications.
/// Covers playback Core Audio cannot see, e.g. Music streaming to AirPlay, which runs no Core Audio output.
/// Notifications arrive on every play/pause/stop; state at launch is read over AppleScript from apps already running.
@MainActor
final class PlayerStateMonitor {
    /// Bundle ID -> distributed notification carrying "Player State" ("Playing", "Paused", "Stopped").
    private static let notifications = [
        "com.apple.Music": "com.apple.Music.playerInfo",
    ]

    private let queue = DispatchQueue(label: "com.morrishoresh.AudioControl.player-state")

    private var playing: Set<String> = []

    init() {
        for (bundleID, name) in Self.notifications {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] notification in
                let state = notification.userInfo?["Player State"] as? String
                MainActor.assumeIsolated { self?.set(bundleID, playing: state == "Playing") }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.set(bundleID, playing: false) }
        }
    }

    /// Reads the current state of apps already running, which posted their last notification before this app started.
    func readInitialState() {
        for bundleID in Self.notifications.keys
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            queue.async {
                let script = "tell application id \"\(bundleID)\" to return (player state is playing)"
                var error: NSDictionary?
                let playing = NSAppleScript(source: script)?.executeAndReturnError(&error).booleanValue ?? false
                guard error == nil else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.set(bundleID, playing: playing) }
                }
            }
        }
    }

    func isPlaying(_ bundleID: String) -> Bool {
        playing.contains(bundleID)
    }

    private func set(_ bundleID: String, playing isPlaying: Bool) {
        if isPlaying {
            playing.insert(bundleID)
        } else {
            playing.remove(bundleID)
        }
    }
}
