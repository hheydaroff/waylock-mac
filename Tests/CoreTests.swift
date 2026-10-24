import Foundation
import Testing
@testable import WaylockCore

// Every decision Waylock makes lives in Core and is a function of its inputs, so
// these tests need no radio, no Bluetooth permission and cannot lock the screen.
//
// Time is always passed in. A few tests read `Date()` for "now", but only as a
// base that the test then offsets, never as something the outcome depends on.

// MARK: - Helpers

/// A numeric expectation that prints both sides on failure. Optionals are compared
/// as optionals, so `nil` can never be mistaken for zero; numbers match to within
/// 0.05 because the windows are reported to one decimal place.
func expectNumber(_ got: Double?, _ want: Double?, _ label: String,
                  sourceLocation: SourceLocation = #_sourceLocation) {
    let format: (Double?) -> String = { $0.map { String(format: "%.1f", $0) } ?? "nil" }
    let matches: Bool
    switch (got, want) {
    case (nil, nil): matches = true
    case let (g?, w?): matches = abs(g - w) < 0.05
    default: matches = false
    }
    #expect(matches, "\(label): got \(format(got)), want \(format(want))",
            sourceLocation: sourceLocation)
}

/// A gap distribution with the shape actually measured on a real device: a
/// median-ish body plus one worst case. Not random, so a failure is reproducible.
func gaps(count: Int, median: Double, worst: Double) -> [Double] {
    guard count > 0 else { return [] }
    let body = (0..<count).map { median * (0.4 + 0.6 * Double($0) / Double(count)) }
    return body + [worst]
}

func arrivals(_ gaps: [Double]) -> Arrivals {
    var history = Arrivals()
    var now = Date()
    history.record(now: now)           // the first record only starts the clock
    for gap in gaps {
        now = now.addingTimeInterval(gap)
        history.record(now: now)
    }
    return history
}

func recommend(_ gaps: [Double]) -> Arrivals.Recommendation? { arrivals(gaps).recommendation() }

func past(_ seconds: Double) -> Date { Date().addingTimeInterval(-seconds) }

// MARK: - Arrivals and windows

@Suite("Arrivals: deriving a window from measured gaps")
struct ArrivalsTests {

    @Test("five gaps are too few to recommend a window")
    func tooFewSamples() {
        var sparse = Arrivals()
        for i in 0..<5 { sparse.record(now: Date().addingTimeInterval(Double(i))) }
        expectNumber(sparse.recommendation()?.window, nil, "5 gaps")
    }

    @Test("a strap-like device with a 2.6 s worst gap gets the 12 s floor")
    func strapLike() {
        expectNumber(recommend(gaps(count: 60, median: 1.5, worst: 2.6))?.window, 12.0,
                     "strap-like (max 2.6s)")
    }

    @Test("a buds-like device with a 10.2 s worst gap gets 15.3 s")
    func budsLike() {
        expectNumber(recommend(gaps(count: 60, median: 1.5, worst: 10.2))?.window, 15.3,
                     "buds-like (max 10.2s)")
    }

    @Test("a slow device with an 11 s worst gap gets 16.5 s")
    func slowDevice() {
        expectNumber(recommend(gaps(count: 60, median: 5, worst: 11))?.window, 16.5,
                     "slow device (max 11s)")
    }

    @Test("a slow device needs a bigger window than a chatty one")
    func slowBeatsChatty() throws {
        let chatty = try #require(recommend(gaps(count: 60, median: 1.0, worst: 3.0))).window
        let quiet = try #require(recommend(gaps(count: 60, median: 9.0, worst: 20.0))).window
        #expect(chatty < quiet, "chatty \(chatty)s should be below quiet \(quiet)s")
    }

