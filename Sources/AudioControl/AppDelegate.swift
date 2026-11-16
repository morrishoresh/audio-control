import AppKit
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private static let volumeChoices = stride(from: 10, through: 100, by: 10).map { $0 }
    /// Bluetooth devices often reconnect a few seconds after wake/login, so keep looking for a while.
    private static let retryInterval: TimeInterval = 1
    private static let maxAttempts = 20

    /// Menu item payload for picking a target device; `uid == nil` clears the target.
    private struct Choice {
        let direction: Direction
        let uid: String?
    }

    /// Menu item payload for picking a target volume; `percent == nil` means "Don't Change".
    private struct VolumeChoice {
        let direction: Direction
        let percent: Int?
    }

    /// Menu item payload for picking an app's device; `uid == nil` means system default.
    private struct AppDeviceChoice {
        let bundleID: String
        let appName: String
        let direction: Direction
        let uid: String?
    }

    /// Menu item payload identifying an app.
    private struct AppRef {
        let bundleID: String
        let name: String
    }

    /// Bundle ID the app had before it was renamed; its settings are copied over once.
    private static let legacyDefaultsDomain = "com.morrishoresh.AudioAutoSwitch"
    private static let legacyKeys = [
        "targetDeviceUID", "targetDeviceName", "targetVolume", "targetInputUID", "targetInputName", "targetInputVolume",
    ]

    private let log = Logger(subsystem: "com.morrishoresh.AudioControl", category: "switch")
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var retryTimer: Timer?
    private var attempts = 0
    private var pending: [Direction] = []
    private let router = AppAudioRouter()
    private let playerState = PlayerStateMonitor()
    private let musicVolume = MusicVolume()
    /// Items of the open menu that show an app's settings, updated live while the menu stays open (sliders).
    private var appMenuItems: [String: (item: NSMenuItem, reset: NSMenuItem, running: Bool)] = [:]
    private weak var resetAllItem: NSMenuItem?
    /// Music's slider in the open menu, re-read every second so changes made elsewhere (volume keys) show up.
    private weak var musicSlider: VolumeSliderView?
    private var musicPollTimer: Timer?

    private func volumeKey(_ direction: Direction) -> String {
        direction == .output ? "targetVolume" : "targetInputVolume"
    }

    /// Volume percentage (10–100) applied to the target device, or nil to leave volume and mute unchanged.
    /// Defaults to nil. Stored as 0 for nil.
    private func targetVolume(_ direction: Direction) -> Int? {
        let stored = defaults.integer(forKey: volumeKey(direction))
        return stored == 0 ? nil : stored
    }

    private func setTargetVolume(_ direction: Direction, _ percent: Int?) {
        defaults.set(percent ?? 0, forKey: volumeKey(direction))
    }

    private func targetVolumeLabel(_ direction: Direction) -> String {
        targetVolume(direction).map { "\($0)%" } ?? "Don't Change"
    }

    private func uidKey(_ direction: Direction) -> String {
        direction == .output ? "targetDeviceUID" : "targetInputUID"
    }

    private func nameKey(_ direction: Direction) -> String {
        direction == .output ? "targetDeviceName" : "targetInputName"
    }

    private func targetUID(_ direction: Direction) -> String? {
        defaults.string(forKey: uidKey(direction))
    }

    private func targetName(_ direction: Direction) -> String? {
        defaults.string(forKey: nameKey(direction))
    }

    private func setTarget(_ direction: Direction, uid: String?, name: String?) {
        defaults.set(uid, forKey: uidKey(direction))
        defaults.set(name, forKey: nameKey(direction))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacySettings()
        playerState.readInitialState()
        router.globalInputTarget = { [weak self] in self?.targetUID(.input) }
        router.onInputChange = { [weak self] in self?.updateIcon() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        AudioDevices.observeChanges { [weak self] in
            MainActor.assumeIsolated {
                self?.updateIcon()
                self?.router.refresh()
            }
        }

        log.info("Launched")
        applyWithRetry()
        router.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        router.stopAll()
    }

    @objc private func didWake() {
        log.info("Woke from sleep")
        applyWithRetry()
        router.rebuild()
    }

    private func migrateLegacySettings() {
        let migratedKey = "migratedLegacySettings"
        guard !defaults.bool(forKey: migratedKey) else { return }
        if let legacy = UserDefaults(suiteName: Self.legacyDefaultsDomain) {
            for key in Self.legacyKeys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: migratedKey)
    }

    // MARK: - Switching

    private func applyWithRetry() {
        retryTimer?.invalidate()
        attempts = 0
        pending = Direction.allCases.filter { targetUID($0) != nil }
        if applyPending() { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if self.applyPending() {
                    timer.invalidate()
                }
            }
        }
    }

    /// Applies each pending target that is connected. Returns true when nothing is left to retry.
    private func applyPending() -> Bool {
        attempts += 1
        pending = pending.filter { !apply($0) }
        guard !pending.isEmpty else { return true }
        guard attempts >= Self.maxAttempts else { return false }
        for direction in pending {
            let target = targetName(direction) ?? targetUID(direction) ?? "none"
            log.info("\(direction.label, privacy: .public) target \(target, privacy: .public) not connected, doing nothing")
        }
        pending = []
        return true
    }

    /// Returns true if the target device was found (whether or not every step succeeded).
    private func apply(_ direction: Direction) -> Bool {
        guard let uid = targetUID(direction) else { return true }
        if direction == .input, router.inputOverrideUID != nil {
            log.info("Input held by a per-app override, global target applied when it ends")
            return true
        }
        guard let device = AudioDevices.devices(direction).first(where: { $0.uid == uid }) else { return false }

        if AudioDevices.defaultDeviceID(direction) != device.id, !AudioDevices.setDefault(device.id, direction) {
            log.error("Failed to set default \(direction.label, privacy: .public) to \(device.name, privacy: .public)")
        }
        if direction == .output, AudioDevices.systemOutputDeviceID() != device.id, !AudioDevices.setSystemOutput(device.id) {
            log.error("Failed to set sound effects output to \(device.name, privacy: .public)")
        }
        guard let volume = targetVolume(direction) else {
            log.info("\(direction.label, privacy: .public) switched to \(device.name, privacy: .public), volume unchanged")
            return true
        }
        if !AudioDevices.setVolume(device.id, direction, Float32(volume) / 100) {
            log.error("\(device.name, privacy: .public) has no settable \(direction.label, privacy: .public) volume")
        }
        AudioDevices.unmute(device.id, direction)
        log.info("\(direction.label, privacy: .public) switched to \(device.name, privacy: .public) at \(volume)%")
        return true
    }

    // MARK: - Icon

    /// Normal speaker when every configured target is the current device, warning badge otherwise.
    private func updateIcon() {
        var onTarget = true
        var lines: [String] = []
        for direction in Direction.allCases {
            let currentID = AudioDevices.defaultDeviceID(direction)
            let current = AudioDevices.devices(direction).first { $0.id == currentID }
            let expected = direction == .input ? router.inputOverrideUID ?? targetUID(.input) : targetUID(.output)
            if let expected, current?.uid != expected {
                onTarget = false
            }
            lines.append("\(direction.label): \(current?.name ?? "unknown")")
        }
        let symbol = onTarget ? "speaker.wave.3" : "speaker.badge.exclamationmark"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AudioControl")
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        appMenuItems = [:]

        var anyConnected = false
        for direction in Direction.allCases {
            if addTargetItems(to: menu, direction) {
                anyConnected = true
            }
            addVolumeItem(to: menu, direction)
            menu.addItem(.separator())
        }

        addAppItems(to: menu)
        menu.addItem(.separator())

        let applyItem = NSMenuItem(title: "Apply Now", action: #selector(applyNow), keyEquivalent: "")
        applyItem.target = self
        applyItem.isEnabled = anyConnected
        menu.addItem(applyItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Adds the target status line and device picker for one direction. Returns true if its target is connected.
    private func addTargetItems(to menu: NSMenu, _ direction: Direction) -> Bool {
        let devices = AudioDevices.devices(direction)
        let uid = targetUID(direction)
        let connected = devices.contains { $0.uid == uid }
        let title = if let name = targetName(direction) {
            "Target \(direction.label): \(name)" + (connected ? "" : " (not connected)")
        } else {
            "Target \(direction.label): none"
        }
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))

        let deviceMenu = NSMenu()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Choice(direction: direction, uid: device.uid)
            item.state = device.uid == uid ? .on : .off
            deviceMenu.addItem(item)
        }
        if uid != nil {
            deviceMenu.addItem(.separator())
            let clear = NSMenuItem(title: "None", action: #selector(selectTarget(_:)), keyEquivalent: "")
            clear.target = self
            clear.representedObject = Choice(direction: direction, uid: nil)
            deviceMenu.addItem(clear)
        }
        let deviceItem = NSMenuItem(title: "Target \(direction.label) Device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        return connected
    }

    private func addVolumeItem(to menu: NSMenu, _ direction: Direction) {
        let current = targetVolume(direction)
        let volumeMenu = NSMenu()
        let unchanged = NSMenuItem(title: "Don't Change", action: #selector(selectVolume(_:)), keyEquivalent: "")
        unchanged.target = self
        unchanged.representedObject = VolumeChoice(direction: direction, percent: nil)
        unchanged.state = current == nil ? .on : .off
        volumeMenu.addItem(unchanged)
        volumeMenu.addItem(.separator())
        for percent in Self.volumeChoices {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(selectVolume(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = VolumeChoice(direction: direction, percent: percent)
            item.state = percent == current ? .on : .off
            volumeMenu.addItem(item)
        }
        let title = "Target \(direction.label) Volume: \(targetVolumeLabel(direction))"
        let volumeItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        musicPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMusicSlider() }
        }
        // Common modes, so it also fires while the menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        musicPollTimer = timer
    }

    private func refreshMusicSlider() {
        guard musicSlider != nil else { return }
        musicVolume.refresh { [weak self] volume in
            self?.musicSlider?.setPercent(volume)
            self?.syncMusicVolumeSetting(volume)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        musicPollTimer?.invalidate()
        musicPollTimer = nil
        // Drops taps no longer needed, e.g. a volume slider dragged back to 100%.
        router.refresh()
    }

    // MARK: - Per-app menu

    /// Small accent-colored dot shown next to apps with changed settings.
    private static let changedIndicator: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 6, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Changed")?
            .withSymbolConfiguration(config)
    }()

    private func addAppItems(to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: "Apps"))
        let running = AudioProcesses.apps()
        let runningIDs = Set(running.map(\.bundleID))
        var entries = running.map {
            (
                bundleID: $0.bundleID,
                name: $0.name,
                icon: $0.icon,
                running: true,
                playing: $0.isRunningOutput || playerState.isPlaying($0.bundleID)
            )
        }
        for (bundleID, settings) in router.settings.all where !runningIDs.contains(bundleID) {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            entries.append((bundleID, settings.name, icon, false, false))
        }
        // Apps playing audio first, then a separator, then the rest; each group by name.
        entries.sort {
            if $0.playing != $1.playing { return $0.playing }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if entries.isEmpty {
            let none = NSMenuItem(title: "No apps using audio", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        let outputs = AudioDevices.devices(.output)
        let inputs = AudioDevices.devices(.input)
        for (index, entry) in entries.enumerated() {
            if index > 0, entries[index - 1].playing, !entry.playing {
                menu.addItem(.separator())
            }
            let settings = router.settings[entry.bundleID]
            let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
            let icon = entry.icon?.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.onStateImage = Self.changedIndicator
            let (submenu, reset) = appMenu(entry.bundleID, entry.name, settings, outputs: outputs, inputs: inputs)
            item.submenu = submenu
            menu.addItem(item)
            appMenuItems[entry.bundleID] = (item, reset, entry.running)
        }

        menu.addItem(.separator())
        let resetAll = NSMenuItem(title: "Reset All Apps", action: #selector(resetAllApps), keyEquivalent: "")
        resetAll.target = self
        menu.addItem(resetAll)
        resetAllItem = resetAll
        updateAppMenuItems()
    }

    /// Shows the current settings in the open menu: changed indicator, summary, Reset / Reset All Apps enabled.
    private func updateAppMenuItems() {
        for (bundleID, entry) in appMenuItems {
            let settings = router.settings[bundleID]
            let subtitle = [entry.running ? nil : "Not running", settings?.summary].compactMap { $0 }
            entry.item.subtitle = subtitle.isEmpty ? nil : subtitle.joined(separator: " · ")
            entry.item.state = settings == nil ? .off : .on
            entry.reset.isEnabled = settings != nil
        }
        resetAllItem?.isEnabled = !router.settings.all.isEmpty
    }

    private func appMenu(
        _ bundleID: String,
        _ name: String,
        _ settings: AppAudioSettings?,
        outputs: [AudioDevice],
        inputs: [AudioDevice]
    ) -> (menu: NSMenu, reset: NSMenuItem) {
        let menu = NSMenu()
        let volumeItem = NSMenuItem()
        if MusicVolume.handles(bundleID) {
            let slider = VolumeSliderView(percent: musicVolume.cached ?? settings?.volume ?? 100) { [weak self] percent in
                self?.setMusicVolume(name: name, percent)
            }
            musicSlider = slider
            refreshMusicSlider()
            volumeItem.view = slider
        } else {
            volumeItem.view = VolumeSliderView(percent: settings?.volume ?? 100) { [weak self] percent in
                self?.router.setVolume(bundleID, name: name, percent)
                self?.updateAppMenuItems()
            }
        }
        menu.addItem(volumeItem)
        menu.addItem(.separator())

        for direction in Direction.allCases {
            let uid = direction == .output ? settings?.outputUID : settings?.inputUID
            let savedName = direction == .output ? settings?.outputName : settings?.inputName
            let devices = direction == .output ? outputs : inputs
            let deviceMenu = NSMenu()
            let systemDefault = NSMenuItem(title: "System Default", action: #selector(selectAppDevice(_:)), keyEquivalent: "")
            systemDefault.target = self
            systemDefault.representedObject = AppDeviceChoice(bundleID: bundleID, appName: name, direction: direction, uid: nil)
            systemDefault.state = uid == nil ? .on : .off
            deviceMenu.addItem(systemDefault)
            deviceMenu.addItem(.separator())
            for device in devices {
                let item = NSMenuItem(title: device.name, action: #selector(selectAppDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = AppDeviceChoice(bundleID: bundleID, appName: name, direction: direction, uid: device.uid)
                item.state = device.uid == uid ? .on : .off
                deviceMenu.addItem(item)
            }
            var current = savedName ?? "System Default"
            if let uid, !devices.contains(where: { $0.uid == uid }) {
                current += " (not connected)"
            }
            let deviceItem = NSMenuItem(title: "\(direction.label): \(current)", action: nil, keyEquivalent: "")
            deviceItem.submenu = deviceMenu
            menu.addItem(deviceItem)
        }

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset", action: #selector(resetApp(_:)), keyEquivalent: "")
        reset.target = self
        reset.representedObject = AppRef(bundleID: bundleID, name: name)
        menu.addItem(reset)
        return (menu, reset)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(resetApp(_:)):
            (item.representedObject as? AppRef).map { router.settings[$0.bundleID] != nil } ?? false
        case #selector(resetAllApps):
            !router.settings.all.isEmpty
        default:
            true
        }
    }

    @objc private func selectAppDevice(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AppDeviceChoice else { return }
        let deviceName = choice.uid == nil ? nil : sender.title
        router.settings.update(choice.bundleID, name: choice.appName) { settings in
            switch choice.direction {
            case .output:
                settings.outputUID = choice.uid
                settings.outputName = deviceName
            case .input:
                settings.inputUID = choice.uid
                settings.inputName = deviceName
            }
        }
        router.refresh()
    }

    @objc private func resetApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppRef else { return }
        restoreMusicVolume(router.settings[app.bundleID], app.bundleID)
        router.settings.reset(app.bundleID)
        router.refresh()
    }

    private func setMusicVolume(name: String, _ percent: Int) {
        let before = musicVolume.cached
        musicVolume.set(percent)
        router.settings.update(MusicVolume.bundleID, name: name) { settings in
            if settings.originalVolume == nil {
                settings.originalVolume = before ?? 100
            }
            settings.volume = percent
        }
        updateAppMenuItems()
    }

    /// Keeps the stored volume in step with Music's actual volume, which can also be changed in Music itself.
    private func syncMusicVolumeSetting(_ volume: Int) {
        guard let settings = router.settings[MusicVolume.bundleID], settings.originalVolume != nil else { return }
        router.settings.update(MusicVolume.bundleID, name: settings.name) { $0.volume = volume }
        updateAppMenuItems()
    }

    private func restoreMusicVolume(_ settings: AppAudioSettings?, _ bundleID: String) {
        guard MusicVolume.handles(bundleID), let original = settings?.originalVolume else { return }
        musicVolume.set(original)
    }

    /// Every app back to System Default input/output and its original volume.
    @objc private func resetAllApps() {
        restoreMusicVolume(router.settings[MusicVolume.bundleID], MusicVolume.bundleID)
        router.settings.resetAll()
        router.refresh()
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        setTarget(choice.direction, uid: choice.uid, name: choice.uid == nil ? nil : sender.title)
        updateIcon()
        applyWithRetry()
    }

    @objc private func selectVolume(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? VolumeChoice else { return }
        setTargetVolume(choice.direction, choice.percent)
        applyWithRetry()
    }

    @objc private func applyNow() {
        applyWithRetry()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
