import Foundation

// Under SwiftPM, Core is a separate module; build.sh compiles everything as one,
// where there is nothing to import. Core is internal by design (see AGENTS.md),
// hence @testable.
#if canImport(WaylockCore)
@testable import WaylockCore
#endif

private let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// Append one line to `~/Library/Logs/Waylock.log`.
///
/// Every decision input is logged, because the failure that cost the most time
/// was a silent one: an app that logged "started" and then nothing looked
/// identical whether the radio had stalled, the key was absent, or the screen was
/// already locked. The heartbeat exists to make those four cases distinguishable.
func log(_ message: String) {
    let line = "\(clock.string(from: Date()))  \(message)\n"
    let path = NSHomeDirectory() + "/Library/Logs/Waylock.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Render a tracker event. The core reports facts; the wording lives here.
func describe(_ event: Tracker.Event, known: Int) -> String {
    switch event {
    case let .learnedAddress(address, first):
        let count = first ? "first" : "\(known) known"
        return "learned key address \(address.prefix(8)) (\(count))"
    case let .ignoredImpostor(name, address):
        return "ignoring '\(name)' at \(address.prefix(8)): another same-named device is in range"
    case let .newChannel(name, address):
        return "key channel: '\(name)' \(address)"
    }
}