    @Test("a 45 second walk-away gap is an absence, not device behaviour")
    func absenceIsNotLearned() {
        var withAway = gaps(count: 60, median: 1.5, worst: 6.0)
        withAway.append(45.0)                              // a trip to a meeting
        let outlied = recommend(withAway)
        expectNumber(outlied?.worst, 6.0, "45s absence is NOT learned as a gap")
        expectNumber(outlied?.window, 12.0, "...so the window stays at the floor")
    }

    @Test("a chatty device keeps its own 8 s gap instead of calling it an absence")
    func realGapIsKept() {
        expectNumber(recommend(gaps(count: 60, median: 0.5, worst: 8.2))?.window, 12.3,
                     "strap-like with a real 8.2s gap")
    }

    @Test("an absurd worst gap is clamped to 60 s")
    func absurdMaxClamps() {
        expectNumber(recommend(gaps(count: 60, median: 30, worst: 200))?.window, 60.0,
                     "absurd max clamps to 60s")
    }

    @Test("a very quiet device is clamped to 60 s")
    func quietDeviceClamps() {
        expectNumber(recommend(gaps(count: 60, median: 40, worst: 120))?.window, 60.0,
                     "very quiet device clamps to 60s")
    }
}

@Suite("Windows: warm-up, learned and manual precedence")
struct WindowsTests {

    @Test("with nothing measured a device gets the warm-up window and is still learning")
    func warmup() {
        let windows = Windows()
        expectNumber(windows.choice(for: "k").seconds, Windows.warmup, "nothing measured -> warm-up")
        #expect(windows.choice(for: "k").isLearning, "a warm-up window means still learning")
    }

    @Test("a learned window applies")
    func learnedApplies() {
        var windows = Windows()
        windows.useLearned(16, for: "k")
        expectNumber(windows.choice(for: "k").seconds, 16.0, "learned applies")
    }

    @Test("a manual window beats a learned one")
    func manualBeatsLearned() {
        var windows = Windows()
        windows.useLearned(16, for: "k")
        windows.useManual(25, for: "k")
        expectNumber(windows.choice(for: "k").seconds, 25.0, "manual beats learned")
    }

    @Test("choosing 'use measured' clears the manual override")
    func useMeasuredClearsManual() {
        var windows = Windows()
        windows.useLearned(16, for: "k")
        windows.useManual(25, for: "k")
        windows.useLearned(14, for: "k")
        expectNumber(windows.choice(for: "k").seconds, 14.0, "'use measured' clears the override")
        #expect(windows.choice(for: "k").source.rawValue == "learned",
                "the source should be learned, not manual")
    }

    @Test("another device is untouched by a window set for this one")
    func devicesAreIndependent() {
        var windows = Windows()
        windows.useLearned(16, for: "k")
        windows.useManual(25, for: "k")
        #expect(windows.choice(for: "other").source.rawValue == "warmup",
                "an unrelated device should still be on warm-up")
    }
}

@Suite("Learning: waiting for enough observation")
struct LearningTests {
    let session = Learning(beganAt: Date())
    let measured = arrivals(gaps(count: 60, median: 1.5, worst: 10.2))

    @Test("one minute of observation is not enough to settle")
    func oneMinuteIsTooSoon() {
        expectNumber(session.settle(now: Date().addingTimeInterval(60), arrivals: measured,
                                    windows: Windows(), device: "k")?.window,
                     nil, "one minute is not enough")
    }

    @Test("three minutes of observation settles on the measured window")
    func threeMinutesSettles() {
        expectNumber(session.settle(now: Date().addingTimeInterval(181), arrivals: measured,
                                    windows: Windows(), device: "k")?.window,
                     15.3, "three minutes settles")
    }

    @Test("a device that has already settled stops learning")
    func settledStopsLearning() {
        var settled = Windows()
        settled.useLearned(15.3, for: "k")
        expectNumber(session.settle(now: Date().addingTimeInterval(999), arrivals: measured,
                                    windows: settled, device: "k")?.window,
                     nil, "a settled device stops learning")
    }
}

