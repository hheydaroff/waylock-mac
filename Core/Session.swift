import Foundation

/// What only the machine can tell us right now. Read by the App each tick and
/// handed in, so the session never reaches for IOKit or the login session itself.
struct Readings: Equatable {
    /// Seconds since the last keyboard or mouse event; `nil` if unreadable.
    var idleFor: Double?
    var screenLocked: Bool
}

/// Something the session decided and only the App can do.
///
/// The session never performs I/O. It returns these, in order, and the App carries
/// them out. That keeps every decision — including "do not lock, and say why" —
/// visible to a test as plain data.
enum Effect: Equatable {
    /// Call the locker, then report the outcome with `Session.lockFinished`. The
    /// trigger is what the log should say caused it.
    case lock(trigger: String)
    /// The key came back after a lock and the session is armed again.
    case rearm
    case log(String)
    /// `Session.settings` changed and should be persisted.
    case saveSettings
    /// The tracker noticed something about the key device worth logging.
    case reportKey(Tracker.Event)
}

/// Everything that decides, advanced by a clock the caller owns.
///
/// This used to live in the app delegate, where the 0.5 s tick, the phase and the
/// call into the locker could only be exercised on a real Mac. Every bug this app
/// shipped — the dry-run bypass, the disabled app that never locked, the false
/// lock at the desk — was in that glue and not in a pure function, so the glue is
/// now a value that a test can walk through virtual time.
///
/// Time is a parameter, as in `Tracker` and `LockDecision`: nothing here calls
/// `Date()`. Both lock entry points (`tick` and `lockNow`) route through
/// `LockDecision`; nothing in this file decides to lock on its own.
struct Session {
    private(set) var settings: Settings
    private(set) var tracker: Tracker
    /// Where the app is in its conversation with the user. Only this type changes
    /// it, so the icon the App draws can never disagree with the gates.
    private(set) var phase: Phase = .noKey

    private var learning: Learning
    private var lastLockAt: Date?
    private var lastHoldLog = Date.distantPast
    private var lastBeat = Date.distantPast

    /// How often to say what the decision was made from.
    static let heartbeatEvery: TimeInterval = 10
    /// How often to repeat "the key is gone but you are still working".
    static let holdLogEvery: TimeInterval = 30

    init(settings: Settings, now: Date) {
        self.settings = settings
        self.tracker = Tracker(keyName: settings.keyName, known: settings.knownKeyAddresses)
        self.learning = Learning(beganAt: now)
    }

    // MARK: the clock

    /// One 0.5 s step: age out stale channels, settle the window if it has been
    /// observed long enough, judge, and report.
    mutating func tick(now: Date, readings: Readings) -> [Effect] {
        var effects: [Effect] = []
        tracker.prune(now: now)
        effects += settleWindow(now: now)

        let absent = tracker.absent(now: now)
        let previous = phase
        let judgment = LockDecision.judge(input(absent: absent, readings: readings, now: now))

        phase = judgment.phase
        if previous == .lockedOut, phase == .armed { effects.append(.rearm) }
        effects += act(on: judgment.action, trigger: "AWAY \(Int(absent ?? 0))s",
                       absent: absent, idle: readings.idleFor, now: now)
        effects += heartbeat(absent: absent, readings: readings, now: now)
        return effects
    }

    /// The App performed a `.lock` effect. `now` is the time of the tick that asked.
    ///
    /// The phase becomes `lockedOut` only here, and only when the lock was
    /// verified, so a failed attempt retries on the next tick instead of waiting
    /// out the cooldown. If the App forgot to call this, the symptom is a lock
    /// attempt on every tick, which is loud rather than quiet.
    mutating func lockFinished(verified: Bool, at now: Date) {
        guard verified else { return }
        lastLockAt = now
        phase = .lockedOut
    }

    /// The user chose "Lock Now". The away gate does not apply; every safety gate
    /// still does. A manual path that skipped dry-run once locked the screen during
    /// a test.
    mutating func lockNow(now: Date, readings: Readings) -> [Effect] {
        let absent = tracker.absent(now: now)
        let judgment = LockDecision.judgeManual(input(absent: absent, readings: readings, now: now))
        phase = judgment.phase
        return act(on: judgment.action, trigger: "manual lock",
                   absent: absent, idle: readings.idleFor, now: now)
    }

    // MARK: the radio

    /// One advertisement. The tracker reports that an address was adopted; copying
    /// it into the settings, and asking for them to be saved, is done here so the
    /// identity rule itself stays free of I/O.
    mutating func sight(_ sighting: Sighting, now: Date) -> [Effect] {
        let events = tracker.sight(sighting, now: now)
        guard !events.isEmpty else { return [] }
        var effects = events.map(Effect.reportKey)
        if tracker.knownAddresses != settings.knownKeyAddresses {
            settings.knownKeyAddresses = tracker.knownAddresses
            effects.append(.saveSettings)
        }
        return effects
    }

