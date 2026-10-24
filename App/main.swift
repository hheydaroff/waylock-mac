import AppKit
import Foundation
import ServiceManagement

/// The menu bar app: it wires the modules together and is the only place that
/// decides nothing.
///
/// Every decision lives in `Core` (what to scan for, how long silence counts,
/// whether to lock) or in the adapters (`Radio`, `Locker`, `SettingsStore`). What
/// is left here is the timer, the icon and the menu.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: SettingsStore
    private var settings: Settings
    private var tracker: Tracker
    private var learning: Learning
    private let radio = Radio()

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var deviceLine: NSMenuItem!
    private var keySubmenu: NSMenu?

    private var phase: Phase = .noKey
    private var lastLockAt: Date?
    private var lastModel: [MenuItem] = []
    private var lastBeat = Date(timeIntervalSince1970: 0)
    private var lastHoldLog = Date(timeIntervalSince1970: 0)
    private var lastMenuUpdate = Date(timeIntervalSince1970: 0)

    init(settings: Settings, store: SettingsStore) {
        self.store = store
        self.settings = settings
        self.tracker = Tracker(keyName: settings.keyName, known: settings.knownKeyAddresses)
        self.learning = Learning(beganAt: Date())
        super.init()
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = symbol(phase.symbol)

        radio.log = { log($0) }
        radio.shouldRecover = { [weak self] in self?.settings.enabled ?? true }
        radio.onSighting = { [weak self] in self?.receive($0) }
        radio.start()

        refreshMenu(now: Date(), force: true)

        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)

        let window = settings.awayWindow
        log("Waylock started (window=\(Int(window.seconds))s \(window.label), key='\(settings.keyName)'"
            + (settings.dryRun ? ", DRY RUN — will not lock" : "") + ")")
    }

    // MARK: sightings

    private func receive(_ sighting: Sighting) {
        let events = tracker.sight(sighting, now: Date())
        guard !events.isEmpty else { return }
        for event in events { log(describe(event, known: tracker.knownAddresses.count)) }

        // The core reports that an address was adopted; persisting it is this
        // layer's job, which keeps the identity rule free of I/O.
        if tracker.knownAddresses != settings.knownKeyAddresses {
            settings.knownKeyAddresses = tracker.knownAddresses
            store.save(settings)
        }
    }

    // MARK: core loop

    private func tick() {
        let now = Date()
        let idle = Locker.hidIdleSeconds()
        tracker.prune(now: now)
        settleWindow(now: now)

        let absent = tracker.absent(now: now)
        let locked = Locker.screenIsLocked()
        let previous = phase

        let judgment = LockDecision.judge(LockInput(
            phase: phase,
            enabled: settings.enabled,
            absentFor: absent,
            window: settings.awayWindow.seconds,
            idleFor: idle,
            respectActivity: settings.respectActivity,
            dryRun: settings.dryRun,
            screenLocked: locked,
            lastLockAt: lastLockAt,
            now: now))

        phase = judgment.phase
        if previous == .lockedOut, phase == .armed { log("re-armed: key back") }
        apply(judgment.action, trigger: "AWAY \(Int(absent ?? 0))s",
              absent: absent, idle: idle, now: now)

        statusItem.button?.image = symbol(phase.symbol)
        heartbeat(absent: absent, idle: idle, locked: locked)
        refreshMenu(now: now)
    }

    /// Once a device has produced enough real gaps, derive its window and stop
    /// learning. A window chosen from two minutes of data would be chosen from the
    /// quietest two minutes of the day, so this waits.
    private func settleWindow(now: Date) {
        guard let learned = learning.settle(now: now, arrivals: tracker.arrivals,
                                            windows: settings.windows,
                                            device: settings.device) else { return }
        settings.windows.useLearned(learned.window, for: settings.device)
        store.save(settings)
        log(String(format: "window learned: %.1fs (worst kept gap %.1fs of %d samples) — warm-up was %.0fs",
                   learned.window, learned.worst, learned.kept, Windows.warmup))
    }

    /// Both lock entry points come through here, so the gates cannot drift apart.
    private func apply(_ action: LockAction, trigger: String,
                       absent: Double?, idle: Double?, now: Date) {
        switch action {
        case .none, .holdCooldown:
            break
        case .holdActive:
            // Throttled: this repeats every tick while the signal is gone and you
            // are still working.
            guard now.timeIntervalSince(lastHoldLog) > 30 else { return }
            lastHoldLog = now
            log("away \(Int(absent ?? 0))s but user active"
                + " (\(String(format: "%.0f", idle ?? 0))s idle) — holding")
        case .alreadyLocked:
            log("\(trigger) but screen already locked — nothing to do")
            lastLockAt = now
        case .dryRun:
            log("\(trigger) -> WOULD LOCK (dry-run)")
            lastLockAt = now
        case .lock:
            log("\(trigger) -> locking")
            // lockedOut only on a verified lock, so a failed attempt retries on the
            // next tick instead of waiting out the cooldown.
            if Locker.lock() {
                lastLockAt = now
                phase = .lockedOut
            }
        }
    }

    /// Every 10 s, record the exact inputs the decision was made from. Without this
    /// a "nothing happened" log is indistinguishable from a dozen different causes,
    /// which is what made the first live failure opaque.
    private func heartbeat(absent: Double?, idle: Double?, locked: Bool) {
        guard Date().timeIntervalSince(lastBeat) >= 10 else { return }
        lastBeat = Date()
        log("hb absent=\(absent.map { String(format: "%.1fs", $0) } ?? "never")"
            + " phase=\(phase.label) ch=\(tracker.channels.count)"
            + " idle=\(idle.map { String(format: "%.0fs", $0) } ?? "unreadable")"
            + " locked=\(locked ? 1 : 0)"
            + " enabled=\(settings.enabled ? 1 : 0)"
            + " window=\(Int(settings.awayWindow.seconds))"
            + " rssi=\(tracker.bestChannel()?.lastRSSI ?? 0)"
            + " gaps=\(tracker.arrivals.count)"
            + " named=\(tracker.named.count)")
    }

    // MARK: menu

    private func snapshot(now: Date) -> MenuSnapshot {
        MenuSnapshot(phase: phase,
                     enabled: settings.enabled,
                     dryRun: settings.dryRun,
                     bluetooth: radio.state,
                     keyName: settings.keyName,
                     device: settings.device,
                     window: settings.awayWindow,
                     windows: settings.windows,
                     bestChannel: tracker.bestChannel(),
                     channelCount: tracker.channels.count,
                     respectActivity: settings.respectActivity,
                     loginEnabled: SMAppService.mainApp.status == .enabled,
                     now: now)
    }

    private func refreshMenu(now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastMenuUpdate) > 1 else { return }
        lastMenuUpdate = now
        let snapshot = self.snapshot(now: now)
        let items = MenuModel.items(snapshot)

        // Rebuild only when the menu's structure or wording actually changed: the
        // two live lines are patched in place, and rebuilding an open menu would
        // interrupt the user.
        if force || items != lastModel {
            rebuildMenu(snapshot)
            return
        }
        let status = MenuModel.status(snapshot)
        statusLine.title = status.title
        deviceLine.title = status.detail
    }

    private func rebuildMenu(_ snapshot: MenuSnapshot) {
        let status = MenuModel.status(snapshot)
        lastModel = MenuModel.items(snapshot)
        keySubmenu = nil

        let menu = NSMenu()
        statusLine = informational(status.title)
        deviceLine = informational(status.detail)
        menu.addItem(statusLine)
        menu.addItem(deviceLine)
        menu.addItem(.separator())
        for item in lastModel { menu.addItem(makeItem(item)) }
        statusItem.menu = menu
    }

    private func informational(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeItem(_ item: MenuItem) -> NSMenuItem {
        switch item.content {
        case .separator:
            return .separator()

        case .info:
            return informational(item.title)

        case let .children(children):
            let row = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for child in children { submenu.addItem(makeItem(child)) }
            row.submenu = submenu
            return row

        case .liveChildren:
            // Rebuilt on open, because advertising sets come and go and a stale
            // list would offer devices that are no longer there.
            let row = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.delegate = self
            keySubmenu = submenu
            row.submenu = submenu
            return row

        case let .action(action):
            let row = NSMenuItem(title: item.title,
                                 action: selector(for: action),
                                 keyEquivalent: action == .quit ? "q" : "")
            row.target = action == .quit ? NSApp : self
            row.representedObject = action
            row.state = item.checked ? .on : .off
            return row
        }
    }

    private func selector(for action: MenuAction) -> Selector {
        switch action {
        case .toggleEnabled: return #selector(toggleEnabled)
        case .automaticWindow: return #selector(useAutomaticWindow)
        case .setWindow: return #selector(setWindow(_:))
        case .toggleActivity: return #selector(toggleActivity)
        case .lockNow: return #selector(lockNow)
        case .toggleLogin: return #selector(toggleLogin)
        case .rescan: return #selector(rescan)
        case .quit: return #selector(NSApplication.terminate(_:))
        case .pickKey: return #selector(pickKey(_:))
        case .typeKeyName: return #selector(typeKeyName)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === keySubmenu else { return }
        menu.removeAllItems()
        let now = Date()
        let devices = tracker.named.values
            .filter { now.timeIntervalSince($0.lastSeen) < 60 }
            .sorted { $0.lastSeen > $1.lastSeen }
        for item in MenuModel.keyDevices(devices, keyName: settings.keyName) {
            menu.addItem(makeItem(item))
        }
    }

    // MARK: actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        store.save(settings)
        if settings.enabled { radio.restartScanning() }
        log("enabled = \(settings.enabled)")
        refreshMenu(now: Date(), force: true)
    }

    @objc private func setWindow(_ item: NSMenuItem) {
        guard let action = item.representedObject as? MenuAction,
              case let .setWindow(seconds) = action else { return }
        settings.windows.useManual(seconds, for: settings.device)
        store.save(settings)
        log("awayWindow = \(Int(seconds)) (manual for '\(settings.keyName)')"
            + (seconds < 15 ? "  (below the measured 10.2s worst case — expect false locks)" : ""))
        refreshMenu(now: Date(), force: true)
    }

    @objc private func useAutomaticWindow() {
        settings.windows.forget(settings.device)
        store.save(settings)
        learning = Learning(beganAt: Date())
        tracker.restartLearning()
        log("awayWindow = automatic (re-learning from now, warm-up \(Int(Windows.warmup))s)")
        refreshMenu(now: Date(), force: true)
    }

    @objc private func toggleActivity() {
        settings.respectActivity.toggle()
        store.save(settings)
        refreshMenu(now: Date(), force: true)
    }

    /// The user asked for a lock. The away gate does not apply; every safety gate
    /// still does — a manual path that skipped dry-run once locked the screen
    /// during a test.
    @objc private func lockNow() {
        let now = Date()
        let absent = tracker.absent(now: now)
        let judgment = LockDecision.judgeManual(LockInput(
            phase: phase,
            enabled: settings.enabled,
            absentFor: absent,
            window: settings.awayWindow.seconds,
            idleFor: Locker.hidIdleSeconds(),
            respectActivity: settings.respectActivity,
            dryRun: settings.dryRun,
            screenLocked: Locker.screenIsLocked(),
            lastLockAt: lastLockAt,
            now: now))
        phase = judgment.phase
        apply(judgment.action, trigger: "manual lock", absent: absent, idle: nil, now: now)
        statusItem.button?.image = symbol(phase.symbol)
        refreshMenu(now: now, force: true)
    }

    @objc private func rescan() {
        radio.restartScanning()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log("login item error: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = "Move Waylock.app to /Applications and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
        refreshMenu(now: Date(), force: true)
    }

    @objc private func pickKey(_ item: NSMenuItem) {
        guard let action = item.representedObject as? MenuAction,
              case let .pickKey(name) = action else { return }
        setKey(name)
    }

    @objc private func typeKeyName() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Key device name"
        alert.informativeText = "Any advertiser whose name contains this text (case-insensitive) counts as your key device."
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = settings.keyName
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { setKey(name) }
        }
    }

    private func setKey(_ name: String) {
        settings.keyName = name
        settings.knownKeyAddresses = []
        tracker.setKey(name)
        store.save(settings)
        learning = Learning(beganAt: Date())
        radio.restartScanning()
        phase = .noKey
        lastLockAt = nil
        log("key device -> '\(name)' (channels reset, re-arming)")
        refreshMenu(now: Date(), force: true)
    }

    // MARK: icon

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Waylock")
        image?.isTemplate = true
        return image ?? NSImage(systemSymbolName: "lock", accessibilityDescription: "Waylock")
    }
}

// MARK: entry point

let application = NSApplication.shared
let delegate = AppDelegate(settings: SettingsStore().load(), store: SettingsStore())
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()