// MARK: - Identity
//
// The rule that a colleague with the same model must not keep the Mac unlocked.
// Staging that for real is impossible, which is why the rule is a value type.

@Suite("KeyIdentity: telling your device from a lookalike")
struct IdentityTests {
    let mine = UUID()
    let impostor = UUID()
    let rotated = UUID()

    @Test("on first run the first matching address is adopted and remembered")
    func firstRun() {
        var identity = KeyIdentity(keyName: "Helio")
        #expect(identity.classify(name: "Amazfit Helio Strap", address: mine.uuidString, rival: false)
                    == .firstAddress,
                "adopts the first address it sees")
        #expect(identity.known == [mine.uuidString], "...and remembers it")
    }

    @Test("a colleague's identical strap is rejected and never learned")
    func impostorRejected() {
        var identity = KeyIdentity(keyName: "Helio")
        _ = identity.classify(name: "Amazfit Helio Strap", address: mine.uuidString, rival: false)
        #expect(identity.classify(name: "Amazfit Helio Strap", address: impostor.uuidString, rival: true)
                    == .impostor,
                "impostor is rejected")
        #expect(!identity.known.contains(impostor.uuidString), "impostor is NOT learned")
        #expect(identity.classify(name: "Amazfit Helio Strap", address: mine.uuidString, rival: true)
                    == .ours,
                "your device is still ours")
    }

    @Test("a rotated address is adopted when nobody else is around")
    func genuineRotation() {
        var identity = KeyIdentity(keyName: "Helio", known: [mine.uuidString])
        #expect(identity.classify(name: "Amazfit Helio Strap", address: rotated.uuidString, rival: false)
                    == .rotation,
                "rotated address is adopted")
        #expect(identity.known.contains(rotated.uuidString), "...and learned")
    }

    @Test("a device with a different name is never the key")
    func differentNameNeverMatches() {
        var identity = KeyIdentity(keyName: "Helio", known: [mine.uuidString])
        #expect(identity.classify(name: "Govee_H6046_712B", address: UUID().uuidString, rival: false)
                    == .notKey,
                "different device")
    }

    @Test("the name match ignores case and accepts a substring")
    func nameMatchIsLoose() {
        var identity = KeyIdentity(keyName: "helio")
        #expect(identity.classify(name: "Amazfit HELIO Strap", address: "x", rival: false)
                    == .firstAddress,
                "case and substring")
    }

    @Test("the learned address set is capped and keeps the newest")
    func learnedSetIsCapped() {
        var crowded = KeyIdentity(keyName: "k")
        for i in 0..<12 { _ = crowded.classify(name: "k device", address: "addr\(i)", rival: false) }
        #expect(crowded.known.count == KeyIdentity.maxKnown,
                "keeps \(KeyIdentity.maxKnown), had \(crowded.known.count)")
        #expect(crowded.known.last == "addr11", "...the newest, had \(String(describing: crowded.known.last))")
    }
}

// MARK: - Tracker
//
// The tracker is handed sightings and times, so an entire walk-away, and an
// impostor standing next to you, replays in microseconds.

func sighting(_ name: String, _ address: UUID, _ rssi: Int = -60) -> Sighting {
    Sighting(name: name, address: address, rssi: rssi)
}

@Suite("Tracker: presence from a stream of sightings")
struct TrackerTests {
    let mine = UUID()
    let impostor = UUID()
    let strap = "Amazfit Helio Strap"

