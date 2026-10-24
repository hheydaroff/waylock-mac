import AppKit
import Foundation
import ServiceManagement

/// The menu bar app: the only place that talks to AppKit, and it decides nothing.
///
/// Every decision lives in `Session` (when to lock, what to log) and the modules
/// under it. This type feeds the session the time and the machine's readings,
/// then performs the effects it returns: call the locker, write the log, save the
/// settings. What is left is the timer, the icon and the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: SettingsStore
    private var session: Session
    private let radio = Radio()

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var deviceLine: NSMenuItem!
    private var keySubmenu: NSMenu?

    private var lastModel: [MenuItem] = []
    private var lastMenuUpdate = Date.distantPast

    init(settings: Settings, store: SettingsStore) {
        self.store = store
        self.session = Session(settings: settings, now: Date())
        super.init()
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = symbol(session.phase.symbol)

        radio.log = { log($0) }
        radio.shouldRecover = { [weak self] in self?.session.settings.enabled ?? true }
        radio.onSighting = { [weak self] in self?.receive($0) }
        radio.start()

        refreshMenu(now: Date(), force: true)

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            // Sound: the timer is added to RunLoop.main below, so this block only
            // ever fires on the main thread. Timer's block is merely not annotated.
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)

        let settings = session.settings
        let window = settings.awayWindow
        log("Waylock started (window=\(Int(window.seconds))s \(window.label), key='\(settings.keyName)'"
            + (settings.dryRun ? ", DRY RUN — will not lock" : "") + ")")
    }

    // MARK: session

    private func receive(_ sighting: Sighting) {
        perform(session.sight(sighting, now: Date()), at: Date())
    }

    private func tick() {
        let now = Date()
        perform(session.tick(now: now, readings: readings()), at: now)
        statusItem.button?.image = symbol(session.phase.symbol)
        refreshMenu(now: now)
    }

    private func readings() -> Readings {
        Readings(idleFor: Locker.hidIdleSeconds(), screenLocked: Locker.screenIsLocked())
    }

    /// Carry out what the session decided, in order. This is the only place the
    /// locker is called, and it is reached only through a `.lock` effect, which
    /// the session emits only after `LockDecision` said so.
    private func perform(_ effects: [Effect], at now: Date) {
        for effect in effects {
            switch effect {
            case let .log(message):
                log(message)
            case .rearm:
                log("re-armed: key back")
            case let .reportKey(event):
                log(describe(event, known: session.tracker.knownAddresses.count))
            case .saveSettings:
                store.save(session.settings)
            case let .lock(trigger):
                log("\(trigger) -> locking")
                session.lockFinished(verified: Locker.lock(), at: now)
            }
        }
    }

    // MARK: menu

    private func snapshot(now: Date) -> MenuSnapshot {
        MenuSnapshot(phase: session.phase,
                     enabled: session.settings.enabled,
                     dryRun: session.settings.dryRun,
                     bluetooth: radio.state,
                     keyName: session.settings.keyName,
                     device: session.settings.device,
                     window: session.settings.awayWindow,
                     windows: session.settings.windows,
                     bestChannel: session.tracker.bestChannel(),
                     channelCount: session.tracker.channels.count,
                     respectActivity: session.settings.respectActivity,
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
        let devices = session.tracker.named.values
            .filter { now.timeIntervalSince($0.lastSeen) < 60 }
            .sorted { $0.lastSeen > $1.lastSeen }
        for item in MenuModel.keyDevices(devices, keyName: session.settings.keyName) {
            menu.addItem(makeItem(item))
        }
    }

    // MARK: actions

    @objc private func toggleEnabled() {
        let now = Date()
        perform(session.toggleEnabled(), at: now)
        if session.settings.enabled { radio.restartScanning() }
        refreshMenu(now: now, force: true)
    }

    @objc private func setWindow(_ item: NSMenuItem) {
        guard let action = item.representedObject as? MenuAction,
              case let .setWindow(seconds) = action else { return }
        let now = Date()
        perform(session.useManualWindow(seconds), at: now)
        refreshMenu(now: now, force: true)
    }

    @objc private func useAutomaticWindow() {
        let now = Date()
        perform(session.useAutomaticWindow(now: now), at: now)
        refreshMenu(now: now, force: true)
    }

    @objc private func toggleActivity() {
        let now = Date()
        perform(session.toggleActivity(), at: now)
        refreshMenu(now: now, force: true)
    }

    /// The user asked for a lock. The session routes it through
    /// `LockDecision.judgeManual`, so it meets the same safety gates as the tick.
    @objc private func lockNow() {
        let now = Date()
        perform(session.lockNow(now: now, readings: readings()), at: now)
        statusItem.button?.image = symbol(session.phase.symbol)
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
        field.stringValue = session.settings.keyName
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { setKey(name) }
        }
    }

    private func setKey(_ name: String) {
        let now = Date()
        perform(session.setKey(name, now: now), at: now)
        radio.restartScanning()
        refreshMenu(now: now, force: true)
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
