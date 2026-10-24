# Waylock

Locks your Mac when your Bluetooth earbuds move out of range.

Built because "lock your screen when you walk away" is still not something macOS
does, and every RSSI-proximity app out there assumes an iPhone or a fixed RSSI
threshold. This one keys on **absence**, not signal strength — because on
earbuds, signal strength does not work.

Tested against a Galaxy Buds3 Pro and an Amazfit Helio Strap on macOS 27.0.1
(M4 Max).

Every decision here was driven by a measurement, including several that
contradicted the obvious design. The dead APIs, RSSI numbers, threshold
baselines and identity findings are recorded in **[FINDINGS.md](FINDINGS.md)** —
read that before changing the window, the matcher, or the lock path.

## Verified end to end

Real walk-away, live mode, Galaxy Buds3 Pro in ears (`~/Library/Logs/Waylock.log`,
local time):

```
17:17:11  hb absent=11.0s phase=armed ch=3 idle=43s locked=0   <- counting up
17:17:15  AWAY 15s -> locking
17:17:15  lock: confirmed (rc=0)                              <- verified, not assumed
17:17:22  hb absent=21.5s phase=lockedOut locked=1
17:17:22  re-armed: key back                                  <- Touch ID, buds back
17:17:32  hb absent=0.4s phase=armed locked=0
```

`hb` lines are a 10 s heartbeat recording every input the decision uses
(`absent`, `phase`, channel count, HID idle, locked, enabled, window). They
exist because the first live failure produced a log with *nothing* in it,
which is indistinguishable from a dozen different causes.

If it ever seems not to work, read the heartbeat first: `absent` climbing past
`window` with `locked=0` is a lock-API problem; `absent` staying near zero means
the key device is still in range — i.e. it never left with you.

### Verified on the Amazfit Helio Strap

```
17:57:45  hb absent=2.3s  phase=armed      idle=33s
17:57:55  hb absent=12.3s phase=armed      idle=43s   <- walking away
17:57:58  AWAY 15s -> locking
17:57:59  lock: confirmed (rc=0)
17:58:06  hb absent=22.8s phase=lockedOut  locked=1
17:58:12  re-armed: key back
17:58:26  hb absent=1.2s  phase=armed      locked=0
```

At-desk absence stayed at 2.3-2.6 s over the preceding 30 s, so the strap is
steadier than the buds and has more headroom against the window.

Two failure modes this key shares with any wearable, both worth knowing:

- **Key left behind** (strap on the desk, buds in the case) -> the Mac stays
  unlocked, because the key really is present. Fail-open.
- **Key battery dies** -> the Mac locks on you mid-sentence. Fail-closed, so it
  is safe, just annoying. This is why the activity gate exists.

## Adding a new key device

Two things must be true of a device, and the app checks both.

**1. It advertises a name.** Menu -> Key Device lists every named advertiser with
live RSSI and measured rate, e.g. `Amazfit Helio Strap  -57 dBm  40/min`.
Anything under ~12/min is flagged `! too rare` — a device heard every 11 s cannot
support a usable window, and the menu is a better place to learn that than a
walk-away test.

**2. Its window gets measured, not guessed.** Advertising rate differs by up to
5x between devices, so the away window is learned per device:

| Stage | Window | Why |
|---|---|---|
| First 3 min on a new device | 20 s (warm-up) | slack on purpose: slow to lock costs seconds, fast costs a locked screen |
| After ~3 min and 20+ gaps | learned | `worst gap x 1.5`, clamped to 12-60 s |
| You pick one by hand | yours | always wins; "Automatic" in the menu goes back to measurement |

An absence and a slowly-advertising device look identical in a raw gap list, so
gaps beyond 10x the median are discarded as absences rather than learned as
behaviour — a 45 s trip to a meeting must not teach the app that 45 s is normal.

Measured so far: strap -> **12 s** (floor), Buds3 Pro -> **15.3 s** from a 10.2 s
worst case. Those match the values that were hand-tuned before any of this was
automated, which is the point.

```sh
# measure a device and see the distribution (no --apply = read only)
./build/waylock-tools --calibrate 10
./build/waylock-tools --calibrate 10 --apply
```

## Choosing your own key device

Menu -> **Key Device** lists every advertiser that announces a name, with its
current RSSI, ticked against the one in use. Picking one clears the learned
address set, because those addresses belong to the previous device.

Matching is a case-insensitive substring of the advertised name, so `buds3`
covers both `Buds3 Pro` and `Buds3 Pro de <owner>`, and address rotation (three
different addresses seen for the same buds) needs no special handling.

**Phones and watches advertise no name, so they cannot be picked.** A 150 s scan
found 116 Apple beacons, every one nameless, across 7+ rotating addresses — the
iPhone and Watch appear only as anonymous Continuity / Find My payloads, with
nothing to distinguish yours from a neighbour's. Devices that name themselves
and advertise continuously (earbuds, a fitness band) are the workable keys.

