import Foundation
import Testing
@testable import WaylockCore

// Scenarios in virtual time. The decision tests in CoreTests.swift check one
// verdict at a time; the bugs this app shipped lived in the loop that calls them,
// so these walk the whole Session forward the way the 0.5 s timer does, with a
// clock the test owns and a locker that is only a recorded effect.

/// A Session, a clock and a key device, advanced the way the App advances them.
private struct Desk {
    var session: Session
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    /// How long the user has been idle at the keyboard, held fixed: 600 s is away
    /// from the desk, 1 s is typing. `nil` is unreadable.
    var idle: Double? = 600
    var screenLocked = false
    /// Whether the key device is advertising. Sightings arrive every 2 s.
    var keyPresent = true
    /// What the next `.lock` effect reports back, standing in for `Locker.lock()`.
    var lockSucceeds = true

    /// Every effect since the desk was built, in order.
    private(set) var effects: [Effect] = []
    private let key = UUID()
    private var lastSighting = Date.distantPast

    init(configure: (inout Settings) -> Void = { _ in }) {
        var settings = Settings()
        settings.windows.useManual(12, for: settings.device)   // 12 s, the lowest learned window
        configure(&settings)
        session = Session(settings: settings, now: now)
        // The key is heard once so the session has something to lose.
        _ = session.sight(Sighting(name: settings.keyName, address: key, rssi: -60), now: now)
        lastSighting = now
    }

    var locks: [Effect] { effects.filter { if case .lock = $0 { return true } else { return false } } }
    var logs: [String] { effects.compactMap { if case let .log(text) = $0 { return text } else { return nil } } }
    var rearms: Int { effects.filter { $0 == .rearm }.count }

    /// Advance by `seconds` in 0.5 s ticks, as the timer would.
    mutating func advance(_ seconds: Double) {
        let end = now.addingTimeInterval(seconds)
        while now < end {
            now = now.addingTimeInterval(0.5)
            if keyPresent, now.timeIntervalSince(lastSighting) >= 2 {
                _ = session.sight(Sighting(name: session.settings.keyName, address: key, rssi: -60), now: now)
                lastSighting = now
            }
            let produced = session.tick(now: now, readings: Readings(idleFor: idle, screenLocked: screenLocked))
            effects += produced
            for case .lock in produced {
                session.lockFinished(verified: lockSucceeds, at: now)
                if lockSucceeds { screenLocked = true }
            }
        }
    }
}

@Suite("Session: the app's behaviour over time")
struct SessionTests {
    @Test("a key that stays in range never causes a lock")
    func keyPresentForAMinute() {
        var desk = Desk()
        desk.advance(60)
        #expect(desk.locks.isEmpty, "locks: \(desk.locks)")
        #expect(desk.session.phase == .armed, "phase: \(desk.session.phase)")
    }

    @Test("a key that goes quiet while the user is idle locks exactly once")
    func keyLeavesUserIdle() {
        var desk = Desk()
        desk.advance(10)
        desk.keyPresent = false
        desk.advance(60)
        #expect(desk.locks == [.lock(trigger: "AWAY 12s")], "locks: \(desk.locks)")
        #expect(desk.session.phase == .lockedOut, "phase: \(desk.session.phase)")
    }

    @Test("no lock happens before the away window has passed")
    func nothingBeforeTheWindow() {
        var desk = Desk()
        desk.keyPresent = false
        desk.advance(10)                       // window is 12 s and the last sighting was at t=0
        #expect(desk.locks.isEmpty, "locks: \(desk.locks)")
    }

    @Test("the key coming back after a lock re-arms the session")
    func keyReturnsAfterLock() {
        var desk = Desk()
        desk.keyPresent = false
        desk.advance(30)
        #expect(desk.session.phase == .lockedOut, "phase: \(desk.session.phase)")

        desk.keyPresent = true
        desk.screenLocked = false
        desk.advance(5)
        #expect(desk.rearms == 1, "rearms: \(desk.rearms)")
        #expect(desk.session.phase == .armed, "phase: \(desk.session.phase)")
        #expect(desk.locks.count == 1, "locks: \(desk.locks)")
    }

    @Test("a long silence while locked out does not drop back to no key")
    func lockedOutSurvivesSilence() {
        var desk = Desk()
        desk.keyPresent = false
        desk.advance(30)
        desk.advance(600)
        #expect(desk.session.phase == .lockedOut, "phase: \(desk.session.phase)")
        #expect(desk.locks.count == 1, "locks: \(desk.locks)")
    }

    @Test("a user who keeps typing is never locked out, and the hold is logged once per 30 s")
    func userKeepsTyping() {
        var desk = Desk()
        desk.keyPresent = false
        desk.idle = 1                          // typing: pinned below the window
        desk.advance(60)
        #expect(desk.locks.isEmpty, "locks: \(desk.locks)")
        let holds = desk.logs.filter { $0.contains("user active") }
        #expect(holds.count == 2, "hold lines: \(holds)")
    }

    @Test("ignoring activity is a choice the user can make, and then the idle gate is open")
    func activityIgnored() {
        var desk = Desk { $0.respectActivity = false }
        desk.keyPresent = false
        desk.idle = 1
        desk.advance(30)
        #expect(desk.locks.count == 1, "locks: \(desk.locks)")
    }

    @Test("a disabled session produces no lock, no re-arm and no hold, however long it runs")
    func disabledDoesNothing() {
        var desk = Desk { $0.enabled = false }
        desk.advance(10)
        desk.keyPresent = false
        desk.advance(120)
        desk.keyPresent = true
        desk.advance(30)
        let acted = desk.effects.filter {
            switch $0 {
            case .lock, .rearm, .saveSettings, .reportKey: return true
            case let .log(text): return !text.hasPrefix("hb ")   // the heartbeat is how a disabled app shows it is alive
            }
        }
        #expect(acted.isEmpty, "effects: \(acted)")
        #expect(desk.session.phase == .noKey, "phase: \(desk.session.phase)")
    }

