# Contributing

Waylock is a small macOS menu bar app. Read [README.md](README.md) for what it
does, [CONTEXT.md](CONTEXT.md) for the words the code uses, and
[FINDINGS.md](FINDINGS.md) for the measurements behind it. Read FINDINGS.md
before you change the away window, the matcher or the lock path. Several
obvious designs were tried there and failed.

## The three commands

```sh
swift build     # compile everything
swift test      # every decision, no radio, no locking
./build.sh      # core tests, tools, and the signed app bundle
```

`swift test` and the Core tests need no Bluetooth permission and cannot lock
the screen. Run them after any change to Core.

`./build.sh` signs the app ad-hoc, so each build asks for Bluetooth permission
again. Approve the prompt once from an unlocked screen. See
[SECURITY.md](SECURITY.md) and
[ADR 0004](docs/adr/0004-adhoc-signing-and-tcc.md).

## Layering

The layers are strict. A change that crosses one is a design change, not a
detail.

| Layer | May import | Holds |
|---|---|---|
| Core | Foundation only | decisions: windows, identity, tracking, the lock decision, menu copy |
| Adapters | Core, CoreBluetooth, Foundation | CoreBluetooth and UserDefaults, each behind one narrow interface |
| App bundle | everything above, AppKit, IOKit | the menu, the wiring, and the lock call |

Rules for Core:

- It imports Foundation and nothing else.
- Time is a parameter. Never call `Date()` for "now" inside Core.
- If a decision needs a fact from the machine, the caller passes it in.

This is why a walk-away, a colleague's identical strap and a false lock at the
desk all replay in milliseconds in the tests.

## The standing rule: one decision for every lock

Every lock entry point goes through `LockDecision`. Automatic locks use
`LockDecision.judge`. The menu item uses `LockDecision.judgeManual`. A new lock
path calls one of them. It never calls `Locker.lock()` directly.

The bug class this prevents is a second lock path with weaker gates. A
"Lock Now (test)" action once bypassed the dry-run guard and locked the screen
for real. The decision lists its gates in a fixed order so that none can drift.

## What a pull request must include

1. **A test at the layer you changed.** A Core change gets a Core test. An
   adapter change gets a tool or selftest check. Tests print what they got, not
   only that they failed.
2. **A line in `FINDINGS.md` or `docs/adr/` if the change taught you something.**
   A measurement, a dead end or a decision with a reason goes in. Dead ends are
   as useful as answers. See [docs/adr/README.md](docs/adr/README.md).
3. **No new lock path that skips `LockDecision`.**
4. **Comments that say why.** Record the measurement behind a constant.

## Style

- One idea per file, named in the domain's words (`AwayWindow`, `Arrivals`,
  `LockDecision`), not the framework's.
- Prefer a loud wrong answer to a quiet plausible one. Log state and every
  decision input. Failures are silent by default.
- Plain English in docs and comments. Short sentences.

## Verifying on hardware

The lock only proves itself live. Open `build/Waylock.app`, walk away with the
key device, and read `~/Library/Logs/Waylock.log`. Check `enabled=1` in the
heartbeat first. A disabled app scans, reports present and never locks. Use
`WAYLOCK_DRYRUN=1` to exercise the whole path without locking.

## Reporting bugs

Use the bug report form. It asks for the heartbeat line, which is usually enough
to tell a lock-API problem from a key device that never left.
