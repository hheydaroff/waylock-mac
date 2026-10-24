# 0004. Sign ad-hoc, and surface the permission stall

## Status

Accepted. The durable fix, a stable signing identity, is not adopted.

## Context

`build.sh` signs the app ad-hoc, so every build has a new cdhash. macOS keys the
Bluetooth grant to that signature. After a rebuild, `tccd` logs:

```
tccd: Failed to match existing code requirement for io.github.hheydaroff.waylock
tccd: AUTHREQ_PROMPTING
```

With the screen locked the prompt cannot appear. `CBCentralManager` stays at
state 0 (`unknown`) and never calls its delegate. The app scans nothing and keeps
logging heartbeats, which looks like "the key is not here".

## Decision

Keep ad-hoc signing and make the stall loud.
- The CLI modes inherit the terminal's grant, so tests and tools keep working
  across rebuilds.
- The radio watchdog recreates the central every 15 s, up to 40 retries, and
  logs a permission hint when the state is `unknown`.
- The menu reads "Waiting for Bluetooth permission", not "Bluetooth unavailable".

## Consequences

- Each rebuild needs one approval from an unlocked screen. A stable self-signed
  identity would stop the prompts. The README has the recipe. It needs a
  one-time Keychain approval and is not in `build.sh`.
- Only `log show` on `com.apple.TCC` explains the stall.

## Evidence

- [FINDINGS: Permissions are keyed to the code signature](../../FINDINGS.md#permissions-are-keyed-to-the-code-signature)
- [README](../../README.md), section "Permissions and the code signature"
