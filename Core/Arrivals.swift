import Foundation

/// The union inter-arrival history for the key device.
///
/// Presence means "any channel was heard recently", so the gap that matters is
/// between *any* two packets, not per-channel timing: one buds stream once went
/// 31 s between its own packets while another stream was audible the whole time.
struct Arrivals: Equatable {
    struct Recommendation: Equatable {
        var window: Double
        /// Worst gap that survived the absence cutoff — what the window is sized for.
        var worst: Double
        var kept: Int
    }

    /// About 20 minutes at 1 Hz: long enough for a tail, cheap to keep.
    static let capacity = 1200
    /// Below this a recommendation is not evidence.
    static let minSamples = 20
    /// Gaps shorter than this are jitter, not observability.
    private static let minGap: TimeInterval = 0.05

    private(set) var gaps: [Double] = []
    private var lastAt: Date?

    var count: Int { gaps.count }

    mutating func record(now: Date) {
        defer { lastAt = now }
        guard let last = lastAt else { return }
        let gap = now.timeIntervalSince(last)
        guard gap > Self.minGap else { return }
        gaps.append(gap)
        if gaps.count > Self.capacity { gaps.removeFirst(gaps.count - Self.capacity) }
    }

    mutating func reset() {
        gaps.removeAll()
        lastAt = nil
    }

    /// The window this history supports.
    ///
    /// A real absence and a slowly-advertising device look identical in a raw gap
    /// list, so gaps beyond 10x the median are discarded as absences rather than
    /// learned as device behaviour. That cutoff has a floor of 1.25x the minimum
    /// window: without it a chatty device (median 0.5 s) treats its own honest 8 s
    /// gap as an absence and learns a window smaller than the gap it must cover.
    ///
    /// The remainder is scaled by 1.5 — headroom validated by hand on the buds
    /// baseline (10.2 s worst case at the desk -> 15 s window, zero false locks in
    /// 600 samples).
    func recommendation() -> Recommendation? {
        guard gaps.count >= Self.minSamples else { return nil }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let cutoff = max(Windows.minWindow * 1.25, median * 10)
        let kept = sorted.filter { $0 <= cutoff }
        guard let worst = kept.last else { return nil }
        // Round to the nearest 0.1 rather than up: the gaps come from Date
        // arithmetic, where 10.2 s is stored as 10.2000001, and rounding up turns
        // that noise into a window that is 0.1 s bigger than the one measured.
        let raw = max(Windows.minWindow, worst * 1.5)
        let window = min(Windows.maxWindow, (raw * 10).rounded() / 10)
        return Recommendation(window: window, worst: worst, kept: kept.count)
    }
}