## When someone else owns the same model

Name matching alone fails open: a colleague's `Amazfit Helio Strap` is another
matching channel, the union never goes absent, and the Mac stays unlocked while
you walk away. So the app learns the *address set* of the device you picked and
accepts a name match only when

- the address is one it has learned, or
- no other same-named device is in range — the signature of a genuine rotation.

An impostor always shows up alongside yours, so it never gets learned. This is
verified deterministically in `./build/waylock-tests` — no radio, and no
impostor hardware needed.

## What the measurements say

Everything below was measured on the actual machine, not assumed.

| Question | Answer |
|---|---|
| Does CoreBluetooth report RSSI? | Yes, ~0.4 Hz for the buds' main stream |
| Does `IOBluetoothDevice.rawRSSI()` work? | **No** — returns 0 on this hardware |
| Does `system_profiler` give RSSI? | Only for a *connected* device; useless here |
| Is `CGSession -suspend` still available? | **No** — removed on modern macOS |
| Does `SACLockScreenImmediate` work? | Yes, resolves from `login.framework` |
| Do the buds rotate their BLE address? | **No** — static public address, no rotation in 8 min |
| Can RSSI distinguish 5 m from 0 m? | **No** — too noisy on earbuds (see below) |

### Why RSSI thresholds fail here

Sitting still at the desk, the buds' RSSI wandered between −70 and −83 dBm,
and on re-entry it read −89 dBm while the wearer was back at the desk. Your own
head blocks 2.4 GHz. Any fixed threshold that fires at −85 either fires while
you are sitting still, or only fires after you are already out of the building.

Reference point: a *stationary, non-worn* BLE device on the same Mac measured
−75.8 dBm ± 1.6 dB over 60 s. Earbuds are an order of magnitude noisier than
that because the antenna is against your skull.

### Why single-channel presence fails

The buds advertise **three** independent streams:

| Channel | Rate | At desk | When away |
|---|---|---|---|
| `Buds3 Pro` | 0.40 Hz | −77…−83 | silent |
| `Buds3 Pro de <owner>` | 0.17 Hz | −70…−78 | silent |
| `Galaxy Buds3 Pro (XXXX) LE` | 0.11 Hz | −53…−60 | silent |

Individually they go quiet for **up to 31 s** while you sit at the desk — a
single-channel detector falsely locked 5 times in 3 minutes. But they almost
never go quiet *together*. So the rule is **all channels absent**, which is
also rotation-proof and survives the buds being briefly occluded.

Gate on the union, not on any one stream.

### The one open tuning number

The union gap at the desk is the false-lock risk, and it is the only number
that decides the default. Measured over a 10-minute at-desk baseline
(600 samples):

| Window | False locks |
|---|---|
| 10 s | 1 — fired at t=145 s while sitting at the desk |
| 15 s | 0 |

Gap distribution: median 1.0 s, p90 3.3 s, p95 4.5 s, p99 7.6 s, **max 10.2 s**.
Default is 15 s, i.e. 47% above the observed worst case rather than below it.
Walk-away silence is unbounded once you actually leave, so a wider window only
costs a few seconds of latency, never a missed lock. Raise it to 20–30 s if you
still see false locks; every hold and every trigger is logged.

Two things make this number worse in practice: audio playback roughly halves
the packet rate (0.9 Hz -> 0.47 Hz), and the buds change BLE address
periodically (two distinct addresses for the same buds were observed). Both are
handled — the lower rate is absorbed by the window, and the address change by
matching on name instead of UUID.

## How the code is organised

Four directories, one rule: **Core never imports AppKit or CoreBluetooth.**

| | |
|---|---|
| `Core/` | the decisions: settings, window derivation, identity, tracking, the lock decision, menu copy |
| `App/` | the adapters: CoreBluetooth, the lock API, UserDefaults, AppKit menu, wiring |
| `Tools/` | the two commands that need a real radio (`--selftest`, `--calibrate`) |
| `Tests/` | assertions against Core only — no radio, no permission prompt, no locking |

Because the decision logic is a set of values rather than a menu bar app, a
walk-away, a colleague's identical strap and a false lock at the desk all replay
in milliseconds under `build/waylock-tests`. The parts that cannot be tested that
way are the parts that talk to macOS, and those are kept as thin as possible.

## Build

```sh
./build.sh                  # builds and signs all three
./build/waylock-tests       # -> CORE OK — 97 checks
open build/Waylock.app
```

No Xcode project. `swiftc` plus a hand-assembled bundle, ad-hoc signed (TCC
keys Bluetooth permission to the bundle identity, so signing is required).

The private lock API rules out the App Store and notarisation. This is a
personal build.

First launch asks for Bluetooth permission. Deny it and the menu reads
"Bluetooth unavailable".

