import Foundation

// ───────────────────────────── assertions ─────────────────────────────
//
// Three helpers, named so an optional can never be silently compared to a
// non-optional. Every failure prints what it saw, because a test that does not
// say what it got costs more than no test.

var checks = 0
var failures = 0

func pass(_ label: String, _ ok: Bool, _ detail: String) {
    checks += 1
    print("  \(ok ? "PASS" : "FAIL")  \(label)\(ok ? "" : "  -> \(detail)")")
    if !ok { failures += 1 }
}

func check(_ label: String, _ ok: Bool) {
    pass(label, ok, "false")
}

func check(_ label: String, _ got: String, _ want: String) {
    pass(label, got == want, "\(got) (want \(want))")
}

func checkNumber(_ label: String, _ got: Double?, _ want: Double?) {
    let format: (Double?) -> String = { $0.map { String(format: "%.1f", $0) } ?? "nil" }
    let matches: Bool
    switch (got, want) {
    case (nil, nil): matches = true
    case let (g?, w?): matches = abs(g - w) < 0.05
    default: matches = false
    }
    pass(label, matches, "\(format(got)) (want \(format(want)))")
}

func checkSame<T: Equatable & CustomStringConvertible>(_ label: String, _ got: T, _ want: T) {
    pass(label, got == want, "\(got) (want \(want))")
}