    @Test("a dry run never asks to lock, and says it would have")
    func dryRun() {
        var desk = Desk { $0.dryRun = true }
        desk.keyPresent = false
        desk.advance(60)
        #expect(desk.locks.isEmpty, "locks: \(desk.locks)")
        let wouldLock = desk.logs.filter { $0.contains("WOULD LOCK (dry-run)") }
        #expect(wouldLock.count == 1, "log: \(desk.logs)")
    }

    @Test("a manual lock in a dry run is also only logged")
    func manualDryRun() {
        var desk = Desk { $0.dryRun = true }
        desk.advance(4)
        let effects = desk.session.lockNow(now: desk.now, readings: Readings(idleFor: 1, screenLocked: false))
        #expect(!effects.contains(.lock(trigger: "manual lock")), "effects: \(effects)")
        #expect(effects.contains(.log("manual lock -> WOULD LOCK (dry-run)")), "effects: \(effects)")
    }

    @Test("a manual lock goes through while the key is present and the user is active")
    func manualLock() {
        var desk = Desk()
        desk.advance(4)
        let effects = desk.session.lockNow(now: desk.now, readings: Readings(idleFor: 1, screenLocked: false))
        #expect(effects == [.lock(trigger: "manual lock")], "effects: \(effects)")
    }

    @Test("a manual lock does nothing when the app is disabled")
    func manualWhileDisabled() {
        var desk = Desk { $0.enabled = false }
        let effects = desk.session.lockNow(now: desk.now, readings: Readings(idleFor: 1, screenLocked: false))
        #expect(effects.isEmpty, "effects: \(effects)")
    }

    @Test("a lock that was not verified leaves the session able to retry on the next tick")
    func failedLockRetries() {
        var desk = Desk()
        desk.lockSucceeds = false
        desk.keyPresent = false
        desk.advance(14)
        let attempts = desk.locks.count
        #expect(attempts >= 1, "locks: \(desk.locks)")
        #expect(desk.session.phase == .away, "phase after a failed lock: \(desk.session.phase)")

        desk.advance(0.5)
        #expect(desk.locks.count == attempts + 1, "locks: \(desk.locks)")

        desk.lockSucceeds = true
        desk.advance(1)
        #expect(desk.session.phase == .lockedOut, "phase: \(desk.session.phase)")
    }

    @Test("a second lock within 20 s of the first is held back, and allowed after")
    func cooldown() {
        // An 8 s window is the shortest a user can pick, so the key can return and
        // vanish again well inside the cooldown.
        var desk = Desk { $0.windows.useManual(8, for: $0.device) }
        desk.keyPresent = false
        desk.advance(10)
        #expect(desk.locks.count == 1, "locks: \(desk.locks)")
        let lockedAt = desk.now

        desk.keyPresent = true
        desk.screenLocked = false
        desk.advance(3)                        // sighted long enough to re-arm
        #expect(desk.session.phase == .armed, "phase: \(desk.session.phase)")

        desk.keyPresent = false
        desk.advance(10)                       // away again, still inside 20 s of the lock
        #expect(desk.now.timeIntervalSince(lockedAt) < 20, "scenario drifted past the cooldown")
        #expect(desk.locks.count == 1, "second lock inside the cooldown: \(desk.locks)")
        #expect(desk.session.phase == .away, "phase: \(desk.session.phase)")

        desk.advance(10)                       // now past 20 s since the first lock
        #expect(desk.locks.count == 2, "locks: \(desk.locks)")
    }

    @Test("a screen that is already locked is recorded and not locked again")
    func alreadyLocked() {
        var desk = Desk()
        desk.screenLocked = true
        desk.keyPresent = false
        desk.advance(30)
        #expect(desk.locks.isEmpty, "locks: \(desk.locks)")
        #expect(desk.logs.contains { $0.contains("screen already locked") }, "log: \(desk.logs)")
    }

    @Test("the heartbeat repeats every 10 s and names the inputs of the decision")
    func heartbeat() {
        var desk = Desk()
        desk.advance(35)
        let beats = desk.logs.filter { $0.hasPrefix("hb ") }
        #expect(beats.count == 4, "beats: \(beats)")           // t = 0.5, 10.5, 20.5, 30.5
        #expect(beats.first?.contains("enabled=1") == true, "beat: \(beats.first ?? "none")")
        #expect(beats.first?.contains("phase=armed") == true, "beat: \(beats.first ?? "none")")
    }

    @Test("choosing a new key device forgets the old one, including the cooldown")
    func newKeyResets() {
        var desk = Desk()
        desk.keyPresent = false
        desk.advance(30)
        #expect(desk.session.phase == .lockedOut)

        let effects = desk.session.setKey("watch", now: desk.now)
        #expect(effects.contains(.saveSettings), "effects: \(effects)")
        #expect(desk.session.phase == .noKey, "phase: \(desk.session.phase)")
        #expect(desk.session.tracker.channels.isEmpty)
        #expect(desk.session.settings.knownKeyAddresses.isEmpty)
    }

    @Test("an adopted key address is copied into the settings and a save is requested")
    func adoptedAddressIsPersisted() {
        var session = Session(settings: Settings(), now: Date(timeIntervalSinceReferenceDate: 0))
        let effects = session.sight(Sighting(name: "buds3", address: UUID(), rssi: -60),
                                    now: Date(timeIntervalSinceReferenceDate: 1))
        #expect(effects.contains(.saveSettings), "effects: \(effects)")
        #expect(session.settings.knownKeyAddresses.count == 1)
    }
}
