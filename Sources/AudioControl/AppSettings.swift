import Foundation

/// Per-app overrides. An app with all defaults is not stored.
struct AppAudioSettings: Codable, Equatable {
    var name: String
    /// 0–100. Applied as gain on the app's tapped audio, or as the app's own volume where `MusicVolume` handles it.
    var volume = 100
    /// For apps whose own volume is set (Music): its volume before the first change, restored on reset.
    var originalVolume: Int?
    /// Output device for the app; nil follows the system default output.
    var outputUID: String?
    var outputName: String?
    /// Input device made the system default input while the app captures; nil leaves the default input alone.
    var inputUID: String?
    var inputName: String?

    var isDefault: Bool { volume == (originalVolume ?? 100) && outputUID == nil && inputUID == nil }

    var summary: String? {
        var parts: [String] = []
        if volume != 100 { parts.append("\(volume)%") }
        if let outputName { parts.append("Out: \(outputName)") }
        if let inputName { parts.append("In: \(inputName)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor
final class AppSettingsStore {
    private static let key = "appSettings"
    private let defaults: UserDefaults
    private(set) var all: [String: AppAudioSettings]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: AppAudioSettings].self, from: $0) } ?? [:]
    }

    subscript(bundleID: String) -> AppAudioSettings? { all[bundleID] }

    func update(_ bundleID: String, name: String, _ change: (inout AppAudioSettings) -> Void) {
        var settings = all[bundleID] ?? AppAudioSettings(name: name)
        settings.name = name
        change(&settings)
        all[bundleID] = settings.isDefault ? nil : settings
        save()
    }

    func reset(_ bundleID: String) {
        all[bundleID] = nil
        save()
    }

    func resetAll() {
        all = [:]
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }
}
