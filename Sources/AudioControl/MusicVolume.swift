import AppKit
import os

/// Music's volume, matching Music's own volume slider: the selected AirPlay receivers' volume while Music plays to
/// AirPlay (which bypasses Core Audio), otherwise Music's player volume. Set over AppleScript; receivers that ignore
/// AirPlay volume but accept Denon/Marantz network control are set directly (`ReceiverControl`).
/// Work runs off the main thread, latest value wins.
/// Nothing is sent while Music is not running, so it is never launched by this.
@MainActor
final class MusicVolume {
    nonisolated static let bundleID = "com.apple.Music"

    /// Last volume read from or set on Music.
    private(set) var cached: Int?

    private let log = Logger(subsystem: "com.morrishoresh.AudioControl", category: "music")
    private let queue = DispatchQueue(label: "com.morrishoresh.AudioControl.music-volume")
    private var pendingSet: Int?
    private var sending = false
    /// Incremented on every `set`, so a read that started before a change is discarded instead of undoing it.
    private var setCount = 0
    /// A read is in progress; further refreshes are skipped until it finishes (the menu polls every second).
    private var refreshing = false
    private let receivers = ReceiverControl()

    static func handles(_ bundleID: String) -> Bool {
        bundleID == Self.bundleID
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Reads Music's volume and calls `completion` on the main thread if it succeeded and no `set` happened meanwhile.
    func refresh(_ completion: @escaping (Int) -> Void) {
        guard isRunning, !refreshing else { return }
        refreshing = true
        let startCount = setCount
        queue.async { [log, receivers] in
            let names = Self.remoteNames(log: log)
            let fromReceiver = names.first.flatMap { receivers.volume(airPlayName: $0) }
            let volume = fromReceiver ?? Self.run(Self.getScript, log: log).map { Int($0.int32Value) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshing = false
                    guard let volume, self.setCount == startCount else { return }
                    self.cached = volume
                    completion(volume)
                }
            }
        }
    }

    func set(_ volume: Int) {
        setCount += 1
        cached = volume
        guard isRunning else { return }
        pendingSet = volume
        sendNext()
    }

    private func sendNext() {
        guard !sending, let volume = pendingSet else { return }
        pendingSet = nil
        sending = true
        queue.async { [log, receivers] in
            for name in Self.remoteNames(log: log) where receivers.setVolume(airPlayName: name, volume) {
                log.info("\(name, privacy: .public) volume set to \(volume)% over network control")
            }
            // Also keeps Music's own display of the volume in step.
            _ = Self.run(Self.setScript(volume), log: log)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sending = false
                    self.sendNext()
                }
            }
        }
    }

    /// Selected AirPlay receivers other than this Mac.
    private nonisolated static let remoteDevices =
        "set remote to (every AirPlay device whose selected is true and kind is not computer)"

    private nonisolated static let namesScript = """
        tell application id "\(bundleID)"
            \(remoteDevices)
            set names to ""
            repeat with device in remote
                set names to names & (name of device) & linefeed
            end repeat
            return names
        end tell
        """

    private nonisolated static func remoteNames(log: Logger) -> [String] {
        let names = run(namesScript, log: log)?.stringValue ?? ""
        return names.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private nonisolated static let getScript = """
        tell application id "\(bundleID)"
            \(remoteDevices)
            if remote is {} then return sound volume
            return sound volume of item 1 of remote
        end tell
        """

    private nonisolated static func setScript(_ volume: Int) -> String {
        """
        tell application id "\(bundleID)"
            \(remoteDevices)
            if remote is {} then
                set sound volume to \(volume)
            else
                repeat with device in remote
                    set sound volume of device to \(volume)
                end repeat
            end if
        end tell
        """
    }

    private nonisolated static func run(_ source: String, log: Logger) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -1743: the user has not allowed AudioControl to control Music (Privacy & Security > Automation).
            log.error("Music AppleScript failed: \(error, privacy: .public)")
            return nil
        }
        return result
    }
}