    @Test("the first sighting teaches an address and opens a channel")
    func firstSighting() {
        var tracker = Tracker(keyName: "Helio")
        let now = Date()
        let events = tracker.sight(sighting(strap, mine), now: now)
        #expect(events == [.learnedAddress(address: mine.uuidString, first: true),
                           .newChannel(name: strap, address: mine.uuidString)],
                "first sighting teaches an address, got \(events)")
        expectNumber(tracker.absent(now: now), 0.0, "no absence yet")
        expectNumber(tracker.absent(now: now.addingTimeInterval(5)), 5.0, "5s of silence")
    }

    @Test("unrelated devices are ignored, do not refresh the key, but stay listed for the picker")
    func unrelatedDevicesAreIgnored() {
        var tracker = Tracker(keyName: "Helio")
        let start = Date()
        _ = tracker.sight(sighting(strap, mine), now: start)
        let now = start.addingTimeInterval(5)
        #expect(tracker.sight(sighting("Govee_H6046_712B", UUID()), now: now).isEmpty,
                "govee ignored")
        expectNumber(tracker.absent(now: now), 5.0, "...and do not refresh us")
        #expect(tracker.named.count == 2, "...but stay listed for the picker, had \(tracker.named.count)")
    }

    @Test("an impostor is reported but does not count as presence")
    func impostorIsNotPresence() {
        var tracker = Tracker(keyName: "Helio")
        var now = Date()
        _ = tracker.sight(sighting(strap, mine), now: now)
        now = now.addingTimeInterval(1)
        #expect(tracker.sight(sighting(strap, mine), now: now).isEmpty, "our device refreshes")
        now = now.addingTimeInterval(1)
        #expect(tracker.sight(sighting(strap, impostor), now: now)
                    == [.ignoredImpostor(name: strap, address: impostor.uuidString)],
                "impostor is reported")
        #expect(tracker.channels[impostor] == nil, "...but not tracked")
        expectNumber(tracker.absent(now: now), 1.0, "...and does not refresh us")
    }

    // The trade-off, stated plainly: a device that legitimately advertises under two
    // addresses at once is followed under the first until that one falls silent.
    @Test("a rotated address is adopted only once the old one has gone quiet")
    func rotationWaitsForSilence() {
        var tracker = Tracker(keyName: "Helio")
        var now = Date()
        let second = UUID()
        _ = tracker.sight(sighting(strap, mine), now: now)
        now = now.addingTimeInterval(2)
        #expect(tracker.sight(sighting(strap, second), now: now)
                    == [.ignoredImpostor(name: strap, address: second.uuidString)],
                "new address while ours is live is refused")
        now = now.addingTimeInterval(KeyIdentity.rivalWindow + 1)
        _ = tracker.sight(sighting(strap, second), now: now)
        #expect(tracker.channels.count == 2, "adopted once it is alone, had \(tracker.channels.count) channels")
        expectNumber(tracker.absent(now: now), 0.0, "newest wins for absence")
    }

    @Test("a stale channel expires so it cannot hold the Mac open")
    func channelsExpire() {
        var tracker = Tracker(keyName: "Helio")
        var now = Date()
        _ = tracker.sight(sighting(strap, mine), now: now)
        now = now.addingTimeInterval(Tracker.channelLifetime + 1)
        tracker.prune(now: now)
        expectNumber(tracker.absent(now: now), nil, "channel gone after 10 min")
    }

    @Test("changing the key forgets the old device and matches the new name")
    func changingTheKey() {
        var replaced = Tracker(keyName: "Helio", known: [mine.uuidString])
        _ = replaced.sight(sighting(strap, mine), now: Date())
        replaced.setKey("Buds3")
        expectNumber(replaced.absent(now: Date()), nil, "channels cleared")
        #expect(replaced.knownAddresses.isEmpty, "addresses cleared")
        let buds = replaced.sight(sighting("Galaxy Buds3 Pro", UUID()), now: Date())
        #expect(buds.contains { if case .newChannel = $0 { return true } else { return false } },
                "new name matches, got \(buds)")
    }
}

// MARK: - Lock decision
//
// The two failures this app actually shipped live in here.

