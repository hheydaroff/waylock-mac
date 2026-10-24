# Working on Waylock

A menu bar app that locks a Mac when a Bluetooth key device stops advertising.
`FINDINGS.md` holds the measurements; this file holds the rules that keep the
code honest.

## The three commands

```sh
./build.sh                  # core tests + tools + signed app
./build/waylock-tests       # every decision, no radio, no locking
./build/waylock-tools --selftest 60
```

Run `./build/waylock-tests` after any change to `Core/`. It needs no Bluetooth
permission and cannot lock the screen, so there is no reason not to.

## Layering

`Core/` may import Foundation and nothing else. No AppKit, no CoreBluetooth, no
`IOKit`, no `UserDefaults`, no `Date()` for "now" — time is a parameter. If a
decision needs something from the machine, the value is passed in.

`App/` is the only place that talks to macOS, and each adapter is narrow:

| file | the one thing it knows |
|---|---|
| `Radio.swift` | CoreBluetooth, and its queue |
| `Locker.swift` | the private lock call and its verification |
| `SettingsStore.swift` | UserDefaults, and the domain name |
| `main.swift` | wiring, and the menu |

`Tools/` and `Tests/` link Core; the tools also link the radio.

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

## Style

One idea per file, named in the domain's words (`AwayWindow`, `Arrivals`,
`LockDecision`) rather than the framework's. Comments explain why, and record the
measurement behind a constant. Tests print what they got, not just that they
failed. `FINDINGS.md` is a lab notebook: add the dead ends, not only the answers.