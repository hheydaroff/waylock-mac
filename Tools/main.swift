import CoreBluetooth
import Foundation

// Under SwiftPM these are separate modules; build.sh compiles everything as one,
// where there is nothing to import. Core and Adapters are internal by design (see
// AGENTS.md), which is why this is @testable and why every build is a debug build.
#if canImport(WaylockCore)
@testable import WaylockCore
@testable import WaylockAdapters
#endif

// Waylock's two radio-dependent commands. Everything they decide is in Core;
// what is left here is printing, because these are the runs that produce evidence
// and their output is read by a human.
//
//   waylock-tools --selftest [seconds]
//   waylock-tools --calibrate [minutes] [--apply]
//   waylock-tools --export-gaps [minutes] [--out path]

/// A live session: radio in, tracker out. Shared by both commands so the wire-up
/// exists once.
///
/// Main-actor bound: the radio delivers its callbacks on the main thread, and a
/// command-line tool prints and exits, so there is nothing here that wants a queue.
@MainActor
final class Live {
    let radio = Radio()
    /// When the all-absent test first fired, so the summary can say when.
    var firedAt: Double?
    private(set) var settings: Settings
    private(set) var tracker: Tracker
    private let store: SettingsStore

    init() {
        store = SettingsStore()
        settings = store.load()
        tracker = Tracker(keyName: settings.keyName, known: settings.knownKeyAddresses)
        radio.log = { print("  \($0)") }
        radio.onSighting = { [weak self] in self?.receive($0) }
    }

    func start() { radio.start() }

    func keep(_ window: Double) {
        settings.windows.useLearned(window, for: settings.device)
        store.save(settings)
    }

    private func receive(_ sighting: Sighting) {
        for event in tracker.sight(sighting, now: Date()) {
            print("  · \(describe(event, known: tracker.knownAddresses.count))")
        }
        if tracker.knownAddresses != settings.knownKeyAddresses {
            settings.knownKeyAddresses = tracker.knownAddresses
            store.save(settings)
        }
    }
}

/// Drives the real scan → match → all-absent path with no menu bar and no locking.
/// This is the part that can false-positive, so it is the part worth watching.
@MainActor func runSelfTest(seconds: Double) {
    let live = Live()
    let start = Date()

    print("selftest \(Int(seconds))s on '\(live.settings.keyName)'"
          + " (window \(Int(live.settings.awayWindow.seconds))s \(live.settings.awayWindow.label))")
    live.start()

    // A Timer block is @Sendable and Timer is not Sendable, so the block keeps the
    // timer and the body is handed only the elapsed seconds. The assumption is sound
    // because the timer is scheduled on RunLoop.main — same thread, no hop — and the
    // body answers with an exit code instead of reaching back into the timer.
    let step: @MainActor (Double) -> Int32? = { elapsed in
        let window = live.settings.awayWindow.seconds
        let now = Date()

        checkRadio(live, elapsed: elapsed)

        if let absent = live.tracker.absent(now: now) {
            let away = absent >= window
            let best = live.tracker.bestChannel()
            if away, live.firedAt == nil { live.firedAt = elapsed }
            print(String(format: "%5.0fs  %-7@  allAbsent=%.1fs window=%.0fs  best=%@ %ddBm %@",
                         elapsed,
                         (away ? "AWAY" : "present") as NSString,
                         absent, window,
                         (best?.name ?? "-") as NSString,
                         best?.lastRSSI ?? 0,
                         (away ? "<-- WOULD LOCK" : "") as NSString))
        } else {
            print(String(format: "%5.0fs  noKey     waiting for '%@'", elapsed,
                         live.settings.keyName as NSString))
        }

        guard elapsed >= seconds else { return nil }
        print("\nchannels tracked: \(live.tracker.channels.count)")
        for (id, channel) in live.tracker.channels.sorted(by: { $0.value.packets > $1.value.packets }) {
            print("  '\(channel.name)' \(id.uuidString.prefix(8))"
                  + " packets=\(channel.packets) last=\(channel.lastRSSI)dBm")
        }
        print(live.firedAt.map { String(format: "TRIGGERED at t=%.0fs", $0) }
              ?? "no trigger (stayed present)")
        return 0
    }
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
        let elapsed = Date().timeIntervalSince(start)
        let code = MainActor.assumeIsolated { step(elapsed) }
        guard let code else { return }
        timer.invalidate()
        exit(code)
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.run()
}

/// Measures this device's union-gap distribution and says what window it can
/// support. Sit at the desk with the device while it runs; walking away does not
/// corrupt the result (absences are discarded as outliers) but clean data is better.
@MainActor func runCalibration(minutes: Double, apply: Bool) {
    let live = Live()
    let start = Date()
    let total = max(30, minutes * 60)

    print("calibrating '\(live.settings.keyName)' for \(Int(total / 60)) min")
    print("stay at the desk with the device — this measures how long it is NORMALLY silent")
    if !live.settings.awayWindow.isLearning {
        print("note: this device has a window already"
              + " (\(Int(live.settings.awayWindow.seconds))s); --apply will overwrite it")
    }
    live.start()

    let step: @MainActor (Double) -> Int32? = { elapsed in
        checkRadio(live, elapsed: elapsed)
        let absent = live.tracker.absent(now: Date())
        print(String(format: "%5.0fs  ch=%d  gaps=%3d  absent=%@",
                     elapsed, live.tracker.channels.count, live.tracker.arrivals.count,
                     (absent.map { String(format: "%.1fs", $0) } ?? "never seen") as NSString))

        guard elapsed >= total else { return nil }

        let gaps = live.tracker.arrivals
        print("\nsamples \(gaps.count) over \(Int(elapsed))s")
        for (id, channel) in live.tracker.channels.sorted(by: { $0.value.packets > $1.value.packets }) {
            print("  '\(channel.name)' \(id.uuidString.prefix(8))"
                  + " packets=\(channel.packets) rssi=\(channel.lastRSSI)dBm")
        }

        guard let recommendation = gaps.recommendation() else {
            print("\nNOT ENOUGH DATA (need \(Arrivals.minSamples) gaps) — is the device advertising?")
            return 2
        }
        print(String(format: "\nrecommended window: %.1fs  (worst kept gap %.1fs x1.5, %d of %d samples)",
                     recommendation.window, recommendation.worst, recommendation.kept, gaps.count))

        if apply {
            live.keep(recommendation.window)
            print("applied: '\(live.settings.keyName)' now locks after"
                  + " \(Int(recommendation.window))s")
        } else {
            print("not applied — rerun with --apply to save it")
        }
        return 0
    }
    let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
        let elapsed = Date().timeIntervalSince(start)
        let code = MainActor.assumeIsolated { step(elapsed) }
        guard let code else { return }
        timer.invalidate()
        exit(code)
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.run()
}

