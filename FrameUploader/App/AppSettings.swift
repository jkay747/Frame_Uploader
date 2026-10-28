import Foundation

/// UserDefaults keys shared by the settings screens (via @AppStorage) and the upload pipeline.
enum SettingsKey {
    static let tvHost = "tvHost"
    static let matteType = "matteType"
    static let matteColor = "matteColor"
    static let slideshowEnabled = "slideshowEnabled"
    static let slideshowMinutes = "slideshowMinutes"
    static let slideshowShuffle = "slideshowShuffle"
    static let replacePrevious = "replacePrevious"
    static let skipDuplicates = "skipDuplicates"
    static let tvMatteTypes = "tvMatteTypes"
    static let tvMatteColors = "tvMatteColors"
}

enum AppSettings {
    // Keep these in sync with the default values on the @AppStorage properties in the views.
    static let defaultMatteType = "none"
    static let defaultMatteColor = "polar"
    static let defaultSlideshowEnabled = true
    static let defaultSlideshowMinutes = 15
    static let defaultSlideshowShuffle = true
    static let defaultReplacePrevious = true
    static let defaultSkipDuplicates = true

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.tvHost: "",
            SettingsKey.matteType: defaultMatteType,
            SettingsKey.matteColor: defaultMatteColor,
            SettingsKey.slideshowEnabled: defaultSlideshowEnabled,
            SettingsKey.slideshowMinutes: defaultSlideshowMinutes,
            SettingsKey.slideshowShuffle: defaultSlideshowShuffle,
            SettingsKey.replacePrevious: defaultReplacePrevious,
            SettingsKey.skipDuplicates: defaultSkipDuplicates,
        ])
    }

    /// Accepts "192.168.1.20", "http://192.168.1.20/", " frame.local " and returns the bare host.
    static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        // Drop a port if one was typed; the app picks the TV's ports itself.
        if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host
    }
}

/// A snapshot of the settings that drive one upload run.
struct UploadOptions {
    var host: String
    var matteID: String
    var skipDuplicates: Bool
    var replacePrevious: Bool
    var slideshowEnabled: Bool
    var slideshowMinutes: Int
    var slideshowShuffle: Bool

    static func current(_ defaults: UserDefaults = .standard) -> UploadOptions {
        UploadOptions(
            host: AppSettings.normalizedHost(defaults.string(forKey: SettingsKey.tvHost) ?? ""),
            matteID: Matte.id(
                type: defaults.string(forKey: SettingsKey.matteType) ?? AppSettings.defaultMatteType,
                color: defaults.string(forKey: SettingsKey.matteColor) ?? AppSettings.defaultMatteColor
            ),
            skipDuplicates: defaults.bool(forKey: SettingsKey.skipDuplicates),
            replacePrevious: defaults.bool(forKey: SettingsKey.replacePrevious),
            slideshowEnabled: defaults.bool(forKey: SettingsKey.slideshowEnabled),
            slideshowMinutes: defaults.integer(forKey: SettingsKey.slideshowMinutes),
            slideshowShuffle: defaults.bool(forKey: SettingsKey.slideshowShuffle)
        )
    }
}

/// Samsung's mat ("matte") identifiers are "<style>_<color>", or "none" for a full-screen photo.
enum Matte {
    /// Styles that suit a full 16:9 photo. The TV's own list replaces this once the app has connected.
    static let defaultTypes = ["none", "modernthin", "modern", "modernwide", "flexible", "shadowbox"]
    static let defaultColors = [
        "polar", "black", "neutral", "antique", "warm", "sand", "seafoam", "sage",
        "burgandy", "navy", "apricot", "byzantine", "lavender", "redorange", "skyblue", "turqoise",
    ]

    static func id(type: String, color: String) -> String {
        type == "none" ? "none" : "\(type)_\(color)"
    }

    static func displayName(_ raw: String) -> String {
        let names = [
            "none": "None (full screen)",
            "modernthin": "Modern – thin",
            "modern": "Modern",
            "modernwide": "Modern – wide",
            "flexible": "Flexible",
            "shadowbox": "Shadow box",
            "panoramic": "Panoramic",
            "triptych": "Triptych",
            "mix": "Mix",
            "squares": "Squares",
            "polar": "Polar white",
            "burgandy": "Burgundy",
            "redorange": "Red-orange",
            "skyblue": "Sky blue",
            "turqoise": "Turquoise",
        ]
        if let name = names[raw] { return name }
        return raw.prefix(1).uppercased() + String(raw.dropFirst())
    }

    static var availableTypes: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: SettingsKey.tvMatteTypes) ?? []
        return stored.isEmpty ? defaultTypes : stored
    }

    static var availableColors: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: SettingsKey.tvMatteColors) ?? []
        return stored.isEmpty ? defaultColors : stored
    }
}

/// Slideshow intervals offered by the TV's own Art Mode menu, in minutes.
struct SlideshowInterval: Identifiable {
    let minutes: Int
    let label: String

    var id: Int { minutes }

    static let options = [
        SlideshowInterval(minutes: 3, label: "Every 3 minutes"),
        SlideshowInterval(minutes: 15, label: "Every 15 minutes"),
        SlideshowInterval(minutes: 60, label: "Every hour"),
        SlideshowInterval(minutes: 720, label: "Every 12 hours"),
        SlideshowInterval(minutes: 1440, label: "Every day"),
        SlideshowInterval(minutes: 10080, label: "Every week"),
    ]

    static func label(for minutes: Int) -> String {
        options.first { $0.minutes == minutes }?.label.lowercased() ?? "every \(minutes) minutes"
    }
}

/// Pairing tokens issued by the TV, one per host.
enum TokenStore {
    private static func key(_ host: String) -> String { "tvToken.\(host)" }

    static func token(for host: String) -> String? {
        UserDefaults.standard.string(forKey: key(host))
    }

    static func save(_ token: String, for host: String) {
        UserDefaults.standard.set(token, forKey: key(host))
    }

    static func remove(for host: String) {
        UserDefaults.standard.removeObject(forKey: key(host))
    }
}
