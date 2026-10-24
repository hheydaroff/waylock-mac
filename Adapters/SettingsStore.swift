import Foundation

// Under SwiftPM, Core is a separate module; build.sh compiles everything as one,
// where there is nothing to import. Core is internal by design (see AGENTS.md),
// hence @testable.
#if canImport(WaylockCore)
@testable import WaylockCore
#endif

/// Translates one `Settings` value to and from `UserDefaults`.
///
/// The only module that touches them, so preferences are written in one place and
/// every other module takes settings as a parameter. The keys are the ones this
/// app has always used, so an existing install keeps its device and windows.
struct SettingsStore {
    /// The domain is named explicitly, not inherited from `.standard`.
    ///
    /// `.standard` means "the current bundle's domain", which is right inside the
    /// app and silently wrong everywhere else: a bare executable in build/ has no
    /// bundle identifier, so it reads and writes the *global* domain and every
    /// setting looks unset. That is how a CLI run once calibrated "buds3" — the
    /// hardcoded fallback — while the app's own prefs said something else.
    static let domain = "io.github.hheydaroff.waylock"

    private let defaults: UserDefaults

    init(_ defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.domain) ?? .standard
    }

    func load() -> Settings {
        var settings = Settings()
        settings.enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        settings.keyName = defaults.string(forKey: "keyName") ?? settings.keyName
        settings.knownKeyAddresses = defaults.stringArray(forKey: "knownKeyAddresses") ?? []
        settings.respectActivity = defaults.object(forKey: "respectActivity") as? Bool ?? true
        settings.windows = Windows(manual: doubles("manualWindows"), learned: doubles("learnedWindows"))
        // WAYLOCK_DRYRUN=1 logs "WOULD LOCK" instead of locking. Never locks.
        settings.dryRun = ProcessInfo.processInfo.environment["WAYLOCK_DRYRUN"] != nil
        return settings
    }

    func save(_ settings: Settings) {
        defaults.set(settings.enabled, forKey: "enabled")
        defaults.set(settings.keyName, forKey: "keyName")
        defaults.set(settings.knownKeyAddresses, forKey: "knownKeyAddresses")
        defaults.set(settings.respectActivity, forKey: "respectActivity")
        defaults.set(settings.windows.manual, forKey: "manualWindows")
        defaults.set(settings.windows.learned, forKey: "learnedWindows")
    }

    private func doubles(_ key: String) -> [String: Double] {
        (defaults.dictionary(forKey: key) ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}