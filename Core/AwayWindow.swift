import Foundation

/// Which away window applies to the key device, and why.
///
/// The "why" is load-bearing: a manual choice always wins, so a window chosen by
/// hand is never silently corrected by learning.
struct AwayWindow: Equatable {
    enum Source: String {
        case manual
        case learned
        case warmup
    }

    var seconds: Double
    var source: Source

    /// Still measuring this device, so the window is the slack warm-up.
    var isLearning: Bool { source == .warmup }

    /// What the startup log and the menu say about this window.
    var label: String {
        switch source {
        case .manual: return "manual"
        case .learned: return "learned \(Int(seconds))s"
        case .warmup: return "learning, warm-up"
        }
    }
}

/// Per-device away windows.
///
/// One constant cannot serve every key device: advertising rates differ by 5x (a
/// strap manages 0.67 Hz, one stray buds stream managed 0.09 Hz), so a window
/// that is comfortable for one device is either too slow for the other or
/// false-locks on it. Each device therefore gets its own, learned from its own
/// gaps.
struct Windows: Equatable {
    /// Deliberately slack. Being slow to lock costs a few seconds once; being
    /// quick costs a locked screen while you are still working.
    static let warmup: Double = 20
    static let minWindow: Double = 12
    static let maxWindow: Double = 60
    /// How long to observe before a measurement is trusted.
    static let learnPeriod: TimeInterval = 180

    var manual: [String: Double] = [:]
    var learned: [String: Double] = [:]

    func choice(for device: String) -> AwayWindow {
        if let m = manual[device] { return AwayWindow(seconds: m, source: .manual) }
        if let l = learned[device] { return AwayWindow(seconds: l, source: .learned) }
        return AwayWindow(seconds: Self.warmup, source: .warmup)
    }

    mutating func useManual(_ seconds: Double, for device: String) {
        manual[device] = seconds
    }

    /// "Use the measured value": records the measurement and drops any override.
    mutating func useLearned(_ seconds: Double, for device: String) {
        learned[device] = seconds
        manual.removeValue(forKey: device)
    }

    mutating func forget(_ device: String) {
        learned.removeValue(forKey: device)
        manual.removeValue(forKey: device)
    }
}

/// One observation session for the current key device.
///
/// The wait is the point: a window chosen from two minutes of data would be
/// chosen from the quietest two minutes of the day.
struct Learning: Equatable {
    var beganAt: Date

    /// The window to store, once this device has been observed long enough.
    /// `nil` means keep observing.
    func settle(now: Date,
                arrivals: Arrivals,
                windows: Windows,
                device: String) -> Arrivals.Recommendation? {
        guard windows.choice(for: device).isLearning else { return nil }
        guard now.timeIntervalSince(beganAt) >= Windows.learnPeriod else { return nil }
        return arrivals.recommendation()
    }
}