    // MARK: the user's choices

    mutating func toggleEnabled() -> [Effect] {
        settings.enabled.toggle()
        return [.saveSettings, .log("enabled = \(settings.enabled)")]
    }

    mutating func toggleActivity() -> [Effect] {
        settings.respectActivity.toggle()
        return [.saveSettings]
    }

    mutating func useManualWindow(_ seconds: Double) -> [Effect] {
        settings.windows.useManual(seconds, for: settings.device)
        return [.saveSettings,
                .log("awayWindow = \(Int(seconds)) (manual for '\(settings.keyName)')"
                     + (seconds < 15 ? "  (below the measured 10.2s worst case — expect false locks)" : ""))]
    }

    mutating func useAutomaticWindow(now: Date) -> [Effect] {
        settings.windows.forget(settings.device)
        learning = Learning(beganAt: now)
        tracker.restartLearning()
        return [.saveSettings,
                .log("awayWindow = automatic (re-learning from now, warm-up \(Int(Windows.warmup))s)")]
    }

    /// A new key device invalidates everything learned about the old one: its
    /// channels, its addresses, its window, and any lock cooldown.
    mutating func setKey(_ name: String, now: Date) -> [Effect] {
        settings.keyName = name
        settings.knownKeyAddresses = []
        tracker.setKey(name)
        learning = Learning(beganAt: now)
        phase = .noKey
        lastLockAt = nil
        return [.saveSettings, .log("key device -> '\(name)' (channels reset, re-arming)")]
    }

    // MARK: private

    private func input(absent: Double?, readings: Readings, now: Date) -> LockInput {
        LockInput(phase: phase,
                  enabled: settings.enabled,
                  absentFor: absent,
                  window: settings.awayWindow.seconds,
                  idleFor: readings.idleFor,
                  respectActivity: settings.respectActivity,
                  dryRun: settings.dryRun,
                  screenLocked: readings.screenLocked,
                  lastLockAt: lastLockAt,
                  now: now)
    }

    /// Once a device has produced enough real gaps, derive its window and stop
    /// learning. A window chosen from two minutes of data would be chosen from the
    /// quietest two minutes of the day, so this waits.
    private mutating func settleWindow(now: Date) -> [Effect] {
        guard let learned = learning.settle(now: now, arrivals: tracker.arrivals,
                                            windows: settings.windows,
                                            device: settings.device) else { return [] }
        settings.windows.useLearned(learned.window, for: settings.device)
        return [.saveSettings,
                .log(String(format: "window learned: %.1fs (worst kept gap %.1fs of %d samples) — warm-up was %.0fs",
                            learned.window, learned.worst, learned.kept, Windows.warmup))]
    }

    /// Turn a verdict into effects. Both entry points come through here, so what
    /// each verdict means for the log and the cooldown cannot drift apart.
    private mutating func act(on action: LockAction, trigger: String,
                              absent: Double?, idle: Double?, now: Date) -> [Effect] {
        switch action {
        case .none, .holdCooldown:
            return []
        case .holdActive:
            // Throttled: this repeats every tick while the signal is gone and you
            // are still working.
            guard now.timeIntervalSince(lastHoldLog) > Self.holdLogEvery else { return [] }
            lastHoldLog = now
            return [.log("away \(Int(absent ?? 0))s but user active"
                         + " (\(String(format: "%.0f", idle ?? 0))s idle) — holding")]
        case .alreadyLocked:
            lastLockAt = now
            return [.log("\(trigger) but screen already locked — nothing to do")]
        case .dryRun:
            lastLockAt = now
            return [.log("\(trigger) -> WOULD LOCK (dry-run)")]
        case .lock:
            // Neither the cooldown nor the phase moves until `lockFinished`.
            return [.lock(trigger: trigger)]
        }
    }

    /// Every 10 s, record the exact inputs the decision was made from. Without this
    /// a "nothing happened" log is indistinguishable from a dozen different causes,
    /// which is what made the first live failure opaque.
    private mutating func heartbeat(absent: Double?, readings: Readings, now: Date) -> [Effect] {
        guard now.timeIntervalSince(lastBeat) >= Self.heartbeatEvery else { return [] }
        lastBeat = now
        return [.log("hb absent=\(absent.map { String(format: "%.1fs", $0) } ?? "never")"
                     + " phase=\(phase.label) ch=\(tracker.channels.count)"
                     + " idle=\(readings.idleFor.map { String(format: "%.0fs", $0) } ?? "unreadable")"
                     + " locked=\(readings.screenLocked ? 1 : 0)"
                     + " enabled=\(settings.enabled ? 1 : 0)"
                     + " window=\(Int(settings.awayWindow.seconds))"
                     + " rssi=\(tracker.bestChannel()?.lastRSSI ?? 0)"
                     + " gaps=\(tracker.arrivals.count)"
                     + " named=\(tracker.named.count)")]
    }
}
