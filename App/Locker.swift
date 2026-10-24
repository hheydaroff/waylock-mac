import Foundation
import IOKit

// ─────────────────────────── private lock API ───────────────────────────
//
// CGSession -suspend is gone on modern macOS. login.framework still exports
// SACLockScreenImmediate, but it reports success even when nothing locked, so we
// always verify through CGSSessionScreenIsLocked.
//
// Deliberately one module for three OS surfaces (lock, screen state, HID idle):
// each has exactly one caller and the complexity behind each does not move with
// it. Split it when a second lock mechanism arrives — that would be the second
// adapter that makes the seam real.

@_silgen_name("CGSessionCopyCurrentDictionary")
func CGSessionCopyCurrentDictionary() -> CFDictionary?

enum Locker {
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Returns only what was verified, not what the private call reported.
    @discardableResult
    static func lock() -> Bool {
        // Resolved on every attempt rather than cached in a static: dlopen on a
        // framework that is already loaded and dlsym are both cheap, a lock is a
        // once-a-day event, and a cached handle is process-wide mutable state that
        // Swift 6 could only accept by being told to look away.
        let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
                               RTLD_LAZY)
        guard let framework, let symbol = dlsym(framework, "SACLockScreenImmediate") else {
            log("lock: could not resolve SACLockScreenImmediate")
            return false
        }
        typealias Lock = @convention(c) () -> Int32
        let rc = unsafeBitCast(symbol, to: Lock.self)()

        // The private call lies, so the answer is the session dictionary.
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

    /// Seconds since the last keyboard or mouse event; `nil` if IOKit cannot say.
    static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let idle = IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return idle.doubleValue / 1_000_000_000
    }
}