func section(_ title: String) {
    print("\n\(title)")
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

// ─────────────────────────── window derivation ───────────────────────────

section("too few samples is not a recommendation")
var sparse = Arrivals()
for i in 0..<5 { sparse.record(now: Date().addingTimeInterval(Double(i))) }
checkNumber("5 gaps", sparse.recommendation()?.window, nil)

section("measured devices")
checkNumber("strap-like (max 2.6s)", recommend(gaps(count: 60, median: 1.5, worst: 2.6))?.window, 12.0)
checkNumber("buds-like (max 10.2s)", recommend(gaps(count: 60, median: 1.5, worst: 10.2))?.window, 15.3)
checkNumber("slow device (max 11s)", recommend(gaps(count: 60, median: 5, worst: 11))?.window, 16.5)

section("a slow device needs a bigger window than a chatty one")
let chatty = recommend(gaps(count: 60, median: 1.0, worst: 3.0))!.window
let quiet = recommend(gaps(count: 60, median: 9.0, worst: 20.0))!.window
check("chatty \(chatty)s < quiet \(quiet)s", chatty < quiet)

section("a walk-away gap is an absence, not device behaviour")
var withAway = gaps(count: 60, median: 1.5, worst: 6.0)
withAway.append(45.0)                                  // a trip to a meeting
let outlied = recommend(withAway)
checkNumber("45s absence is NOT learned as a gap", outlied?.worst, 6.0)
checkNumber("...so the window stays at the floor", outlied?.window, 12.0)

section("a chatty device keeps its own 8s gap instead of calling it an absence")
checkNumber("strap-like with a real 8.2s gap", recommend(gaps(count: 60, median: 0.5, worst: 8.2))?.window, 12.3)

section("clamps")
checkNumber("absurd max clamps to 60s", recommend(gaps(count: 60, median: 30, worst: 200))?.window, 60.0)
checkNumber("very quiet device clamps to 60s", recommend(gaps(count: 60, median: 40, worst: 120))?.window, 60.0)

// ─────────────────────────── window precedence ───────────────────────────

section("warm-up, learning and manual precedence")
var windows = Windows()
checkNumber("nothing measured -> warm-up", windows.choice(for: "k").seconds, Windows.warmup)
check("...and it is learning", windows.choice(for: "k").isLearning)
windows.useLearned(16, for: "k")
checkNumber("learned applies", windows.choice(for: "k").seconds, 16.0)
windows.useManual(25, for: "k")
checkNumber("manual beats learned", windows.choice(for: "k").seconds, 25.0)
windows.useLearned(14, for: "k")
checkNumber("'use measured' clears the override", windows.choice(for: "k").seconds, 14.0)
check("...and drops manual", windows.choice(for: "k").source.rawValue, "learned")
check("another device is untouched", windows.choice(for: "other").source.rawValue, "warmup")

section("learning waits for enough observation")
let session = Learning(beganAt: Date())
let measured = arrivals(gaps(count: 60, median: 1.5, worst: 10.2))
let fresh = Windows()
checkNumber("one minute is not enough",
            session.settle(now: Date().addingTimeInterval(60), arrivals: measured,
                           windows: fresh, device: "k")?.window, nil)
checkNumber("three minutes settles",
            session.settle(now: Date().addingTimeInterval(181), arrivals: measured,
                           windows: fresh, device: "k")?.window, 15.3)
var settledWindows = Windows()
settledWindows.useLearned(15.3, for: "k")
checkNumber("a settled device stops learning",
            session.settle(now: Date().addingTimeInterval(999), arrivals: measured,
                           windows: settledWindows, device: "k")?.window, nil)

// ─────────────────────────────── identity ───────────────────────────────
//
// The rule that a colleague with the same model must not keep the Mac unlocked.
// Staging that for real is impossible, which is why the rule is a value type.

let mine = UUID()
let impostor = UUID()
let rotated = UUID()

section("first run, nothing learned yet")
var identity = KeyIdentity(keyName: "Helio")
checkSame("adopts the first address it sees",
          identity.classify(name: "Amazfit Helio Strap", address: mine.uuidString, rival: false),
          KeyIdentity.Verdict.firstAddress)
check("...and remembers it", identity.known == [mine.uuidString])

section("colleague's identical strap arrives")
checkSame("impostor is rejected",
          identity.classify(name: "Amazfit Helio Strap", address: impostor.uuidString, rival: true),
          KeyIdentity.Verdict.impostor)
check("impostor is NOT learned", !identity.known.contains(impostor.uuidString))
checkSame("your device is still ours",
          identity.classify(name: "Amazfit Helio Strap", address: mine.uuidString, rival: true),
          KeyIdentity.Verdict.ours)

section("genuine rotation, nobody else around")
var rotating = KeyIdentity(keyName: "Helio", known: [mine.uuidString])
checkSame("rotated address is adopted",
          rotating.classify(name: "Amazfit Helio Strap", address: rotated.uuidString, rival: false),
          KeyIdentity.Verdict.rotation)
check("...and learned", rotating.known.contains(rotated.uuidString))

section("names that are not the key never match")
checkSame("different device",
          rotating.classify(name: "Govee_H6046_712B", address: UUID().uuidString, rival: false),
          KeyIdentity.Verdict.notKey)
var caseInsensitive = KeyIdentity(keyName: "helio")
checkSame("case and substring",
          caseInsensitive.classify(name: "Amazfit HELIO Strap", address: "x", rival: false),
          KeyIdentity.Verdict.firstAddress)
section("the learned set is capped")
var crowded = KeyIdentity(keyName: "k")
for i in 0..<12 { _ = crowded.classify(name: "k device", address: "addr\(i)", rival: false) }
check("keeps 8", crowded.known.count == KeyIdentity.maxKnown)
check("...the newest", crowded.known.last == "addr11")

// ─────────────────────────────── tracking ───────────────────────────────
//
// The tracker is handed sightings and times, so an entire walk-away — and an
// impostor standing next to you — replays in microseconds.

func sighting(_ name: String, _ address: UUID, _ rssi: Int = -60) -> Sighting {
    Sighting(name: name, address: address, rssi: rssi)
}

section("the key is heard, then goes quiet")
var tracker = Tracker(keyName: "Helio")
var now = Date()
let firstSighting = tracker.sight(sighting("Amazfit Helio Strap", mine), now: now)
check("first sighting teaches an address",
      firstSighting == [.learnedAddress(address: mine.uuidString, first: true),
                        .newChannel(name: "Amazfit Helio Strap", address: mine.uuidString)])
checkNumber("no absence yet", tracker.absent(now: now), 0.0)
now = now.addingTimeInterval(5)
checkNumber("5s of silence", tracker.absent(now: now), 5.0)

section("unrelated devices are ignored")
check("govee ignored", tracker.sight(sighting("Govee_H6046_712B", UUID()), now: now).isEmpty)
checkNumber("...and do not refresh us", tracker.absent(now: now), 5.0)
check("...but stay listed for the picker", tracker.named.count == 2)

section("an impostor does not count as presence")
now = now.addingTimeInterval(1)
check("our device refreshes", tracker.sight(sighting("Amazfit Helio Strap", mine), now: now).isEmpty)
now = now.addingTimeInterval(1)
check("impostor is reported",
      tracker.sight(sighting("Amazfit Helio Strap", impostor), now: now)
        == [.ignoredImpostor(name: "Amazfit Helio Strap", address: impostor.uuidString)])
check("...but not tracked", tracker.channels[impostor] == nil)
checkNumber("...and does not refresh us", tracker.absent(now: now), 1.0)

section("a rotated address is adopted only once the old one has gone quiet")
// The trade-off, stated plainly: a device that legitimately advertises under two
// addresses at once is followed under the first until that one falls silent.
let second = UUID()
now = now.addingTimeInterval(1)
check("new address while ours is live is refused",
      tracker.sight(sighting("Amazfit Helio Strap", second), now: now)
        == [.ignoredImpostor(name: "Amazfit Helio Strap", address: second.uuidString)])
now = now.addingTimeInterval(KeyIdentity.rivalWindow + 1)
_ = tracker.sight(sighting("Amazfit Helio Strap", second), now: now)
check("adopted once it is alone", tracker.channels.count == 2)
checkNumber("newest wins for absence", tracker.absent(now: now), 0.0)

section("channels expire, so a stale one cannot hold the Mac open")
now = now.addingTimeInterval(Tracker.channelLifetime + 1)
tracker.prune(now: now)
checkNumber("channel gone after 10 min", tracker.absent(now: now), nil)

section("changing the key forgets the old device")
var replaced = Tracker(keyName: "Helio", known: [mine.uuidString])
_ = replaced.sight(sighting("Amazfit Helio Strap", mine), now: Date())
replaced.setKey("Buds3")
checkNumber("channels cleared", replaced.absent(now: Date()), nil)
check("addresses cleared", replaced.knownAddresses.isEmpty)
let buds = replaced.sight(sighting("Galaxy Buds3 Pro", UUID()), now: Date())
check("new name matches", buds.contains { if case .newChannel = $0 { return true } else { return false } })

// ───────────────────────────── lock decision ─────────────────────────────
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

section("present, away, never seen")
checkSame("key present -> armed", judge(absent: 2), Judgment(phase: .armed, action: .none))
checkSame("15s of silence -> lock", judge(absent: 15), Judgment(phase: .away, action: .lock))
checkSame("14.9s is not yet", judge(absent: 14.9), Judgment(phase: .armed, action: .none))
checkSame("never seen -> noKey", judge(absent: nil), Judgment(phase: .noKey, action: .none))
checkSame("disabled -> noKey, no action", judge(enabled: false, absent: 60),
          Judgment(phase: .noKey, action: .none))

section("the desk false-lock, and the gate that prevents it")
checkSame("away 40s but typing 3s ago -> hold", judge(absent: 40, idle: 3),
          Judgment(phase: .away, action: .holdActive))
checkSame("away 40s and idle 40s -> lock", judge(absent: 40, idle: 40),
          Judgment(phase: .away, action: .lock))
checkSame("idle exactly at the window -> lock", judge(absent: 20, idle: 15),
          Judgment(phase: .away, action: .lock))
checkSame("activity gate off -> locks anyway", judge(absent: 20, idle: 0, respectActivity: false),
          Judgment(phase: .away, action: .lock))
checkSame("idle unreadable does not block", judge(absent: 20, idle: nil),
          Judgment(phase: .away, action: .lock))

section("a flapping signal cannot lock twice")
checkSame("locked 5s ago -> cooldown", judge(absent: 40, idle: 40, lastLockAt: past(5)),
          Judgment(phase: .away, action: .holdCooldown))
checkSame("locked 25s ago -> lock", judge(absent: 40, idle: 40, lastLockAt: past(25)),
          Judgment(phase: .away, action: .lock))

section("states that resolve the attempt without locking")
checkSame("screen already locked", judge(absent: 40, locked: true),
          Judgment(phase: .lockedOut, action: .alreadyLocked))
checkSame("dry run", judge(absent: 40, dryRun: true),
          Judgment(phase: .lockedOut, action: .dryRun))
checkSame("already locked beats dry run", judge(absent: 40, dryRun: true, locked: true),
          Judgment(phase: .lockedOut, action: .alreadyLocked))
checkSame("cooldown beats already-locked",
          judge(absent: 40, dryRun: true, locked: true, lastLockAt: past(1)),
          Judgment(phase: .away, action: .holdCooldown))

section("locked out waits for a real return")
checkSame("still away -> stays locked out", judge(phase: .lockedOut, absent: 60),
          Judgment(phase: .lockedOut, action: .none))
checkSame("3s of silence -> still locked out", judge(phase: .lockedOut, absent: 3.0),
          Judgment(phase: .lockedOut, action: .none))
checkSame("under 3s -> re-armed", judge(phase: .lockedOut, absent: 2.9),
          Judgment(phase: .armed, action: .none))
checkSame("channel expired while locked -> still locked out, not noKey",
          judge(phase: .lockedOut, absent: nil), Judgment(phase: .lockedOut, action: .none))

section("a window learned for one device is used for that device")
checkSame("per-device window", judge(absent: 13, window: 12), Judgment(phase: .away, action: .lock))

section("manual lock: away gate waived, safety gates kept")
checkSame("key present, asked -> lock", manual(), Judgment(phase: .armed, action: .lock))
checkSame("dry run still protects", manual(dryRun: true), Judgment(phase: .lockedOut, action: .dryRun))
checkSame("already locked is a no-op", manual(locked: true),
          Judgment(phase: .lockedOut, action: .alreadyLocked))
checkSame("disabled does nothing", manual(enabled: false), Judgment(phase: .armed, action: .none))
checkSame("phase left alone for a failed lock", manual(phase: .away),
          Judgment(phase: .away, action: .lock))

// ─────────────────────────────── menu copy ───────────────────────────────
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

section("status lines")
check("permission pending", MenuModel.status(snapshot(bluetooth: .unknown)).title,
      "Waiting for Bluetooth permission")
check("bluetooth off", MenuModel.status(snapshot(bluetooth: .off)).title, "Bluetooth unavailable")
check("disabled wins over everything",
      MenuModel.status(snapshot(enabled: false, bluetooth: .unknown)).title, "Disabled")
check("armed", MenuModel.status(snapshot(phase: .armed)).title, "Armed — key is present")
check("away", MenuModel.status(snapshot(phase: .away)).title, "Key is away…")
check("locked out", MenuModel.status(snapshot(phase: .lockedOut)).detail, "waiting for key to return")
check("no key names it", MenuModel.status(snapshot(phase: .noKey)).detail, "no 'Helio' advertising yet")
check("dry run is labelled", MenuModel.status(snapshot(dryRun: true)).title,
      "DRY RUN · Armed — key is present")

section("device line")
let channel = Channel(name: "Amazfit Helio Strap", lastSeen: Date().addingTimeInterval(-4),
                      lastRSSI: -57, packets: 100)
check("best channel shown", MenuModel.status(snapshot(best: channel, count: 1)).detail,
      "Amazfit Helio Strap · -57 dBm · 4s ago")
check("extras counted", MenuModel.status(snapshot(best: channel, count: 3)).detail,
      "Amazfit Helio Strap · -57 dBm · 4s ago · +2")
check("nothing yet", MenuModel.status(snapshot(best: nil)).detail, "—")

section("away submenu")
func awayItems(_ s: MenuSnapshot) -> [MenuItem] {
    let row = MenuModel.items(s).first { $0.title == "Away for" }
    guard case let .children(items)? = row?.content else { return [] }
    return items
}
let warm = awayItems(snapshot(window: AwayWindow(seconds: 20, source: .warmup)))
check("automatic is checked while learning", warm.first?.checked == true)
check("automatic says learning", warm.first?.title ?? "nil", "Automatic · learning…")
let learnedItems = awayItems(snapshot(window: AwayWindow(seconds: 15.3, source: .learned)))
check("learned window is named", learnedItems.first?.title ?? "nil", "Automatic · learned 15 s")
check("automatic checked when learned", learnedItems.first?.checked == true)
let manualItems = awayItems(snapshot(window: AwayWindow(seconds: 20, source: .manual),
                                     windows: Windows(manual: ["helio": 20])))
check("automatic unchecked when manual", manualItems.first?.checked == false)
check("manual window is checked", manualItems.first { $0.title.hasPrefix("20") }?.checked == true)
check("risky windows are labelled", manualItems.contains { $0.title == "10 seconds · may false-lock" })
check("safe windows are not", manualItems.contains { $0.title == "15 seconds" })

section("key device picker")
let device = NamedDevice(name: "Amazfit Helio Strap", address: mine,
                         firstSeen: Date().addingTimeInterval(-100), lastSeen: Date(),
                         rssi: -57, packets: 100)
let picker = MenuModel.keyDevices([device], keyName: "helio")
check("current key is marked", picker.first?.title.hasPrefix("\u{2713}") == true)
check("rate is shown", picker.first?.title.contains("60/min") == true)
let rare = NamedDevice(name: "Slow Thing", address: UUID(),
                       firstSeen: Date().addingTimeInterval(-120), lastSeen: Date(),
                       rssi: -70, packets: 4)
check("a rare device is warned about",
      MenuModel.keyDevices([rare], keyName: "helio").first?.title.contains("too rare") == true)
check("no devices", MenuModel.keyDevices([], keyName: "helio").first?.title ?? "nil",
      "No named devices visible")

// ──────────────────────────────── summary ────────────────────────────────

print(failures == 0
      ? "\nCORE OK — \(checks) checks"
      : "\n\(failures) FAILURE(S) of \(checks) checks")
exit(failures == 0 ? 0 : 1)