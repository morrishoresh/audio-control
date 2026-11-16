import AppKit
import CoreAudio

/// A running app that has registered with Core Audio, together with every audio process it is responsible for
/// (e.g. Safari's WebKit GPU process, Chrome's helpers).
struct AudioApp {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]
    var isRunningInput: Bool
    var isRunningOutput: Bool
}

enum AudioProcesses {
    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` maps a helper/XPC process to the app it works for.
    /// Not in the public headers, so it is looked up at runtime; without it each process is treated as its own app.
    private static let responsiblePID: ResponsiblePIDFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    static func processObjects() -> [AudioObjectID] {
        var address = AudioDevices.globalAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioDevices.system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioDevices.system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Apps with at least one audio process, grouped by responsible app. Excludes this app.
    @MainActor
    static func apps() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var byBundleID: [String: AudioApp] = [:]
        for process in processObjects() {
            guard let pid = pidProperty(process), pid != ownPID,
                  let app = runningApp(for: pid), app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier else { continue }
            let input = uint32Property(process, kAudioProcessPropertyIsRunningInput) != 0
            let output = uint32Property(process, kAudioProcessPropertyIsRunningOutput) != 0
            if var existing = byBundleID[bundleID] {
                existing.processes.append(process)
                existing.isRunningInput = existing.isRunningInput || input
                existing.isRunningOutput = existing.isRunningOutput || output
                byBundleID[bundleID] = existing
            } else {
                byBundleID[bundleID] = AudioApp(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    icon: app.icon,
                    processes: [process],
                    isRunningInput: input,
                    isRunningOutput: output
                )
            }
        }
        return byBundleID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Calls `handler` on the main queue when the process starts or stops capturing input.
    static func observeInput(_ process: AudioObjectID, _ handler: @escaping @Sendable () -> Void) {
        var address = AudioDevices.globalAddress(kAudioProcessPropertyIsRunningInput)
        AudioObjectAddPropertyListenerBlock(process, &address, .main) { _, _ in handler() }
    }

    @MainActor
    private static func runningApp(for pid: pid_t) -> NSRunningApplication? {
        let candidates = [responsiblePID?(pid), pid].compactMap { $0 }.filter { $0 > 0 }
        for candidate in candidates {
            if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy != .prohibited {
                return app
            }
        }
        return nil
    }

    private static func pidProperty(_ process: AudioObjectID) -> pid_t? {
        var address = AudioDevices.globalAddress(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioDevices.globalAddress(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}