func judge(phase: Phase = .armed,
           enabled: Bool = true,
           absent: Double? = nil,
           window: Double = 15,
           idle: Double? = 60,
           respectActivity: Bool = true,
           dryRun: Bool = false,
           locked: Bool = false,
           lastLockAt: Date? = nil,
           now: Date = Date()) -> Judgment {
    LockDecision.judge(LockInput(phase: phase, enabled: enabled, absentFor: absent,
                                 window: window, idleFor: idle, respectActivity: respectActivity,
                                 dryRun: dryRun, screenLocked: locked,
                                 lastLockAt: lastLockAt, now: now))
}

func manual(phase: Phase = .armed, enabled: Bool = true,
            dryRun: Bool = false, locked: Bool = false) -> Judgment {
    LockDecision.judgeManual(LockInput(phase: phase, enabled: enabled, absentFor: 0.5,
                                       window: 15, idleFor: 1, respectActivity: true,
                                       dryRun: dryRun, screenLocked: locked,
                                       lastLockAt: nil, now: Date()))
}

@Suite("LockDecision: when to lock and when to hold")
struct DecisionTests {

    @Test("a present key keeps the Mac armed")
    func presentKey() {
        #expect(judge(absent: 2) == Judgment(phase: .armed, action: .none), "key present -> armed")
    }

    @Test("fifteen seconds of silence locks; 14.9 does not")
    func windowBoundary() {
        #expect(judge(absent: 15) == Judgment(phase: .away, action: .lock), "15s of silence -> lock")
        #expect(judge(absent: 14.9) == Judgment(phase: .armed, action: .none), "14.9s is not yet")
    }

    @Test("a key never seen, or a disabled app, never acts")
    func neverSeenOrDisabled() {
        #expect(judge(absent: nil) == Judgment(phase: .noKey, action: .none), "never seen -> noKey")
        #expect(judge(enabled: false, absent: 60) == Judgment(phase: .noKey, action: .none),
                "disabled -> noKey, no action")
    }

    @Test("recent typing holds the lock: the desk false-lock")
    func activityGate() {
        #expect(judge(absent: 40, idle: 3) == Judgment(phase: .away, action: .holdActive),
                "away 40s but typing 3s ago -> hold")
        #expect(judge(absent: 40, idle: 40) == Judgment(phase: .away, action: .lock),
                "away 40s and idle 40s -> lock")
        #expect(judge(absent: 20, idle: 15) == Judgment(phase: .away, action: .lock),
                "idle exactly at the window -> lock")
    }

    @Test("with the activity gate off, or idle time unreadable, the gate does not block")
    func activityGateOffOrUnreadable() {
        #expect(judge(absent: 20, idle: 0, respectActivity: false)
                    == Judgment(phase: .away, action: .lock),
                "activity gate off -> locks anyway")
        #expect(judge(absent: 20, idle: nil) == Judgment(phase: .away, action: .lock),
                "idle unreadable does not block")
    }

    @Test("a flapping signal cannot lock twice inside the cooldown")
    func cooldown() {
        #expect(judge(absent: 40, idle: 40, lastLockAt: past(5))
                    == Judgment(phase: .away, action: .holdCooldown),
                "locked 5s ago -> cooldown")
        #expect(judge(absent: 40, idle: 40, lastLockAt: past(25))
                    == Judgment(phase: .away, action: .lock),
                "locked 25s ago -> lock")
    }

    @Test("an attempt that resolves without locking: already locked, dry run, and their precedence")
    func resolvedWithoutLocking() {
        #expect(judge(absent: 40, locked: true)
                    == Judgment(phase: .lockedOut, action: .alreadyLocked),
                "screen already locked")
        #expect(judge(absent: 40, dryRun: true) == Judgment(phase: .lockedOut, action: .dryRun),
                "dry run")
        #expect(judge(absent: 40, dryRun: true, locked: true)
                    == Judgment(phase: .lockedOut, action: .alreadyLocked),
                "already locked beats dry run")
        #expect(judge(absent: 40, dryRun: true, locked: true, lastLockAt: past(1))
                    == Judgment(phase: .away, action: .holdCooldown),
                "cooldown beats already-locked")
    }

    @Test("once locked out, only a real return re-arms")
    func lockedOutWaitsForReturn() {
        #expect(judge(phase: .lockedOut, absent: 60) == Judgment(phase: .lockedOut, action: .none),
                "still away -> stays locked out")
        #expect(judge(phase: .lockedOut, absent: 3.0) == Judgment(phase: .lockedOut, action: .none),
                "3s of silence -> still locked out")
        #expect(judge(phase: .lockedOut, absent: 2.9) == Judgment(phase: .armed, action: .none),
                "under 3s -> re-armed")
        #expect(judge(phase: .lockedOut, absent: nil) == Judgment(phase: .lockedOut, action: .none),
                "channel expired while locked -> still locked out, not noKey")
    }

    @Test("the window passed in for a device is the one used")
    func perDeviceWindow() {
        #expect(judge(absent: 13, window: 12) == Judgment(phase: .away, action: .lock),
                "per-device window")
    }

    @Test("a manual lock waives the away gate but keeps the safety gates")
    func manualLock() {
        #expect(manual() == Judgment(phase: .armed, action: .lock), "key present, asked -> lock")
        #expect(manual(dryRun: true) == Judgment(phase: .lockedOut, action: .dryRun),
                "dry run still protects")
        #expect(manual(locked: true) == Judgment(phase: .lockedOut, action: .alreadyLocked),
                "already locked is a no-op")
        #expect(manual(enabled: false) == Judgment(phase: .armed, action: .none),
                "disabled does nothing")
        #expect(manual(phase: .away) == Judgment(phase: .away, action: .lock),
                "phase left alone for a failed lock")
    }
}

