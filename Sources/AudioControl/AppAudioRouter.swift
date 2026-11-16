import CoreAudio
import Foundation
import os

/// Applies per-app settings:
/// - Volume / output device: the app's audio is tapped (muted at source) and replayed on the chosen device at the chosen gain.
/// - Input device: macOS has no per-process input selection, so while an app with an input override is capturing,
///   its device becomes the system default input. The most recently started capture wins. When no such app is
///   capturing, the default input goes back to the global target input, or else to what it was before.
@MainActor
final class AppAudioRouter {
    /// Delay before acting on capture start/stop, so an app briefly restarting its input does not flip the default.
    private static let inputSettleDelay: TimeInterval = 0.5

    let settings = AppSettingsStore()
    /// Global target input UID, consulted when restoring the default input after an override.
    var globalInputTarget: () -> String? = { nil }
    /// Called after the default input is changed by an override.
    var onInputChange: () -> Void = {}

    /// Device UID currently forced as default input by a capturing app, nil when no override is active.
    private(set) var inputOverrideUID: String?

    private let log = Logger(subsystem: "com.morrishoresh.AudioControl", category: "per-app")
    private var taps: [String: AppTap] = [:]
    /// Configuration (processes + device) that last failed per app, so it is not retried on every refresh.
    private var failed: [String: String] = [:]
    private var observedProcesses: Set<AudioObjectID> = []
    private var captureStarted: [String: Date] = [:]
    private var restoreInputUID: String?
    private var inputTimer: Timer?

    /// Reconciles taps and input overrides with the current processes, devices and settings. Idempotent.
    func refresh() {
        let apps = AudioProcesses.apps()
        observeNewProcesses()
        reconcileOutput(apps)
        trackCapture(apps)
    }

    /// Tears down every tap and rebuilds them (e.g. after wake, when devices may have been reset).
    func rebuild() {
        stopAll()
        failed = [:]
        refresh()
    }

    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps = [:]
    }

    /// Updates the gain live while a slider moves; creates the tap if the app had none.
    /// A tap left unneeded (back at 100%) is removed on the next `refresh()`.
    func setVolume(_ bundleID: String, name: String, _ volume: Int) {
        settings.update(bundleID, name: name) { $0.volume = volume }
        if let tap = taps[bundleID] {
            tap.setVolume(volume)
        } else if volume != 100 {
            refresh()
        }
    }

    // MARK: - Output

    private func reconcileOutput(_ apps: [AudioApp]) {
        let outputs = AudioDevices.devices(.output)
        let defaultUID = AudioDevices.defaultDeviceUID(.output)
        var wanted: [String: (processes: [AudioObjectID], device: AudioDevice, volume: Int)] = [:]
        for app in apps {
            guard let settings = settings[app.bundleID] else { continue }
            // Music's volume is set on Music itself, so its tap (if any) only reroutes, at unity gain.
            let volume = MusicVolume.handles(app.bundleID) ? 100 : settings.volume
            guard volume != 100 || settings.outputUID != nil else { continue }
            let chosen = settings.outputUID.flatMap { uid in outputs.first { $0.uid == uid } }
            guard let device = chosen ?? outputs.first(where: { $0.uid == defaultUID }) else { continue }
            wanted[app.bundleID] = (app.processes.sorted(), device, volume)
        }

        for (bundleID, tap) in taps {
            if let want = wanted[bundleID], want.processes == tap.processes, want.device.uid == tap.deviceUID {
                continue
            }
            tap.stop()
            taps[bundleID] = nil
            log.info("Stopped routing \(bundleID, privacy: .public)")
        }

        for (bundleID, want) in wanted {
            if let tap = taps[bundleID] {
                tap.setVolume(want.volume)
                continue
            }
            let key = "\(want.processes)|\(want.device.uid)"
            guard failed[bundleID] != key else { continue }
            do {
                taps[bundleID] = try AppTap(
                    bundleID: bundleID,
                    processes: want.processes,
                    deviceID: want.device.id,
                    deviceUID: want.device.uid,
                    volume: want.volume
                )
                failed[bundleID] = nil
                log.info("Routing \(bundleID, privacy: .public) to \(want.device.name, privacy: .public) at \(want.volume)%")
            } catch {
                failed[bundleID] = key
                log.error("Routing \(bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Input

    private func observeNewProcesses() {
        let current = Set(AudioProcesses.processObjects())
        for process in current.subtracting(observedProcesses) {
            AudioProcesses.observeInput(process) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        observedProcesses = current
    }

    private func trackCapture(_ apps: [AudioApp]) {
        let capturing = Set(apps.filter(\.isRunningInput).map(\.bundleID))
        let now = Date()
        for bundleID in capturing where captureStarted[bundleID] == nil {
            captureStarted[bundleID] = now
        }
        captureStarted = captureStarted.filter { capturing.contains($0.key) }

        inputTimer?.invalidate()
        inputTimer = Timer.scheduledTimer(withTimeInterval: Self.inputSettleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyInput() }
        }
    }

    private func applyInput() {
        let inputs = AudioDevices.devices(.input)
        let current = AudioDevices.defaultDeviceUID(.input)
        let wanted = captureStarted
            .sorted { $0.value > $1.value }
            .compactMap { settings[$0.key]?.inputUID }
            .first { uid in inputs.contains { $0.uid == uid } }

        if let wanted {
            if inputOverrideUID == nil {
                restoreInputUID = current
            }
            inputOverrideUID = wanted
            setDefaultInput(wanted, inputs, current: current)
        } else if inputOverrideUID != nil {
            inputOverrideUID = nil
            let restore = [globalInputTarget(), restoreInputUID]
                .compactMap { $0 }
                .first { uid in inputs.contains { $0.uid == uid } }
            restoreInputUID = nil
            if let restore {
                setDefaultInput(restore, inputs, current: current)
            }
        }
    }

    private func setDefaultInput(_ uid: String, _ inputs: [AudioDevice], current: String?) {
        guard uid != current, let device = inputs.first(where: { $0.uid == uid }) else { return }
        if AudioDevices.setDefault(device.id, .input) {
            log.info("Default input set to \(device.name, privacy: .public)")
        } else {
            log.error("Failed to set default input to \(device.name, privacy: .public)")
        }
        onInputChange()
    }
}
