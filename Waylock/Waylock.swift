// Waylock — lock your Mac when your Bluetooth earbuds walk away.
//
// Verified on macOS 27.0.1 / M4 Max:
//   • Galaxy Buds3 Pro advertise ~0.4 Hz with a static public BLE address
//   • at desk, no stream is ever absent for 10 s (0 false locks in 189 s)
//   • walk away -> all streams silent for 16-17 s
//   • per-channel gaps reach 31 s at desk, so we require ALL channels absent

import AppKit
import CoreBluetooth
import IOKit
import ServiceManagement

// ─────────────────────────────── config ───────────────────────────────

enum Prefs {
    /// Redirectable so tests run in a sandbox suite and can never write junk into
    /// the user's real preferences. exit() skips defer, so saving and restoring
    /// the real domain would not have been reliable either.
    static var defaults: UserDefaults = .standard

    /// WAYLOCK_DRYRUN=1 -> log "WOULD LOCK" instead of locking. Never locks.
    static let isDryRun = ProcessInfo.processInfo.environment["WAYLOCK_DRYRUN"] != nil

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    /// Effective away window. A manual pick wins over a learned value, which
    /// wins over the deliberately slack warm-up. See WindowPolicy.
    static var awayWindow: Double {
        get { WindowPolicy.effective }
        set { WindowPolicy.useManual(newValue) }
    }
    /// Windows derived from observation, keyed by lowercased keyName.
    static var learnedWindows: [String: Double] {
        get { (defaults.dictionary(forKey: "learnedWindows") ?? [:])
                .compactMapValues { ($0 as? NSNumber)?.doubleValue } }
        set { defaults.set(newValue, forKey: "learnedWindows") }
    }
    /// Windows the user chose by hand. These always win, and are why an
    /// explicit choice never gets silently "corrected" by learning.
    static var manualWindows: [String: Double] {
        get { (defaults.dictionary(forKey: "manualWindows") ?? [:])
                .compactMapValues { ($0 as? NSNumber)?.doubleValue } }
        set { defaults.set(newValue, forKey: "manualWindows") }
    }
    /// Don't lock while the user is actively typing/clicking.
    static var respectActivity: Bool {
        get { defaults.object(forKey: "respectActivity") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "respectActivity") }
    }
    /// Name fragment used to pick the key device.
    static var keyName: String {
        get { defaults.string(forKey: "keyName") ?? "buds3" }
        set { defaults.set(newValue, forKey: "keyName") }
    }
    /// Addresses this Mac has learned belong to the key device. Lets us tell our
    /// own strap from a colleague's identical one.
    static var knownKeyAddresses: [String] {
        get { defaults.stringArray(forKey: "knownKeyAddresses") ?? [] }
        set { defaults.set(newValue, forKey: "knownKeyAddresses") }
    }
}

/// How the away window is chosen for the current key device.
///
/// Advertising rate differs by device by up to 5x (a strap manages 0.67 Hz, one
/// stray buds stream managed 0.09 Hz), so a single constant is either too slow
/// for a chatty device or false-locks on a quiet one. The window is therefore
/// learned per device from its own union-gap distribution, starting from a
/// deliberately slack warm-up: being slow to lock costs seconds once, being
/// quick costs a locked screen while you are working.
enum WindowPolicy {
    /// Used until this device has been observed long enough to measure.
    static let warmup: Double = 20
    static let minWindow: Double = 12
    static let maxWindow: Double = 60
    /// How long to observe before trusting a measurement.
    static let learnPeriod: TimeInterval = 180
    /// Gaps needed before a recommendation is made at all.
    static let minSamples = 20

    private static var deviceKey: String { Prefs.keyName.lowercased() }

    static var effective: Double {
        let k = deviceKey
        if let m = Prefs.manualWindows[k] { return m }
        if let l = Prefs.learnedWindows[k] { return l }
        return warmup
    }

    static var isLearning: Bool {
        let k = deviceKey
        return Prefs.manualWindows[k] == nil && Prefs.learnedWindows[k] == nil
    }

    static var learned: Double? { Prefs.learnedWindows[deviceKey] }
    static var isManual: Bool { Prefs.manualWindows[deviceKey] != nil }

    static func useManual(_ v: Double) {
        var m = Prefs.manualWindows
        m[deviceKey] = v
        Prefs.manualWindows = m
    }

    static func useLearned(_ v: Double) {
        var l = Prefs.learnedWindows
        l[deviceKey] = v
        Prefs.learnedWindows = l
        var m = Prefs.manualWindows     // "use the measured value" drops any override
        m.removeValue(forKey: deviceKey)
        Prefs.manualWindows = m
    }

    static func forget() {
        var l = Prefs.learnedWindows
        l.removeValue(forKey: deviceKey)
        Prefs.learnedWindows = l
        var m = Prefs.manualWindows
        m.removeValue(forKey: deviceKey)
        Prefs.manualWindows = m
    }