/// Records the union-gap distribution and writes it out as JSON, so the window
/// choice can be argued with interactively instead of from a table.
///
/// This exists because the interesting question — "what does a 10 s window cost
/// me?" — cannot be answered from percentiles. It needs every gap that was
/// actually measured, so a reader can slide the window across them and watch the
/// false-lock count move. The output holds timings and nothing else: no
/// identifiers, so it is safe to publish alongside the histogram it feeds.
@MainActor func runExportGaps(minutes: Double, out path: String) {
    let live = Live()
    let start = Date()
    let total = max(30, minutes * 60)

    print("recording gaps for '\(live.settings.keyName)' for \(Int(total / 60)) min -> \(path)")
    print("stay at the desk with the device; absences are discarded as outliers, not learned")
    live.start()

    let step: @MainActor (Double) -> Int32? = { elapsed in
        checkRadio(live, elapsed: elapsed)
        print(String(format: "%5.0fs  ch=%d  gaps=%3d",
                     elapsed, live.tracker.channels.count, live.tracker.arrivals.count))

        guard elapsed >= total else { return nil }

        let arrivals = live.tracker.arrivals
        let gaps = arrivals.gaps
        guard gaps.count >= Arrivals.minSamples else {
            print("\nNOT ENOUGH DATA (need \(Arrivals.minSamples) gaps, got \(gaps.count))"
                  + " — is the device advertising?")
            return 2
        }

        // Percentiles are recomputed by the page, so this carries raw gaps only;
        // the recommendation is included to let a reader check the page against
        // the app instead of trusting the page.
        let recommendation = arrivals.recommendation()
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let payload = """
        {
          "device": \(quote(live.settings.keyName)),
          "seconds": \(String(format: "%.0f", elapsed)),
          "samples": \(gaps.count),
          "appWindow": \(String(format: "%.1f", live.settings.awayWindow.seconds)),
          "recommended": \(recommendation.map { String(format: "%.1f", $0.window) } ?? "null"),
          "worstKept": \(recommendation.map { String(format: "%.1f", $0.worst) } ?? "null"),
          "gaps": [\(gaps.map { String(format: "%.3f", $0) }.joined(separator: ","))]
        }

        """
        do {
            try payload.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            print("\ncould not write \(path): \(error.localizedDescription)")
            return 2
        }
        print("\nwrote \(gaps.count) gaps over \(Int(elapsed))s to \(path)")
        if let r = recommendation {
            print(String(format: "app would learn %.1fs (worst kept gap %.1fs, %d of %d samples)",
                         r.window, r.worst, r.kept, gaps.count))
        }
        return 0
    }
    let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
        let elapsed = Date().timeIntervalSince(start)
        let code = MainActor.assumeIsolated { step(elapsed) }
        guard let code else { return }
        timer.invalidate()
        exit(code)
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.run()
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: a hang must still leave a trace

/// The radio never reaching a known state is the failure that has no error
/// message: CoreBluetooth is waiting for a permission decision and will wait
/// forever. Fail loud instead of hanging — this is a tool, not the menu bar app.
/// Exits rather than returning, because a tool that waits forever for a permission
/// prompt looks exactly like a tool that is working.
@MainActor func checkRadio(_ live: Live, elapsed: Double) {
    guard live.radio.state == .unknown, elapsed > 20 else { return }
    print("""

    Bluetooth never reported a state after \(Int(elapsed))s.
    macOS is almost certainly waiting for a Bluetooth permission decision for
    this binary — approve the prompt if one is open. CLI runs inherit the
    terminal's grant, so running it from Terminal.app usually avoids the prompt.
    """)
    exit(2)
}

let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--export-gaps") {
    let minutes = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 10 : 10
    let out = arguments.firstIndex(of: "--out").flatMap { i in
        i + 1 < arguments.count ? arguments[i + 1] : nil
    } ?? "gaps.json"
    runExportGaps(minutes: minutes, out: out)
} else if let index = arguments.firstIndex(of: "--calibrate") {
    let minutes = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 10 : 10
    runCalibration(minutes: minutes, apply: arguments.contains("--apply"))
} else if arguments.contains("--selftest") {
    let index = arguments.firstIndex(of: "--selftest")!
    let seconds = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 40 : 40
    runSelfTest(seconds: seconds)
} else {
    print("""
    usage: waylock-tools --selftest [seconds]
           waylock-tools --calibrate [minutes] [--apply]
           waylock-tools --export-gaps [minutes] [--out path]   (feeds docs/window-simulator.html)

    The menu bar app is build/Waylock.app. Logic tests are `swift test`.
    """)
    exit(2)
}