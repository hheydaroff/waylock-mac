import Foundation

/// The user's configuration as one value.
///
/// Read once per tick and passed down, so no module has to know where settings
/// came from, and every test builds one as a literal. Only `SettingsStore` — an
/// adapter — touches `UserDefaults`.
struct Settings: Equatable {
    var enabled = true
    var keyName = "buds3"
    /// Addresses learned for this key device. Empty means "adopt the first one we
    /// see"; see `KeyIdentity`.
    var knownKeyAddresses: [String] = []
    var respectActivity = true
    var windows = Windows()
    /// Log what would have happened instead of locking.
    var dryRun = false

    /// Lowercased: the storage key for this device's away windows.
    var device: String { keyName.lowercased() }
    var awayWindow: AwayWindow { windows.choice(for: device) }
}