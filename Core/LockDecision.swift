import Foundation

/// Where the app is in its conversation with the user, which is also what the
/// menu icon shows.
enum Phase: Equatable {
    case noKey       // never heard the key
    case armed       // key present
    case away        // key gone
    case lockedOut   // we locked; wait for the user to come back
}

extension Phase {
    var label: String {
        switch self {
        case .noKey: return "noKey"
        case .armed: return "armed"
        case .away: return "away"
        case .lockedOut: return "lockedOut"
        }
    }

    var symbol: String {
        switch self {
        case .noKey: return "lock.slash"
        case .armed: return "lock.open"
        case .away: return "lock.rotation"
        case .lockedOut: return "lock.fill"
        }
    }
}

/// What this tick should do about locking.
enum LockAction: Equatable {
    case none
    /// Gates cleared: call the locker.
    case lock
    /// Away, but the user is still here.
    case holdActive
    /// Away, but we locked recently.
    case holdCooldown
    /// Away, and somebody already locked the screen.
    case alreadyLocked
    /// Away, and this build does not lock.
    case dryRun
}

/// The readings the decision is made from. Every field is a fact the app
/// measured or read; the decision itself is a pure function of them.
struct LockInput {
    var phase: Phase
    var enabled: Bool
    var absentFor: Double?
    var window: Double
    var idleFor: Double?
    var respectActivity: Bool
    var dryRun: Bool
    var screenLocked: Bool
    var lastLockAt: Date?
    var now: Date
    /// Minimum time between locks, so a flapping signal cannot lock you twice.
    var cooldown: TimeInterval = 20
    /// Presence needed to leave the locked-out state.
    var rearmBelow: Double = 3
}

struct Judgment: Equatable {
    var phase: Phase
    var action: LockAction
}

extension Judgment: CustomStringConvertible {
    var description: String { "\(phase.label)/\(action)" }
}

extension LockAction: CustomStringConvertible {
    var description: String {
        switch self {
        case .none: return "none"
        case .lock: return "lock"
        case .holdActive: return "holdActive"
        case .holdCooldown: return "holdCooldown"
        case .alreadyLocked: return "alreadyLocked"
        case .dryRun: return "dryRun"
        }
    }
}

/// The lock decision, as one function.
///
/// The interface is the test surface: hand it readings, get a verdict, no screen
/// and no timer involved. Both lock entry points — the tick and the menu — go
/// through here, because the two failures this app actually shipped (a lock while
/// sitting at the desk, and a manual lock that ignored dry-run) were both a gate
/// list that had drifted.
///
/// The invariant callers rely on: a `lock` verdict leaves the phase at `away`.
/// The phase becomes `lockedOut` only once the lock is *confirmed*, so a failed
/// lock retries on the next tick instead of waiting out the cooldown.
enum LockDecision {
    static func judge(_ input: LockInput) -> Judgment {
        guard input.enabled else { return Judgment(phase: .noKey, action: .none) }

        // Locked out is checked first: while locked, a key that has gone quiet for
        // ten minutes must not decay into "no key" and re-arm.
        if input.phase == .lockedOut {
            if let absent = input.absentFor, absent < input.rearmBelow {
                return Judgment(phase: .armed, action: .none)
            }
            return Judgment(phase: .lockedOut, action: .none)
        }

        guard let absent = input.absentFor else {
            return Judgment(phase: .noKey, action: .none)
        }
        guard absent >= input.window else {
            return Judgment(phase: .armed, action: .none)
        }

        // Away. The gates are ordered, and the first two do not resolve the
        // attempt while the last two do.
        if let last = input.lastLockAt, input.now.timeIntervalSince(last) < input.cooldown {
            return Judgment(phase: .away, action: .holdCooldown)
        }

        // Require the user to have been idle for the whole window, not just for a
        // moment. This makes "you are actively using the Mac" a hard guarantee
        // against a false lock: while you type or move the mouse we never lock.
        // When you genuinely walk away you stop touching the machine, so the idle
        // timer starts at the same moment the signal dies and adds no latency.
        if input.respectActivity, let idle = input.idleFor, idle < input.window {
            return Judgment(phase: .away, action: .holdActive)
        }

        if input.screenLocked {
            return Judgment(phase: .lockedOut, action: .alreadyLocked)
        }
        if input.dryRun {
            return Judgment(phase: .lockedOut, action: .dryRun)
        }
        return Judgment(phase: .away, action: .lock)
    }

    /// A lock the user asked for. The away gate does not apply — that is the whole
    /// point of asking — but every safety gate does, and the phase stays whatever
    /// it was so a failed attempt leaves the icon honest.
    static func judgeManual(_ input: LockInput) -> Judgment {
        guard input.enabled else { return Judgment(phase: input.phase, action: .none) }
        if input.screenLocked {
            return Judgment(phase: .lockedOut, action: .alreadyLocked)
        }
        if input.dryRun {
            return Judgment(phase: .lockedOut, action: .dryRun)
        }
        return Judgment(phase: input.phase, action: .lock)
    }
}