## Use

Menu bar icon:

| Icon | Meaning |
|---|---|
| `lock.open` | armed, buds present |
| `lock.rotation` | buds gone, counting down |
| `lock.fill` | locked |
| `lock.slash` | disabled or waiting for the buds |

Menu has the away window (8/10/15/20/30 s), a "don't lock while I'm typing"
toggle, Start at Login, and Lock Now for testing.

Log: `~/Library/Logs/Waylock.log` (local time)

`Start at Login` needs the app in a stable location — copy it to
`/Applications` first, or `SMAppService` will refuse to register it.

## Bluetooth permission survives nothing

The app is ad-hoc signed by `build.sh`, and **every build changes the signature**.
macOS keys the Bluetooth grant to that signature, so the next launch is a
stranger: it asks again, and the old grant no longer matches. The evidence is in
the system log, not in the app:

```
tccd: Failed to match existing code requirement for io.github.hheydaroff.waylock
      service kTCCServiceBluetoothAlways
      cdhash H"6f8fa67b…"   <- the grant that exists
      cdhash H"a4f5597d…"   <- this build
tccd: AUTHREQ_PROMPTING
```

While the screen is locked the prompt cannot appear, and CoreBluetooth simply
never reports a state — which is why the menu says **"Waiting for Bluetooth
permission"** rather than claiming all is well. Unlock, approve, done.

Two consequences worth knowing:

- **The CLI runs are unaffected.** `build/waylock-tests` needs no Bluetooth at
  all, and `build/waylock-tools` inherits the terminal's grant, so detection can
  be tested immediately after a rebuild — the app bundle may be waiting for
  permission while the same logic runs fine from a shell.
- **You can stop the prompts** by signing with a stable identity instead of
  ad-hoc. One-time, and it needs a Keychain approval:

```sh
openssl req -x509 -newkey rsa:2048 -keyout /tmp/wl.key -out /tmp/wl.crt \
  -days 3650 -nodes -subj "/CN=Waylock Dev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -out /tmp/wl.p12 -inkey /tmp/wl.key -in /tmp/wl.crt -passout pass:
security import /tmp/wl.p12 -k ~/Library/Keychains/login.keychain-db -P "" -T /usr/bin/codesign
# then in build.sh: codesign -s "Waylock Dev" --force --identifier io.github.hheydaroff.waylock "$APP"
```

## Design notes

- **Never lock mid-keystroke.** The lock requires `HIDIdleTime` to have reached
  the whole window, not a token few seconds. While you type or move the mouse it
  cannot lock at all — and it costs no latency, because the idle timer starts
  when the key signal dies, not when the decision is made.
- **Verify the lock.** `SACLockScreenImmediate` returns success even when
  nothing happened. After calling it the app polls `CGSSessionScreenIsLocked`
  for 3 s and logs the truth.
- **Re-arm only on sustained presence.** After a lock it requires 3 s of
  continuous presence before arming again, so a single stray packet does not
  re-arm it while you are still away.
- **Identity is name + a learned address set**, never a pinned UUID. The name
  survives rotation (`"Buds3 Pro"` matched three different addresses for the
  same device); the address set is what stops a colleague's identical model from
  counting as present. A rotated address is adopted only when no other
  same-named device is in range — the signature of rotation rather than an
  impostor.

## Testing without locking yourself out

```sh
# every decision, no radio, no permission prompt, no locking
./build/waylock-tests

# the detection path against the real radio, terminal output only
./build/waylock-tools --selftest 60

# existing behaviour, end to end but never touching the screen
open build/Waylock.app --env WAYLOCK_DRYRUN=1
```

`-a` takes an app *name*, not a path, so `open -a build/Waylock.app` fails.

The test binary covers windows, identity, tracking, the lock decision and the
menu copy. The tools cover what only the radio can answer.

## Known limits

- The key must be on and advertising. In the case, on the charger, powered off,
  or paired to another device first, there is no signal — the Mac locks. That is
  fail-safe, and also means opening the case at your desk re-arms it.
- **Bonded iPhones advertise continuously but may be replayed from the macOS
  cache**, which would make absence-based detection impossible for them. Under
  investigation; see FINDINGS.md.
- A colleague with the *same model* is handled by the learned address set, but
  a device that rotates its address at the exact moment both of you are out of
  range could still confuse it. Not defended against; not worth it at a desk.
- **Warm-up fail-open:** if the app launches while the key is out of range it
  has never seen one, so it sits at `noKey` and will not lock until the key is
  seen once. Deliberate — the alternative is locking the instant you launch it.
- **The first 3 minutes on a new device lock late** (20 s warm-up) while the
  window is measured. Also deliberate, for the same reason.
- No auto-unlock. `login.framework` exports no unlock symbol; unlocking means
  injecting your password via Accessibility, which is not worth the attack
  surface. Touch ID stays the unlock path.