# 0003. Lock with the private API, and verify it

## Status

Accepted.

## Context

macOS has no public API to lock the screen. Apple DTS confirms this. The options
checked on macOS 27:

| Mechanism | Result |
|---|---|
| `CGSession -suspend` | absent |
| `pmset displaysleepnow` | locks only if "require password immediately" is set |
| System Events Cmd+Ctrl+Q | works, but needs Accessibility and Automation consent, and depends on the keyboard layout |
| `SACLockScreenImmediate` | resolves from `login.framework` and locks with no prompt |

## Decision

Resolve `SACLockScreenImmediate` with `dlopen` and `dlsym` at run time. After the
call, poll `CGSSessionScreenIsLocked` for 3 s and log the result. The private
call reports success even when nothing locked, so its return code is never the
answer.

`Locker.lock()` returns only what was verified. A failed lock retries next tick.

## Consequences

- Personal build: the private symbol rules out the App Store and notarisation.
- Apple can remove the symbol in any release. The log then says
  `could not resolve` or `screen did not lock`.
- There is no unlock. `login.framework` exports no unlock symbol, and injecting
  a password would need Accessibility and a stored credential.

## Evidence

- [FINDINGS: Lock mechanism](../../FINDINGS.md#lock-mechanism)
- [README: What this is not](../../README.md#what-this-is-not), and the README
  section "Design rules" (Verify the lock)
