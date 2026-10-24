# Findings

Empirical record behind Waylock. Everything here was measured on the machine
below on 2026-10-19, not assumed. Numbers are kept even where they were
superseded, because how a figure was arrived at (and why it was wrong) is the
part that transfers to the next device.

README.md is how to *use* this. This file is why it is built the way it is.

## Environment

| | |
|---|---|
| OS | macOS 27.0.1 (build 26A434), arm64 |
| Hardware | Apple M4 Max, Bluetooth controller `BCM_4388C2` |
| Toolchain | Apple Swift 6.4, `swiftc -O`, hand-built `.app` bundle, ad-hoc signed |
| SIP | enabled |
| Notes | no `timeout(1)` (coreutils absent) — timed runs use background + `kill -INT` |

Devices involved, all identified from `system_profiler SPBluetoothDataType`:

| Device | Address | Role |
|---|---|---|
| Galaxy Buds3 Pro "de <owner>" | `34:E3:FB:xx:xx:xx` | first key device |
| Amazfit Helio Strap | LE `1A2B3C41-…` | current key device |
| Govee strips x2, Samsung AU6979 TV | — | named neighbours, used as negative controls |
| CMF Buds Pro 2, HUAWEI FreeBuds SE | — | neighbours' earbuds, matched by name-adjacent strings |
| iPhone / Apple Watch | rotating | never identifiable (see below) |

## Dead ends

Each of these was expected to work and does not. All were checked on this
machine; the version matters, several changed recently.

### `IOBluetoothDevice.rawRSSI()` — always 0

Paired devices list fine (`pairedDevices()`), but `rawRSSI()` returns `0` for a
genuinely connected device. Verified with a fresh `IOBluetoothDevice(addressString:)`
lookup after `system_profiler` confirmed the buds connected with
`HFP AVRCP A2DP ACL` services: `isConnected=true`, `rawRSSI=0`.

Two traps found on the way: `pairedDevices()` returns *stale* objects reporting
`isConnected=false` (needs a fresh address lookup), and `openConnection` does not
change the state. `recentDevices` returned 0 entries.

Consequence: the classic-Bluetooth RSSI path is unusable here. It gave a binary
connected/disconnected signal at best, and a classic link drop also happens when
audio switches to the phone (multipoint), so it would false-lock at the desk.

### `system_profiler SPBluetoothDataType -json` — RSSI only while connected

Plain-text output does show `RSSI: -33` — but **only for a device with an active
connection**. Under `device_not_connected` there is no RSSI field at all. So a
phone that is not connected to the Mac is invisible to this path, which rules
out the approach `perrosenlind/proximity-lock` takes.

### `CGSession -suspend` — gone

Not present at the expected path on macOS 27. The long-standing shell trick for
locking is dead; it was also reported gone on macOS 26.

### RSSI as a distance proxy — unusable for earbuds

| Measurement | Result |
|---|---|
| Stationary beacon, 60 s, 74 samples | mean −75.8 dBm, sd **1.6 dB**, range −80…−71 (9 dB) |
| Buds3 Pro at desk, 22 s | −88…−52 dBm (**36 dB**) |
| Buds3 Pro returning from a walk | −89 dBm at the moment of re-entry |

The stationary figure is tight, and tempting. But a wearable's RSSI swings by
tens of dB as your head and body block 2.4 GHz, and the walk-away *return*
transient reaches −89 dBm — below any threshold that would fire at 5 m. A
threshold near −85 dBm would have locked the Mac during normal wear.

Literature agrees (body/wall attenuation, multipath, ±8–10 dB jitter,
accuracy collapsing past ~4–5 m), but the local numbers are the decisive part:
at-desk RSSI overlaps the departure RSSI, so no threshold separates them.

### Phones and watches — visible, but anonymous

150 s scan, `AllowDuplicates`, every advertiser recorded:

| | |
|---|---|
| Devices named, ever | 5 (2 Govee strips, Samsung TV, Amazfit strap, buds' LE channel) |
| Apple beacons (company `0x004C`) | **116 snapshots-worth, every one nameless** |
| Distinct Apple addresses in 150 s | 7+ |
| Payload change on screen lock | `0x1006…` (Nearby Info) → `0x1202…` (Find My) |

So the iPhone and Watch *are* there — as anonymous Continuity / Find My
payloads with rotating Resolvable Private Addresses. There is no name to match
and nothing distinguishing the user's S25 from a neighbour's iPhone. Name+ID
matching, which works for earbuds, has no handle here.

Resolving an RPA needs the IRK from bonding. Untested follow-up: bond the phone
to the Mac and check whether CoreBluetooth then hands back a stable identifier.

## What works

**BLE advertisement RSSI, used as pure presence.** `scanForPeripherals` with
`AllowDuplicates: true` delivers continuous packets. RSSI is logged and shown
but never thresholds on.

**Identity by advertised name.** The buds announced `Buds3 Pro`,
`Buds3 Pro de <owner>` and `Galaxy Buds3 Pro (XXXX) LE`; matching the substring
`buds3` covered all of them and excluded the neighbours' `CMF Buds Pro 2` and
`HUAWEI FreeBuds SE`.

**Absence of *all* channels, not of one.** This is the core insight, and it came
from a measurement that killed the obvious design:

| 189 s at desk, per channel | |
|---|---|
| gaps > 10 s, each channel | **5** |
| p99 inter-arrival gap | 30.6 s |
| max gap | 31.6 s |

A per-channel silence detector would have locked the Mac ~5 times in 3 minutes
while the user sat still. But the channels are independent, so the *union* of
arrival times almost never gaps — and when the device leaves, all of them stop
at once. Hence: present if *any* key channel was heard recently.

## Threshold selection

The window is the only real tuning parameter, and it was set from the
distribution of the union gap, not from intuition.

| Run | median | p90 | p95 | p99 | max | 10 s window | 15 s window |
|---|---|---|---|---|---|---|---|
| 180 s | 1.1 s | 3.7 s | — | 9.2 s | 10.2 s | **1 false lock** (t=171) | — |
| 600 s (full baseline) | 1.0 s | 3.3 s | 4.5 s | 7.6 s | 10.2 s | **1 false lock** (t=145) | **0 in 600 samples** |
| Amazfit, ~30 s at desk | — | — | — | — | 2.6 s | — | — |

**10 s is measurably wrong** — it locked a seated user twice across two runs.
15 s sits 47 % above the observed 10.2 s worst case, which is why it is the
default. The menu still offers 8 s and 10 s, labelled `may false-lock`.

A correction worth recording: an earlier "longest all-absent run at desk = 0 s"
figure was **tautological** — it defined presence using the same window it was
testing, so it could never show a false-lock risk. The union-gap distribution
replaced it.

Lock latency after leaving is the window itself, plus up to one 0.5 s tick.
When the user really leaves, the key is gone for good, so a larger window costs
seconds once, whereas a too-small one costs a locked screen while working.
The asymmetry favours the larger window.

## Advertising rate

| Condition | Rate |
|---|---|
| Buds3 Pro, idle | ~0.6–0.9 Hz per channel |
| Buds3 Pro, audio playing | **~0.47 Hz** — roughly halves |
| Amazfit Helio Strap | ~0.67 Hz, steady (at-desk absence 2.3–2.6 s) |
| Earlier 12 s scan | too short to judge anything — 1–3 packets per device |

A 12 s window produces packet counts that look like instability but are just a
small sample. Nothing below ~60 s is worth reasoning about.

## Calibrating a new device

The window is device-specific, because advertising rate is. Measured rates span
a factor of five, so the window is derived from the union-gap distribution
instead of chosen:

| Device | Rate | Worst at-desk gap | Derived window |
|---|---|---|---|
| Amazfit Helio Strap | 0.67 Hz | 6.6 s | **12 s** (floor) |
| Buds3 Pro | 0.6-0.9 Hz | 10.2 s | **15.3 s** |
| A 0.09 Hz stream | 0.09 Hz | >11 s | unusable - flagged in the picker |

Rules, and why each exists:

- **Warm up slack at 20 s.** The first three minutes on an unfamiliar device
  accept a later lock. A false lock costs a locked screen mid-work; a late lock
  costs seconds.
- **`worst gap x 1.5`**, clamped to 12-60 s. The 1.5 factor is the headroom the
  buds baseline validated by hand before any of this was automated.
- **Discard gaps beyond 10x the median** as absences. A raw gap list cannot tell
  a slow advertiser from a coffee break, and learning a 45 s "normal" gap from
  one meeting would leave the Mac unlocked for 45 s forever after.
- **The cutoff floor is 1.25x the minimum window, not an absolute number of
  seconds.** An 8 s floor discarded a chatty device's honest 8.2 s gap and
  produced a window (12 s) barely above the gap it had to cover. Found by a
  smoke run of `--calibrate`, not by a failing test — which is why that exact
  distribution is now a test case.
- **Manual always wins**, and "Automatic" clears the override, so a device whose
  firmware changes can be re-measured rather than argued with.

`--policy-test` covers the derivation (14 checks). `--calibrate <min> [--apply]`
measures in the field. Both are headless and need no radio or permission.

## Identity over time, and impostors

The buds' address is not stable, which is why name matching was adopted:

- `1A2B3C42` (`Buds3 Pro`) — stable across ~24 min of monitoring, 121 pkts/150 s
- `1A2B3C43` → `1A2B3C44` → `1A2B3C45` (`Buds3 Pro de <owner>`) — **rotated**
  while `1A2B3C42` persisted, so a device can present several addresses at once
- OUI `34:E3:FB` is Samsung's; a static public address would explain the
  stability, making rotation a tendency rather than a certainty
- An earlier pin of `E96AC176` (0.09 Hz) was simply the wrong stream — the same
  physical device was also advertising at 0.77 Hz under another address

UUID pinning therefore cannot be the identity mechanism. But name matching alone
has a hole the user asked about directly:

> what if someone else with the same Amazfit Helio Strap name is also around?

It **fails open**: their strap is another matching channel, the union never goes
absent, and the Mac stays unlocked while the owner walks away. For a lock app
that is the worst failure direction, and it is silent.

Fix: learn the *address set* of the chosen device, persisted, and accept a name
match only when the address is known **or** no other same-named device is in
range — the latter being the signature of a genuine rotation. An impostor always
appears alongside the real device, so it is never learned. Bounded at 8
addresses; a rival within 10 s of the candidate blocks adoption.

## Lock mechanism

No public API exists for forcing a screen lock; Apple DTS confirms this.

| Mechanism | Status on macOS 27 |
|---|---|
| `CGSession -suspend` | absent |
| `SACLockScreenImmediate` (private, `login.framework`) | resolves via `dlopen`/`dlsym`, **works**, locks with no prompt |
| `SACUnlockScreenImmediate` | absent — 274 exported symbols, none containing "unlock" |
| `pmset displaysleepnow` | locks only if "require password immediately" is set |
| System Events ⌘⌃Q | works, needs Accessibility + Automation consent, layout-dependent |

Choosing the private symbol costs App Store eligibility, which is fine for a
personal build and is documented as such. The critical detail is that the call
**reports success even when nothing happens**, so every lock is confirmed by
reading `CGSSessionScreenIsLocked` back (`lock: confirmed (rc=0)`).

Unlock is out of scope: with no unlock API it would mean injecting the login
password, which needs Accessibility permission and stores a credential.

## Gates

- **HID idle ≥ window.** Without it, the app locks mid-sentence. Making the gate
  wait the *full* window rather than a few seconds adds no latency, because the
  idle timer starts when the signal dies.
- **20 s cooldown** after a lock, so a flapping key cannot lock repeatedly.
- **Re-arm only below 3 s absence**, and only in `lockedOut`.
- **Warm-up fail-open:** launched while the key is away, the app sits at `noKey`
  and never locks until the key is seen once. Deliberate — the alternative is
  locking the instant it launches.

## Methodology notes

These cost real time; they are the reusable part.

1. **Log every input the decision uses.** The first live failure produced a log
   with *nothing* after channel detection — indistinguishable from a dozen
   causes. A 10 s heartbeat (absence, phase, channels, HID idle, locked, enabled,
   window) turned the next investigation into one glance.
2. **A test that can corrupt what it tests is worse than no test.** `exit()`
   skips `defer` in Swift, so an identity test's save/restore never ran and it
   wrote fake UUIDs into the user's real preferences. Tests now run in a
   sandboxed `UserDefaults` suite.
3. **Separate decisions from radios.** `ingest(name:id:rssi:)` holds the whole
   decision; `--identity-test` drives it directly, staging an impostor that
   cannot be staged with real hardware. 9 checks, no permissions required.
4. **Fix the parser before trusting the verdict.** A CSV writer that sorted the
   header by packet count while writing rows in discovery order shifted columns
   and produced a confident wrong conclusion from a 35 s capture.
5. **Ten minutes of baseline beats three of them.** The 180 s run missed the
   10.2 s tail that the 600 s run found, and that tail is what decides the window.

### `UserDefaults.standard` is bundle-relative, so a bare executable reads the wrong domain

`.standard` means "the current bundle's domain". Inside `Waylock.app` that is
`io.github.hheydaroff.waylock`. A binary at `build/waylock-tools` has **no** bundle
identifier, so `.standard` is the *global* domain: every key looks absent and the
code falls back to its hardcoded defaults. That is not a read-only mistake — the
first `save()` writes the fallbacks into the global domain.

It surfaced as a selftest reporting the key device as `buds3`, the source
default, while `defaults read io.github.hheydaroff.waylock` said `Amazfit Helio Strap`.
The old single binary never hit it because it lived inside the .app and resolved
the bundle even when invoked directly.

Fix: name the domain explicitly.

```swift
init(_ defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? UserDefaults(suiteName: "io.github.hheydaroff.waylock") ?? .standard
}
```

A test can still inject a sandbox suite, which is how the identity checks stay
off the real prefs.

### CoreBluetooth's initialiser blocks the thread it is called on

`CBCentralManager(delegate:queue: nil)` runs on the main queue. When macOS is
waiting for a Bluetooth permission decision, that initialiser blocks — so the
main run loop never starts, the stall watchdog never fires, and the process
produces **no output at all**. An 8-second selftest hung for 38 minutes this way,
and every diagnostic that would have explained it was downstream of the block.

Two fixes, both needed:

- Create the manager on its own serial queue and hop callbacks to main. A
  permission decision can then take as long as it likes without freezing the app
  that is supposed to explain what is happening.
- Never let a tool run unbounded. The CLI tools exit non-zero after 20 s with no
  radio state, and print the reason; the menu bar app cannot exit, so it logs and
  retries instead.

`setvbuf(stdout, nil, _IONBF, 0)` in the tools as well: buffered output means a
hang leaves no trace, which is exactly when a trace is worth most.

### Rounding up on a measurement amplifies its noise

`(raw * 10).rounded(.up) / 10` turned a 15.3 s window into 15.4 s, because the
gaps come from `Date` subtraction, where 10.2 s is stored as 10.2000001 and
multiplied by 1.5 lands just above 15.3. The `1.5x` headroom is the safety
margin; the last decimal place is presentation. Round to nearest instead — and
the test that caught it was comparing a derived window to a hand-computed one.

## Permissions are keyed to the code signature

The app is ad-hoc signed, and `build.sh` signs on every build, so the cdhash
changes with every edit. macOS matches the Bluetooth grant against that hash, so
after each rebuild the app is treated as a new app:

```
tccd: Failed to match existing code requirement for io.github.hheydaroff.waylock
      service kTCCServiceBluetoothAlways   cdhash 6f8fa67b… vs a4f5597d…
tccd: AUTHREQ_PROMPTING
```

With the screen locked the prompt cannot be shown, and the failure is invisible:
`CBCentralManager` stays at state 0 (`unknown`), never calls its delegate, and
the app runs forever without scanning. Only a `log show` on `com.apple.TCC`
explains it. This is almost certainly what the earlier unexplained "28 s startup
delay, possibly Bluetooth re-init" was.

Two habits came out of it:

- **Log the radio state, and never let silence mean "fine".** A watchdog now
  recreates the central every 15 s and says why, and the menu distinguishes
  "waiting for permission" from "Bluetooth unavailable".
- **The CLI modes inherit the terminal's grant** and keep working across
  rebuilds, so detection logic stays testable while the bundle is blocked.

## Reproduce

```bash
./build.sh                                   # swiftc -O -> build/Waylock.app
./build/Waylock.app/Contents/MacOS/Waylock --identity-test    # identity logic, sandboxed
./build/Waylock.app/Contents/MacOS/Waylock --selftest 180     # presence + union gap, no lock
WAYLOCK_DRYRUN=1 open build/Waylock.app      # full app, logs WOULD LOCK instead of locking
open build/Waylock.app                       # live
tail -f ~/Library/Logs/Waylock.log
```

`--selftest` prints the union-absence series and a `TRIGGERED`/`no trigger`
verdict — that is the tool used to choose the window, and the one to re-run
against any new key device.

## Open questions

- Strap behaviour off the wrist / on the charger — untested. If it stops
  advertising there, it fails open whenever it is not being worn.
- Whether the buds' rate drop during playback holds over hours, or was an
  artefact of a 28 s sample.
- RPA resolution after bonding a phone — untested; the only plausible route to a
  phone as key device without a companion app.
- Multiple keys (watch + earbuds, present if *either* is) — the all-absent
  structure already supports it; no menu for it yet.
- Auto-unlock — blocked on the missing unlock API.