// MARK: - Menu copy
//
// The menu is the app's only explanation of itself, so its wording is asserted.

func snapshot(phase: Phase = .armed, enabled: Bool = true, dryRun: Bool = false,
              bluetooth: RadioState = .on,
              window: AwayWindow? = nil, windows: Windows = Windows(),
              best: Channel? = nil, count: Int = 0) -> MenuSnapshot {
    MenuSnapshot(phase: phase, enabled: enabled, dryRun: dryRun, bluetooth: bluetooth,
                 keyName: "Helio", device: "helio",
                 window: window ?? AwayWindow(seconds: 20, source: .warmup),
                 windows: windows, bestChannel: best, channelCount: count,
                 respectActivity: true, loginEnabled: false, now: Date())
}

func awayItems(_ s: MenuSnapshot) -> [MenuItem] {
    let row = MenuModel.items(s).first { $0.title == "Away for" }
    guard case let .children(items)? = row?.content else { return [] }
    return items
}

@Suite("MenuModel: the wording the user reads")
struct MenuTests {

    @Test("the status title explains why the app is not armed")
    func statusTitles() {
        #expect(MenuModel.status(snapshot(bluetooth: .unknown)).title == "Waiting for Bluetooth permission",
                "permission pending")
        #expect(MenuModel.status(snapshot(bluetooth: .off)).title == "Bluetooth unavailable",
                "bluetooth off")
        #expect(MenuModel.status(snapshot(enabled: false, bluetooth: .unknown)).title == "Disabled",
                "disabled wins over everything")
        #expect(MenuModel.status(snapshot(phase: .armed)).title == "Armed — key is present", "armed")
        #expect(MenuModel.status(snapshot(phase: .away)).title == "Key is away…", "away")
    }

    @Test("the status detail names what the app is waiting for")
    func statusDetails() {
        #expect(MenuModel.status(snapshot(phase: .lockedOut)).detail == "waiting for key to return",
                "locked out")
        #expect(MenuModel.status(snapshot(phase: .noKey)).detail == "no 'Helio' advertising yet",
                "no key names it")
    }

    @Test("a dry run is labelled in the title")
    func dryRunLabel() {
        #expect(MenuModel.status(snapshot(dryRun: true)).title == "DRY RUN · Armed — key is present",
                "dry run is labelled")
    }

    @Test("the device line shows the best channel, how many more, or a dash")
    func deviceLine() {
        let channel = Channel(name: "Amazfit Helio Strap", lastSeen: Date().addingTimeInterval(-4),
                              lastRSSI: -57, packets: 100)
        #expect(MenuModel.status(snapshot(best: channel, count: 1)).detail
                    == "Amazfit Helio Strap · -57 dBm · 4s ago",
                "best channel shown")
        #expect(MenuModel.status(snapshot(best: channel, count: 3)).detail
                    == "Amazfit Helio Strap · -57 dBm · 4s ago · +2",
                "extras counted")
        #expect(MenuModel.status(snapshot(best: nil)).detail == "—", "nothing yet")
    }

    @Test("Automatic is checked and says 'learning' while on the warm-up window")
    func awayMenuWhileLearning() {
        let items = awayItems(snapshot(window: AwayWindow(seconds: 20, source: .warmup)))
        #expect(items.first?.checked == true, "automatic is checked while learning")
        #expect(items.first?.title == "Automatic · learning…",
                "automatic says learning, got \(items.first?.title ?? "nil")")
    }

    @Test("Automatic names the learned window and stays checked")
    func awayMenuWhenLearned() {
        let items = awayItems(snapshot(window: AwayWindow(seconds: 15.3, source: .learned)))
        #expect(items.first?.title == "Automatic · learned 15 s",
                "learned window is named, got \(items.first?.title ?? "nil")")
        #expect(items.first?.checked == true, "automatic checked when learned")
    }

    @Test("with a manual window Automatic is unchecked and the chosen row is checked")
    func awayMenuWhenManual() {
        let items = awayItems(snapshot(window: AwayWindow(seconds: 20, source: .manual),
                                       windows: Windows(manual: ["helio": 20])))
        #expect(items.first?.checked == false, "automatic unchecked when manual")
        #expect(items.first { $0.title.hasPrefix("20") }?.checked == true, "manual window is checked")
    }

    @Test("windows short enough to false-lock are labelled, safe ones are not")
    func riskyWindowsAreLabelled() {
        let items = awayItems(snapshot(window: AwayWindow(seconds: 20, source: .manual),
                                       windows: Windows(manual: ["helio": 20])))
        #expect(items.contains { $0.title == "10 seconds · may false-lock" },
                "risky windows are labelled")
        #expect(items.contains { $0.title == "15 seconds" }, "safe windows are not")
    }

    @Test("the key picker marks the current key and shows the advertising rate")
    func pickerMarksCurrentKey() {
        let device = NamedDevice(name: "Amazfit Helio Strap", address: UUID(),
                                 firstSeen: Date().addingTimeInterval(-100), lastSeen: Date(),
                                 rssi: -57, packets: 100)
        let picker = MenuModel.keyDevices([device], keyName: "helio")
        #expect(picker.first?.title.hasPrefix("\u{2713}") == true, "current key is marked")
        #expect(picker.first?.title.contains("60/min") == true, "rate is shown")
    }

    @Test("the key picker warns about a device that advertises too rarely to track")
    func pickerWarnsAboutRareDevices() {
        let rare = NamedDevice(name: "Slow Thing", address: UUID(),
                               firstSeen: Date().addingTimeInterval(-120), lastSeen: Date(),
                               rssi: -70, packets: 4)
        #expect(MenuModel.keyDevices([rare], keyName: "helio").first?.title.contains("too rare") == true,
                "a rare device is warned about")
    }

    @Test("the key picker says so when no named device is visible")
    func pickerWhenEmpty() {
        let title = MenuModel.keyDevices([], keyName: "helio").first?.title
        #expect(title == "No named devices visible", "no devices, got \(title ?? "nil")")
    }
}
