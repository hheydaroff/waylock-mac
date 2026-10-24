# Working on Waylock

A menu bar app that locks a Mac when a Bluetooth key device stops advertising.
`FINDINGS.md` holds the measurements; this file holds the rules that keep the
code honest.

## The three commands

```sh
swift build        # Core, Adapters, tools and probes
swift test         # every decision, no radio, no locking
./build.sh         # runs swift build, then makes the signed build/Waylock.app
```

Run `swift test` after any change to `Core/`. It needs no Bluetooth permission
and cannot lock the screen, so there is no reason not to.

The radio-dependent commands run through SwiftPM too:

```sh
swift run waylock-tools --selftest 60
swift run waylock-scan 150
swift run waylock-watch iPhone 120
```

## Layout

```
Core/       pure decisions        -> target WaylockCore
Adapters/   what talks to macOS   -> target WaylockAdapters
Tools/      radio-dependent CLI   -> target waylock-tools
Tools/Probes/                     -> targets waylock-scan, waylock-watch
Tests/      swift-testing         -> target CoreTests
App/        menu bar bundle only  -> not a SwiftPM target; build.sh compiles it
```

`App/` is the one directory SwiftPM does not build. An `.app` needs an
`Info.plist` and a signature, and `build.sh` supplies both. It compiles
`Core/`, `Adapters/` and `App/` together as one module, which is why none of them
needs `public`. Under SwiftPM the other modules reach Core and Adapters with
`@testable import`, guarded by `#if canImport(WaylockCore)` so the same file also
compiles in the single-module app build.

## Layering

`Core/` may import Foundation and nothing else. No AppKit, no CoreBluetooth, no
`IOKit`, no `UserDefaults`, no `Date()` for "now" — time is a parameter. If a
decision needs something from the machine, the value is passed in.

`Adapters/` and `App/` are the only places that talk to macOS, and each file is
narrow:

| file | the one thing it knows |
|---|---|
| `Adapters/Radio.swift` | CoreBluetooth, and its queue |
| `Adapters/SettingsStore.swift` | UserDefaults, and the domain name |
| `Adapters/Log.swift` | the log file, and how an event is worded |
| `App/Locker.swift` | the private lock call and its verification |
| `App/main.swift` | wiring, and the menu |

`Adapters/` links CoreBluetooth and nothing else. IOKit belongs to `Locker`,
which stays in `App/` so the tools cannot lock a screen by accident.

`Tools/` and `Tests/` link Core; the tools also link the adapters. Tests link
only Core.

## Things that have broken here before

- **Every lock entry point goes through one decision.** `LockDecision.judge` for
  automatic, `judgeManual` for the menu item. A new lock path must call one of
  them, never `Locker.lock()` directly. A "Lock Now (test)" action once bypassed
  the dry-run guard and locked the screen for real.
- **Name matching alone fails open.** A colleague with the same model keeps the
  Mac unlocked after you leave. Identity is name *plus* a learned address set, and
  an unknown same-named address is adopted only when no other same-named device
  was seen in the last 10 s.
- **Failures are silent by default.** CoreBluetooth that never reaches
  `poweredOn` looks identical to "the key is not here". Log state, log every
  decision input, and prefer a loud wrong answer to a quiet plausible one.
- **`.standard` is bundle-relative.** A bare executable reads the global domain.
  Name the domain explicitly (see `SettingsStore.domain`).
- **CoreBluetooth blocks its caller while a permission decision is pending.** It
  lives on its own queue; never create it on the main thread.

## Verifying on the hardware

The lock itself only proves itself live: `open build/Waylock.app`, walk away with
the key device, and read `~/Library/Logs/Waylock.log`. Check `enabled=1` in the
heartbeat first — a disabled app scans, reports present, and never locks.
Every ad-hoc rebuild invalidates the Bluetooth grant, so approve the prompt once
from an unlocked screen.

`./build.sh` replaces `build/Waylock.app`. Quit a running copy first; the new
bundle is a different signature and asks for Bluetooth again.

## Style

One idea per file, named in the domain's words (`AwayWindow`, `Arrivals`,
`LockDecision`) rather than the framework's. Comments explain why, and record the
measurement behind a constant. Tests are sentences (`@Test("a 45 second
walk-away gap is an absence, not device behaviour")`), grouped one `@Suite` per Core module, and every
`#expect` carries a message that says what it got. `FINDINGS.md` is a lab
notebook: add the dead ends, not only the answers.
