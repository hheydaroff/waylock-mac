import Foundation

/// Everything the menu needs, as one value.
struct MenuSnapshot {
    var phase: Phase
    var enabled: Bool
    var dryRun: Bool
    var bluetooth: RadioState
    var keyName: String
    var device: String
    var window: AwayWindow
    var windows: Windows
    var bestChannel: Channel?
    var channelCount: Int
    var respectActivity: Bool
    var loginEnabled: Bool
    var now: Date
}

enum MenuAction: Equatable {
    case toggleEnabled
    case automaticWindow
    case setWindow(Double)
    case toggleActivity
    case lockNow
    case toggleLogin
    case rescan
    case quit
    case pickKey(String)
    case typeKeyName
}

/// One row, as data. `content` says what kind of row it is, so the AppKit layer
/// only has to render and never has to decide.
struct MenuItem: Equatable {
    enum Content: Equatable {
        case action(MenuAction)
        /// Submenu described here, built now.
        case children([MenuItem])
        /// Submenu the app rebuilds every time it opens (the device picker).
        case liveChildren
        case info
        case separator
    }

    var title = ""
    var checked = false
    var content: Content = .info
}

struct MenuStatus: Equatable {
    var title: String
    var detail: String
}

/// What the menu says, as data.
///
/// The menu copy is the app's only explanation of itself — "Waiting for Bluetooth
/// permission" is how a user finds out the app is stuck rather than idle — so it
/// is built away from AppKit and asserted in the tests.
enum MenuModel {
    /// The two live lines at the top, patched every tick.
    static func status(_ s: MenuSnapshot) -> MenuStatus {
        guard s.enabled else { return MenuStatus(title: "Disabled", detail: "—") }

        switch s.bluetooth {
        case .unknown:
            return MenuStatus(title: "Waiting for Bluetooth permission",
                              detail: "approve the prompt — a rebuild changes the signature")
        case .off:
            return MenuStatus(title: "Bluetooth unavailable",
                              detail: "enable it in System Settings > Privacy > Bluetooth")
        case .on:
            break
        }

        let prefix = s.dryRun ? "DRY RUN · " : ""
        switch s.phase {
        case .noKey:
            return MenuStatus(title: prefix + "Waiting for key device",
                              detail: "no '\(s.keyName)' advertising yet")
        case .armed:
            return MenuStatus(title: prefix + "Armed — key is present", detail: channelLine(s))
        case .away:
            return MenuStatus(title: prefix + "Key is away…", detail: channelLine(s))
        case .lockedOut:
            return MenuStatus(title: prefix + "Locked", detail: "waiting for key to return")
        }
    }

    private static func channelLine(_ s: MenuSnapshot) -> String {
        guard let best = s.bestChannel else { return "—" }
        let age = Int(s.now.timeIntervalSince(best.lastSeen))
        let extra = s.channelCount > 1 ? " · +\(s.channelCount - 1)" : ""
        return "\(best.name) · \(best.lastRSSI) dBm · \(age)s ago\(extra)"
    }

    /// Every row below the two status lines.
    static func items(_ s: MenuSnapshot) -> [MenuItem] {
        [
            MenuItem(title: "Enabled", checked: s.enabled, content: .action(.toggleEnabled)),
            MenuItem(title: "Away for", content: .children(awayItems(s))),
            MenuItem(title: "Key Device", content: .liveChildren),
            MenuItem(title: "Don't lock while I'm typing",
                     checked: s.respectActivity, content: .action(.toggleActivity)),
            MenuItem(content: .separator),
            MenuItem(title: "Lock Now (test)", content: .action(.lockNow)),
            MenuItem(title: "Start at Login", checked: s.loginEnabled, content: .action(.toggleLogin)),
            MenuItem(title: "Restart Scanning", content: .action(.rescan)),
            MenuItem(content: .separator),
            MenuItem(title: "Quit Waylock", content: .action(.quit)),
        ]
    }

    private static func awayItems(_ s: MenuSnapshot) -> [MenuItem] {
        let automatic: String
        switch s.window.source {
        case .manual: automatic = "Automatic · use measured"
        case .learned: automatic = "Automatic · learned \(Int(s.window.seconds)) s"
        case .warmup: automatic = "Automatic · learning…"
        }

        var items = [
            MenuItem(title: automatic, checked: s.window.source != .manual,
                     content: .action(.automaticWindow)),
            MenuItem(content: .separator),
        ]
        for seconds in [8.0, 10.0, 15.0, 20.0, 30.0] {
            // Measured at-desk worst case is 10.2 s, so anything below 15 s is a
            // known false-lock risk. Say so in the menu instead of hiding it.
            let risky = seconds < 15 ? " · may false-lock" : ""
            items.append(MenuItem(title: "\(Int(seconds)) seconds\(risky)",
                                  checked: s.windows.manual[s.device] == seconds,
                                  content: .action(.setWindow(seconds))))
        }
        return items
    }

    /// The device picker, rebuilt on open because advertising sets come and go.
    static func keyDevices(_ devices: [NamedDevice], keyName: String) -> [MenuItem] {
        var items: [MenuItem] = []
        if devices.isEmpty {
            items.append(MenuItem(title: "No named devices visible"))
        }
        for device in devices.prefix(20) {
            let isKey = device.name.localizedCaseInsensitiveContains(keyName)
            // Show the measured rate before the choice, not after it: a device
            // that advertises every 11 s cannot support a usable window, and
            // finding that out by walking away and back is a bad way to learn.
            var rate = "  measuring…"
            if let perMinute = device.perMinute() {
                rate = perMinute < 12
                    ? String(format: "  ⚠ %.0f/min — too rare", perMinute)
                    : String(format: "  %.0f/min", perMinute)
            }
            let mark = isKey ? "\u{2713} " : "   "
            items.append(MenuItem(title: "\(mark)\(device.name)  \(device.rssi) dBm\(rate)",
                                  content: .action(.pickKey(device.name))))
        }
        items.append(MenuItem(content: .separator))
        items.append(MenuItem(title: "Type a name\u{2026}", content: .action(.typeKeyName)))
        return items
    }
}