    /// Derive a window from observed union gaps.
    ///
    /// A real absence and a slowly-advertising device look identical in a raw
    /// gap list, so gaps beyond 10x the median are discarded as absences rather
    /// than learned as device behaviour. The remainder is scaled by 1.5 — the
    /// headroom that was validated by hand on the buds baseline (10.2 s worst
    /// case at the desk -> 15 s window, zero false locks in 600 samples).
    ///
    /// The cutoff has a floor of 1.25x the minimum window. Without it a chatty
    /// device (median 0.5 s) would treat its own honest 8 s gap as an absence
    /// and learn a window smaller than the gap it must cover.
    static func recommend(from gaps: [Double]) -> (window: Double, worst: Double, kept: Int)? {
        guard gaps.count >= minSamples else { return nil }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let cutoff = max(minWindow * 1.25, median * 10)
        let kept = sorted.filter { $0 <= cutoff }
        guard let worst = kept.last else { return nil }
        let raw = max(minWindow, worst * 1.5)
        return (min(maxWindow, (raw * 10).rounded(.up) / 10), worst, kept.count)
    }
}

private let logClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func log(_ msg: String) {
    let line = "\(logClock.string(from: Date()))  \(msg)\n"
    let path = NSHomeDirectory() + "/Library/Logs/Waylock.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// ─────────────────────────── private lock API ───────────────────────────
//
// CGSession -suspend is gone on modern macOS. login.framework still exports
// SACLockScreenImmediate, but it reports success even when nothing locked,
// so we always verify through CGSSessionScreenIsLocked.

@_silgen_name("CGSessionCopyCurrentDictionary")
func CGSessionCopyCurrentDictionary() -> CFDictionary?

enum Locker {
    private static var handle: UnsafeMutableRawPointer?

    static func screenIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    @discardableResult
    static func lock() -> Bool {
        if handle == nil {
            handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
                            RTLD_LAZY)
        }
        guard let h = handle, let sym = dlsym(h, "SACLockScreenImmediate") else {
            log("lock: could not resolve SACLockScreenImmediate")
            return false
        }
        typealias Fn = @convention(c) () -> Int32
        let rc = unsafeBitCast(sym, to: Fn.self)()

        // Verify — the private call lies.
        for _ in 0..<20 {
            if screenIsLocked() {
                log("lock: confirmed (rc=\(rc))")
                return true
            }
            usleep(150_000)
        }
        log("lock: rc=\(rc) but screen did not lock")
        return false
    }

    /// Seconds since the last keyboard/mouse event.
    static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return prop.doubleValue / 1_000_000_000
    }
}

// ───────────────────────── presence monitoring ─────────────────────────

struct Channel {
    var name: String
    var lastSeen: Date
    var lastRSSI: Int
    var packets: Int
}

/// Any advertiser that announced a name, whether or not it is the key.
struct NamedDevice {
    var name: String
    var lastSeen: Date
    var rssi: Int
    var uuid: UUID
    var firstSeen: Date
    var packets: Int

    /// Packets per minute since first sighting. Drives the picker's "too rare"
    /// warning: a device heard every 11 s cannot support a tight window, and
    /// learning that after selecting it is a worse experience than seeing it.
    func perMinute() -> Double? {
        let span = lastSeen.timeIntervalSince(firstSeen)
        guard span >= 30 else { return nil }
        return Double(packets) / span * 60
    }
}

enum Presence { case noKey, present, away }

final class PresenceMonitor: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private(set) var channels: [UUID: Channel] = [:]
    private(set) var named: [String: NamedDevice] = [:]
    /// Every peripheral recently seen whose name matches the key, ours or not.
    private var matchSeen: [UUID: Date] = [:]
    /// Union inter-arrival gaps for the key device: the statistic the away
    /// window is derived from. Presence is "any channel heard recently", so the
    /// gap between *any* two packets is what matters, not per-channel timing.
    private(set) var gaps: [Double] = []
    private var lastUnion: Date?
    private var lastImpostorLog = Date(timeIntervalSince1970: 0)
    private static let maxKnown = 8
    private static let rivalWindow: TimeInterval = 10
    private(set) var scanning = false
    private(set) var bluetoothState: CBManagerState = .unknown

    private var watchdog: Timer?
    private var centralRetries = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)

        // CoreBluetooth occasionally never delivers its first state callback at
        // all: the app keeps running, the menu says "unavailable", and the log
        // stays empty while nothing is scanned. That is the worst failure mode
        // this app can have, because it looks like it is working. Watch for it
        // and rebuild the central rather than sitting there blind.
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.recoverIfRadioStalled()
        }
        if let w = watchdog { RunLoop.main.add(w, forMode: .common) }
    }

    private func recoverIfRadioStalled() {
        guard central.state != .poweredOn, Prefs.enabled else { return }
        // Keep trying for ~10 minutes rather than giving up after a minute:
        // when the cause is a pending permission prompt the user may be away,
        // and a single unlock should be enough to bring the app back to life.
        guard centralRetries < 40 else { return }
        centralRetries += 1
        if centralRetries <= 3 || centralRetries % 10 == 0 {
            log("bluetooth stalled at state \(central.state.rawValue)"
                + " — recreating central (attempt \(centralRetries))"
                + (central.state == .unknown
                   ? "  [if a permission prompt is pending: every rebuild changes the"
                     + " ad-hoc signature, so macOS asks again — approve it, or sign"
                     + " with a stable identity]"
                   : ""))
        }
        scanning = false
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state != bluetoothState {
            log("bluetooth state -> \(c.state.rawValue)")
        }
        bluetoothState = c.state
        guard c.state == .poweredOn else {
            scanning = false
            return
        }
        centralRetries = 0
        startScanning()
    }

    func startScanning() {
        guard central.state == .poweredOn, !scanning else { return }
        central.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanning = true
        log("scanning")
    }

    func restartScanning() {
        if scanning { central.stopScan(); scanning = false }
        startScanning()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi R: NSNumber) {
        let rssi = R.intValue
        guard rssi != 127, rssi != 0 else { return }   // 127 = "not available"
        let name = p.name ?? (d[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        ingest(name: name, id: p.identifier, rssi: rssi)
    }

    /// The whole decision, deliberately separated from CoreBluetooth so that
    /// --identity-test can drive it directly, including an impossible-to-stage
    /// impostor. Anything that only works with real radios is not tested here.
    func ingest(name: String, id: UUID, rssi: Int) {
        guard !name.isEmpty else { return }

        // Remember every named advertiser so the menu can offer a device picker.
        if var nd = named[name] {
            nd.lastSeen = Date(); nd.rssi = rssi; nd.uuid = id; nd.packets += 1
            named[name] = nd
        } else {
            named[name] = NamedDevice(name: name, lastSeen: Date(), rssi: rssi, uuid: id,
                                      firstSeen: Date(), packets: 1)
        }

        // Match on the name only. A full device name is specific enough, and name
        // matching survives the device changing its BLE address (the Buds3 Pro was
        // seen under three different addresses). Gating on a manufacturer ID would
        // break any non-Samsung key, which defeats the keyName preference.
        guard name.localizedCaseInsensitiveContains(Prefs.keyName) else { return }

        // ---- identity: the name, plus an address set learned from your device --
        let now = Date()
        matchSeen[id] = now
        matchSeen = matchSeen.filter { now.timeIntervalSince($0.value) < 60 }

        var known = Prefs.knownKeyAddresses
        let addr = id.uuidString
        if !known.isEmpty, !known.contains(addr) {
            // An unknown address carrying our key's name means one of two things:
            // our device rotated its address, or somebody nearby owns the same
            // model. Rotation is only credible when no *other* same-named device
            // is in range - an impostor always shows up alongside ours and would
            // otherwise keep this Mac unlocked forever.
            let rival = matchSeen.contains {
                $0.key != id && now.timeIntervalSince($0.value) < Self.rivalWindow
            }
            if rival {
                if now.timeIntervalSince(lastImpostorLog) > 60 {
                    lastImpostorLog = now
                    log("ignoring '\(name)' at \(addr.prefix(8)): another same-named device is in range")
                }
                return
            }
            known.append(addr)
            if known.count > Self.maxKnown { known.removeFirst(known.count - Self.maxKnown) }
            Prefs.knownKeyAddresses = known
            log("learned key address \(addr.prefix(8)) (\(known.count) known)")
        } else if known.isEmpty {
            Prefs.knownKeyAddresses = [addr]
            log("learned key address \(addr.prefix(8)) (first)")
        }

        recordGap(now)

        if var ch = channels[id] {
            ch.lastSeen = Date()
            ch.lastRSSI = rssi
            ch.packets += 1
            ch.name = name
            channels[id] = ch
        } else {
            channels[id] = Channel(name: name, lastSeen: Date(),
                                             lastRSSI: rssi, packets: 1)
            log("key channel: '\(name)' \(id.uuidString)")
        }
    }

    private func recordGap(_ now: Date) {
        defer { lastUnion = now }
        guard let last = lastUnion else { return }
        let g = now.timeIntervalSince(last)
        guard g > 0.05 else { return }
        gaps.append(g)
        if gaps.count > 1200 { gaps.removeFirst(gaps.count - 1200) }
    }

    func resetGaps() {
        gaps.removeAll()
        lastUnion = nil
    }

    func prune() {
        // Forget channels unseen for 10 minutes so the menu stays honest.
        let cutoff = Date().addingTimeInterval(-600)
        channels = channels.filter { $0.value.lastSeen > cutoff }
        named = named.filter { $0.value.lastSeen > Date().addingTimeInterval(-120) }
    }

    /// Switching key device invalidates every tracked channel, otherwise the old
    /// device keeps the app "present" and it never locks again.
    /// The test drives ingest() directly, so it must not open a radio.
    func beginScanningForTest() {}

    func resetChannels() {
        channels.removeAll()
        matchSeen.removeAll()
        resetGaps()
    }

    /// Seconds since the most recent packet from ANY tracked channel.
    /// nil means we have never seen the key at all.
    func allAbsentFor() -> Double? {
        guard let newest = channels.values.map({ $0.lastSeen }).max() else { return nil }
        return Date().timeIntervalSince(newest)
    }

    func state() -> Presence {
        guard let absent = allAbsentFor() else { return .noKey }
        return absent >= Prefs.awayWindow ? .away : .present
    }

    func bestChannel() -> Channel? {
        channels.values.max { $0.lastSeen < $1.lastSeen }
    }
}

// ───────────────────────────── app ─────────────────────────────

enum Phase {
    case noKey        // never saw the buds yet
    case armed        // buds present
    case away         // buds gone, waiting to confirm
    case lockedOut    // we locked; wait for the user to come back
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = PresenceMonitor()
    private var timer: Timer?
    private var phase: Phase = .noKey
    private var lastLockAt: Date?
    private let lockCooldown: TimeInterval = 20
    private var lastHoldLog = Date(timeIntervalSince1970: 0)
    private var keySelectedAt = Date()

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = symbol("lock.open")

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)

        rebuildMenu()
        let source: String = {
            if WindowPolicy.isManual { return "manual" }
            if let l = WindowPolicy.learned { return "learned \(Int(l))s" }
            return "learning, warm-up"
        }()
        log("Waylock started (window=\(Prefs.awayWindow)s \(source), key='\(Prefs.keyName)'"
            + (Prefs.isDryRun ? ", DRY RUN — will not lock" : "") + ")")
    }

    // MARK: core loop

    private var lastBeat = Date(timeIntervalSince1970: 0)

    private func phaseName() -> String {
        switch phase {
        case .noKey: return "noKey"
        case .armed: return "armed"
        case .away: return "away"
        case .lockedOut: return "lockedOut"
        }
    }

    /// Every 10 s, record the exact inputs the decision is made from. Without
    /// this a "nothing happened" log is indistinguishable from a dozen
    /// different causes, which is what made the first live failure opaque.
    private func heartbeat(_ absent: Double?, idle: Double?) {
        guard Date().timeIntervalSince(lastBeat) >= 10 else { return }
        lastBeat = Date()
        log("hb absent=\(absent.map { String(format: "%.1f", $0) } ?? "nil")s"
            + " phase=\(phaseName()) ch=\(monitor.channels.count)"
            + " idle=\(idle.map { String(format: "%.0f", $0) } ?? "nil")s"
            + " locked=\(Locker.screenIsLocked() ? 1 : 0)"
            + " enabled=\(Prefs.enabled ? 1 : 0)"
            + " window=\(Int(Prefs.awayWindow))"
            + " rssi=\(monitor.bestChannel()?.lastRSSI ?? 0)"
            + " gaps=\(monitor.gaps.count)"
            + " named=\(monitor.named.count)")
    }

    private func tick() {
        let idle = Locker.hidIdleSeconds()

        guard Prefs.enabled else {
            phase = .noKey
            statusItem.button?.image = symbol("lock.slash")
            heartbeat(monitor.allAbsentFor(), idle: idle)
            return
        }

        monitor.prune()
        settleWindowIfLearned()
        let absent = monitor.allAbsentFor()

        switch phase {
        case .lockedOut:
            // Re-arm only after real, sustained presence.
            if let a = absent, a < 3 {
                phase = .armed
                log("re-armed: key back")
            }
        default:
            if absent == nil {
                phase = .noKey
            } else if absent! >= Prefs.awayWindow {
                phase = .away
                attemptLock(absentFor: absent!)
            } else {
                phase = .armed
            }
        }

        heartbeat(absent, idle: idle)
        statusItem.button?.image = symbol(iconName())
        updateMenuDynamicBits()
    }

    /// Once a device has produced enough real gaps, derive its window and stop
    /// learning. The wait is deliberate: a window chosen from two minutes of
    /// data would be chosen from the quietest two minutes of the day.
    private func settleWindowIfLearned() {
        guard WindowPolicy.isLearning else { return }
        guard Date().timeIntervalSince(keySelectedAt) >= WindowPolicy.learnPeriod else { return }
        guard let r = WindowPolicy.recommend(from: monitor.gaps) else { return }
        WindowPolicy.useLearned(r.window)
        log(String(format: "window learned: %.1fs (worst kept gap %.1fs of %d samples) — warm-up was %.0fs",
                   r.window, r.worst, r.kept, WindowPolicy.warmup))
        rebuildMenu()
    }

    private func attemptLock(absentFor: Double) {
        if let last = lastLockAt, Date().timeIntervalSince(last) < lockCooldown {
            return
        }

        // Require the user to have been idle for the whole window, not just a
        // moment. This makes "you are actively using the Mac" a hard guarantee
        // against a false lock: while you type or move the mouse, we never lock.
        // When you genuinely walk away you stop touching the machine, so the
        // idle timer starts at the same moment the signal dies and adds no
        // extra latency.
        if Prefs.respectActivity, let idle = Locker.hidIdleSeconds(), idle < Prefs.awayWindow {
            if Date().timeIntervalSince(lastHoldLog) > 30 {
                lastHoldLog = Date()
                log("away \(Int(absentFor))s but user active (\(String(format: "%.0f", idle))s idle) — holding")
            }
            return
        }

        // Someone already locked it (lid, hot corner) — don't stack up.
        if Locker.screenIsLocked() {
            log("away \(Int(absentFor))s but screen already locked — nothing to do")
            lastLockAt = Date()
            phase = .lockedOut
            return
        }

        if Prefs.isDryRun {
            log("AWAY \(Int(absentFor))s -> WOULD LOCK (dry-run)")
            lastLockAt = Date()
            phase = .lockedOut
            return
        }

        log("AWAY \(Int(absentFor))s -> locking")
        if Locker.lock() {
            lastLockAt = Date()
            phase = .lockedOut
        }
    }

    private func iconName() -> String {
        switch phase {
        case .noKey:     return "lock.slash"
        case .armed:     return "lock.open"
        case .away:      return "lock.rotation"
        case .lockedOut: return "lock.fill"
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Waylock")
        img?.isTemplate = true
        return img ?? NSImage(systemSymbolName: "lock", accessibilityDescription: "Waylock")
    }

    // MARK: menu

    private var statusLine: NSMenuItem!
    private var deviceLine: NSMenuItem!

    private func rebuildMenu() {
        let menu = NSMenu()

        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        deviceLine = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        deviceLine.isEnabled = false
        menu.addItem(deviceLine)

        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = Prefs.enabled ? .on : .off
        enabled.tag = 100
        menu.addItem(enabled)

        let awayItem = NSMenuItem(title: "Away for", action: nil, keyEquivalent: "")
        let awayMenu = NSMenu()

        let autoTitle: String = {
            if WindowPolicy.isManual { return "Automatic · use measured" }
            if let l = WindowPolicy.learned { return "Automatic · learned \(Int(l)) s" }
            return "Automatic · learning (\(monitor.gaps.count) samples)"
        }()
        let autoItem = NSMenuItem(title: autoTitle,
                                  action: #selector(useAutomaticWindow(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = WindowPolicy.isManual ? .off : .on
        awayMenu.addItem(autoItem)
        awayMenu.addItem(.separator())

        for secs in [8.0, 10.0, 15.0, 20.0, 30.0] {
            // Measured at-desk worst case is 10.2 s, so anything below 15 s is
            // a known false-lock risk. Say so in the menu instead of hiding it.
            let risky = secs < 15 ? " · may false-lock" : ""
            let i = NSMenuItem(title: "\(Int(secs)) seconds\(risky)",
                               action: #selector(setWindow(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = secs
            i.state = (Prefs.manualWindows[Prefs.keyName.lowercased()] == secs) ? .on : .off
            awayMenu.addItem(i)
        }
        awayItem.submenu = awayMenu
        menu.addItem(awayItem)

        let keyItem = NSMenuItem(title: "Key Device", action: nil, keyEquivalent: "")
        let km = NSMenu()
        km.delegate = self
        keyItem.submenu = km
        keySubmenu = km
        menu.addItem(keyItem)

        let activity = NSMenuItem(title: "Don't lock while I'm typing", action: #selector(toggleActivity), keyEquivalent: "")
        activity.target = self
        activity.state = Prefs.respectActivity ? .on : .off
        activity.tag = 101
        menu.addItem(activity)

        menu.addItem(.separator())

        let lockNow = NSMenuItem(title: "Lock Now (test)", action: #selector(lockNow), keyEquivalent: "")
        lockNow.target = self
        menu.addItem(lockNow)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.tag = 102
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let rescan = NSMenuItem(title: "Restart Scanning", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Waylock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private var keySubmenu: NSMenu?

    // Built on demand so the list is always current — advertising sets come and
    // go, and a stale list would offer devices that are no longer there.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === keySubmenu else { return }
        menu.removeAllItems()

        let now = Date()
        let devs = monitor.named.values
            .filter { now.timeIntervalSince($0.lastSeen) < 60 }
            .sorted { $0.lastSeen > $1.lastSeen }

        if devs.isEmpty {
            let i = NSMenuItem(title: "No named devices visible", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        for d in devs.prefix(20) {
            let on = d.name.localizedCaseInsensitiveContains(Prefs.keyName)
            // Show the measured rate before the choice, not after it: a device
            // that advertises every 11 s cannot support a usable window, and
            // finding that out by walking away and back is a bad way to learn.
            var rate = "  measuring…"
            if let pm = d.perMinute() {
                rate = pm < 12
                    ? String(format: "  ⚠ %.0f/min — too rare", pm)
                    : String(format: "  %.0f/min", pm)
            }
            let i = NSMenuItem(title: (on ? "\u{2713} " : "   ") + "\(d.name)  \(d.rssi) dBm\(rate)",
                               action: #selector(pickKey(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.name
            menu.addItem(i)
        }

        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Type a name\u{2026}", action: #selector(typeKeyName), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
    }

    @objc private func pickKey(_ item: NSMenuItem) {
        guard let n = item.representedObject as? String else { return }
        setKey(n)
    }

    @objc private func typeKeyName() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Key device name"
        a.informativeText = "Any advertiser whose name contains this text (case-insensitive) counts as your key device."
        a.addButton(withTitle: "Use")
        a.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = Prefs.keyName
        a.accessoryView = tf
        if a.runModal() == .alertFirstButtonReturn {
            let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { setKey(v) }
        }
    }

    private func setKey(_ name: String) {
        Prefs.keyName = name
        Prefs.knownKeyAddresses = []
        monitor.resetChannels()
        monitor.restartScanning()
        phase = .noKey
        lastLockAt = nil
        log("key device -> '\(name)' (channels reset, re-arming)")
    }

    private var lastMenuUpdate = Date(timeIntervalSince1970: 0)

    private func updateMenuDynamicBits() {
        guard Date().timeIntervalSince(lastMenuUpdate) > 1 else { return }
        lastMenuUpdate = Date()

        if !Prefs.enabled {
            statusLine.title = "Disabled"
            deviceLine.title = "—"
            return
        }

        if monitor.bluetoothState != .poweredOn {
            // .unknown means CoreBluetooth never got a state back at all, which
            // in practice is a permission prompt waiting to be answered (a
            // rebuild re-signs the app, so the old grant stops matching).
            if monitor.bluetoothState == .unknown {
                statusLine.title = "Waiting for Bluetooth permission"
                deviceLine.title = "approve the prompt — a rebuild changes the signature"
            } else {
                statusLine.title = "Bluetooth unavailable"
                deviceLine.title = "enable it in System Settings > Privacy > Bluetooth"
            }
            return
        }

        let prefix = Prefs.isDryRun ? "DRY RUN · " : ""

        switch phase {
        case .noKey:
            statusLine.title = prefix + "Waiting for key device"
            deviceLine.title = "no '\(Prefs.keyName)' advertising yet"
        case .armed:
            statusLine.title = prefix + "Armed — key is present"
            deviceLine.title = describeChannels()
        case .away:
            statusLine.title = prefix + "Key is away…"
            deviceLine.title = describeChannels()
        case .lockedOut:
            statusLine.title = prefix + "Locked"
            deviceLine.title = "waiting for key to return"
        }
    }

    private func describeChannels() -> String {
        let sorted = monitor.channels.values.sorted { $0.lastSeen > $1.lastSeen }
        guard let best = sorted.first else { return "—" }
        let age = Int(Date().timeIntervalSince(best.lastSeen))
        let n = sorted.count
        return "\(best.name) · \(best.lastRSSI) dBm · \(age)s ago\(n > 1 ? " · +\(n - 1)" : "")"
    }

    // MARK: actions

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        Prefs.enabled.toggle()
        item.state = Prefs.enabled ? .on : .off
        if Prefs.enabled { monitor.restartScanning() }
        log("enabled = \(Prefs.enabled)")
    }

    @objc private func setWindow(_ item: NSMenuItem) {
        guard let v = item.representedObject as? Double else { return }
        Prefs.awayWindow = v          // records a manual choice for this device
        item.menu?.items.forEach { $0.state = ($0.representedObject as? Double == v) ? .on : .off }
        log("awayWindow = \(v) (manual for '\(Prefs.keyName)')"
            + (v < 15 ? "  (below the measured 10.2s worst case — expect false locks)" : ""))
    }

    @objc private func useAutomaticWindow(_ item: NSMenuItem) {
        WindowPolicy.forget()
        keySelectedAt = Date()
        monitor.resetGaps()
        log("awayWindow = automatic (re-learning from now, warm-up \(Int(WindowPolicy.warmup))s)")
        rebuildMenu()
    }

    @objc private func toggleActivity(_ item: NSMenuItem) {
        Prefs.respectActivity.toggle()
        item.state = Prefs.respectActivity ? .on : .off
    }

    @objc private func lockNow(_ item: NSMenuItem) {
        if Prefs.isDryRun {
            log("manual lock -> suppressed (DRY RUN)")
            return
        }
        log("manual lock")
        _ = Locker.lock()
    }

    @objc private func rescan(_ item: NSMenuItem) {
        monitor.restartScanning()
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
                item.state = .off
            } else {
                try svc.register()
                item.state = .on
            }
        } catch {
            log("login item error: \(error.localizedDescription)")
            let a = NSAlert()
            a.messageText = "Couldn't change login item"
            a.informativeText = "Move Waylock.app to /Applications and try again.\n\n\(error.localizedDescription)"
            a.runModal()
        }
    }
}

// ───────────────────────── headless self-test ─────────────────────────
//
// Waylock --selftest [seconds]
// Drives the real scan -> match -> all-absent path with no menu bar and no
// screen locking. This is the part that can false-positive, so it is the part
// worth testing.

func runSelfTest(seconds: Double = 40) {
    let monitor = PresenceMonitor()
    let t0 = Date()
    var firedAt: Double?

    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
        let t = Date().timeIntervalSince(t0)
        guard let absent = monitor.allAbsentFor() else {
            print(String(format: "%5.0fs  noKey     waiting for '%@'", t, Prefs.keyName))
            return
        }
        let away = absent >= Prefs.awayWindow
        let best = monitor.bestChannel()
        if away, firedAt == nil { firedAt = t }
        print(String(format: "%5.0fs  %-7@  allAbsent=%.1fs window=%.0fs  best=%@ %ddBm %@",
                     t,
                     (away ? "AWAY" : "present") as NSString,
                     absent, Prefs.awayWindow,
                     (best?.name ?? "-") as NSString,
                     best?.lastRSSI ?? 0,
                     (away ? "<-- WOULD LOCK" : "") as NSString))
        if t >= seconds {
            timer.invalidate()
            print("\nchannels tracked: \(monitor.channels.count)")
            for (id, c) in monitor.channels.sorted(by: { $0.value.packets > $1.value.packets }) {
                print("  '\(c.name)' \(id.uuidString.prefix(8)) packets=\(c.packets) last=\(c.lastRSSI)dBm")
            }
            print(firedAt.map { String(format: "TRIGGERED at t=%.0fs", $0) }
                  ?? "no trigger (stayed present)")
            exit(0)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    withExtendedLifetime(monitor) { RunLoop.main.run() }
}

// MARK: - calibration
//
// Waylock --calibrate [minutes] [--apply]
//
// Measures this device's union-gap distribution and says what window it can
// support. Sit at the desk with the device while it runs; walking away does not
// corrupt the result (absences are discarded as outliers) but clean data is
// better. --apply stores the result as the learned window for the device.

func runCalibration(minutes: Double, apply: Bool) {
    let monitor = PresenceMonitor()
    let t0 = Date()
    let total = max(30, minutes * 60)

    print("calibrating '\(Prefs.keyName)' for \(Int(total / 60)) min")
    print("stay at the desk with the device — this measures how long it is NORMALLY silent")
    if !WindowPolicy.isLearning {
        print("note: this device has a window already (\(Prefs.awayWindow)s); --apply will overwrite it")
    }

    let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
        let t = Date().timeIntervalSince(t0)
        let absent = monitor.allAbsentFor()
        print(String(format: "%5.0fs  ch=%d  gaps=%3d  absent=%@",
                     t, monitor.channels.count, monitor.gaps.count,
                     (absent.map { String(format: "%.1fs", $0) } ?? "never seen") as NSString))

        guard t >= total else { return }
        timer.invalidate()

        let gaps = monitor.gaps
        let sorted = gaps.sorted()
        func pct(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }

        print("\nsamples \(gaps.count) over \(Int(t))s")
        if !sorted.isEmpty {
            print(String(format: "median %.1fs   p90 %.1fs   p99 %.1fs   max %.1fs",
                         pct(0.5), pct(0.9), pct(0.99), sorted.last ?? 0))
        }
        for (id, c) in monitor.channels.sorted(by: { $0.value.packets > $1.value.packets }) {
            print("  '\(c.name)' \(id.uuidString.prefix(8)) packets=\(c.packets) rssi=\(c.lastRSSI)dBm")
        }

        guard let r = WindowPolicy.recommend(from: gaps) else {
            print("\nNOT ENOUGH DATA (need \(WindowPolicy.minSamples) gaps) — is the device advertising?")
            exit(2)
        }
        print(String(format: "\nrecommended window: %.1fs  (worst kept gap %.1fs x1.5, %d of %d samples)",
                     r.window, r.worst, r.kept, gaps.count))

        if apply {
            WindowPolicy.useLearned(r.window)
            print("applied: '\(Prefs.keyName)' now locks after \(Int(r.window))s")
        } else {
            print("not applied — rerun with --apply to save it")
        }
        exit(0)
    }
    RunLoop.main.add(timer, forMode: .common)
    withExtendedLifetime(monitor) { RunLoop.main.run() }
}

// MARK: - policy test
//
// Waylock --policy-test
//
// The window is now derived rather than chosen, so the derivation is tested
// against distributions that were actually measured on real devices. No radio.

func runPolicyTest() {
    var failures = 0
    func check(_ label: String, _ got: Double?, _ want: Double?) {
        let ok: Bool
        switch (got, want) {
        case (nil, nil): ok = true
        case let (g?, w?): ok = abs(g - w) < 0.05
        default: ok = false
        }
        let g = got.map { String(format: "%.1f", $0) } ?? "nil"
        let w = want.map { String(format: "%.1f", $0) } ?? "nil"
        print("  \(ok ? "PASS" : "FAIL")  \(label)  -> \(g) (want \(w))")
        if !ok { failures += 1 }
    }

    // Distribution shapes taken from the measured baselines in FINDINGS.md.
    func gaps(count: Int, median: Double, max maxv: Double) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in median * (0.4 + 0.6 * Double(i) / Double(count)) } + [maxv]
    }

    print("too few samples is not a recommendation")
    check("5 gaps", WindowPolicy.recommend(from: [1, 2, 3, 4, 5])?.window, nil)

    print("measured devices")
    check("strap-like (max 2.6s)", WindowPolicy.recommend(from: gaps(count: 60, median: 1.5, max: 2.6))?.window, 12.0)
    check("buds-like (max 10.2s)", WindowPolicy.recommend(from: gaps(count: 60, median: 1.5, max: 10.2))?.window, 15.3)
    check("slow device (max 11s)", WindowPolicy.recommend(from: gaps(count: 60, median: 5, max: 11))?.window, 16.5)

    print("a slow device still needs a bigger window than a chatty one")
    let chatty = WindowPolicy.recommend(from: gaps(count: 60, median: 1.0, max: 3.0))!.window
    let quiet  = WindowPolicy.recommend(from: gaps(count: 60, median: 9.0, max: 20.0))!.window
    print("  chatty \(chatty)s < quiet \(quiet)s")
    if !(chatty < quiet) { failures += 1; print("  FAIL  ordering") }

    print("a walk-away gap is an absence, not device behaviour")
    var withAway = gaps(count: 60, median: 1.5, max: 6.0)
    withAway.append(45.0)                        // brief trip to a meeting
    // The window would be 60s if the absence were learned; the point of the test
    // is that the worst *kept* gap stays at the real in-room maximum.
    let outlied = WindowPolicy.recommend(from: withAway)
    check("45s absence is NOT learned as a gap", outlied?.worst, 6.0)
    check("...so the window stays at the floor", outlied?.window, 12.0)

    print("a chatty device keeps its own 8s gap instead of calling it an absence")
    check("strap-like with a real 8.2s gap", WindowPolicy.recommend(from: gaps(count: 60, median: 0.5, max: 8.2))?.window, 12.3)

    print("clamps")
    check("absurd max clamps to 60s", WindowPolicy.recommend(from: gaps(count: 60, median: 30, max: 200))?.window, 60.0)
    check("very quiet device clamps to 60s", WindowPolicy.recommend(from: gaps(count: 60, median: 40, max: 120))?.window, 60.0)

    print("warm-up, learning and manual precedence")
    let suite = "io.github.hheydaroff.waylock.policytest"
    let sandbox = UserDefaults(suiteName: suite)!
    sandbox.removePersistentDomain(forName: suite)
    Prefs.defaults = sandbox
    Prefs.keyName = "Test Key"

    check("no entry -> warm-up", WindowPolicy.effective, WindowPolicy.warmup)
    if !WindowPolicy.isLearning { failures += 1; print("  FAIL  should be learning") }
    WindowPolicy.useLearned(16)
    check("learned applies", WindowPolicy.effective, 16.0)
    if WindowPolicy.isLearning { failures += 1; print("  FAIL  should not be learning") }
    WindowPolicy.useManual(25)
    check("manual beats learned", WindowPolicy.effective, 25.0)
    WindowPolicy.useLearned(14)
    check("'use measured' clears the override", WindowPolicy.effective, 14.0)
    if WindowPolicy.isManual { failures += 1; print("  FAIL  manual should be cleared") }
    Prefs.keyName = "Other Key"
    check("policy is per device", WindowPolicy.effective, WindowPolicy.warmup)

    Prefs.defaults = .standard
    sandbox.removePersistentDomain(forName: suite)
    print(failures == 0 ? "\nPOLICY OK" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - identity test

/// Feeds the real decision logic a scripted sequence of advertisers, then checks
/// what a colleague owning the same model of key device would do to it.
func runIdentityTest() {
    let suite = "io.github.hheydaroff.waylock.identitytest"
    let sandbox = UserDefaults(suiteName: suite)!
    sandbox.removePersistentDomain(forName: suite)
    Prefs.defaults = sandbox

    Prefs.keyName = "Helio"
    let mine = UUID(), impostor = UUID(), rotated = UUID()
    var failures = 0

    func check(_ label: String, _ ok: Bool) {
        print("  \(ok ? "PASS" : "FAIL")  \(label)")
        if !ok { failures += 1 }
    }

    func fresh(_ known: [String]) -> PresenceMonitor {
        Prefs.knownKeyAddresses = known
        let m = PresenceMonitor()
        m.beginScanningForTest()
        return m
    }

    print("first run, nothing learned yet")
    var m = fresh([])
    m.ingest(name: "Amazfit Helio Strap", id: mine, rssi: -60)
    check("adopts the first address it sees", Prefs.knownKeyAddresses == [mine.uuidString])
    check("tracks it as a channel", m.channels.count == 1)

    print("colleague's identical strap arrives")
    m.ingest(name: "Amazfit Helio Strap", id: impostor, rssi: -55)
    check("impostor is NOT tracked", m.channels[impostor] == nil)
    check("impostor is NOT learned", !Prefs.knownKeyAddresses.contains(impostor.uuidString))
    check("your device is still tracked", m.channels[mine] != nil)

    print("you walk away, colleague stays")
    for _ in 0..<3 {
        m.ingest(name: "Amazfit Helio Strap", id: impostor, rssi: -55)
        usleep(2_000_000)
    }
    let absentWithRival = m.allAbsentFor() ?? 0
    check("Mac still counts as away despite the impostor (\(String(format: "%.1f", absentWithRival))s)",
          absentWithRival >= 4)

    print("genuine rotation, nobody else around")
    m = fresh([mine.uuidString])
    m.ingest(name: "Amazfit Helio Strap", id: rotated, rssi: -60)
    check("rotated address is adopted", Prefs.knownKeyAddresses.contains(rotated.uuidString))
    check("rotated address is tracked", m.channels[rotated] != nil)

    print("a different device name never matches")
    m.ingest(name: "Govee_H6046_712B", id: UUID(), rssi: -40)
    check("unrelated device ignored", m.channels.count == 1)

    Prefs.defaults = .standard          // restore before leaving the sandbox
    sandbox.removePersistentDomain(forName: suite)
    print(failures == 0 ? "\nIDENTITY OK" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--identity-test") {
    runIdentityTest()
} else if CommandLine.arguments.contains("--policy-test") {
    runPolicyTest()
} else if let ci = CommandLine.arguments.firstIndex(of: "--calibrate") {
    let mins = (ci + 1 < CommandLine.arguments.count)
        ? (Double(CommandLine.arguments[ci + 1]) ?? 10) : 10
    runCalibration(minutes: mins, apply: CommandLine.arguments.contains("--apply"))
} else if CommandLine.arguments.contains("--selftest") {
    let idx = CommandLine.arguments.firstIndex(of: "--selftest")!
    let secs = (idx + 1 < CommandLine.arguments.count)
        ? (Double(CommandLine.arguments[idx + 1]) ?? 40) : 40
    runSelfTest(seconds: secs)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}