# Security

Waylock is a convenience lock. It is not a security control.

It locks your screen when a Bluetooth key device stops being heard. It does not
stop anyone who can reach your Mac while you are nearby, and it does not stop
anyone who has your key device. Do not rely on it where a missed lock has
consequences. Use a short screen-saver timeout and `Ctrl+Cmd+Q` for that.

## How it fails

### Fails open: the Mac stays unlocked after you leave

- **You leave the key device behind.** A strap on the desk is still advertising,
  so the key is present and the Mac does not lock. This is the correct answer to
  the question Waylock asks. It is the wrong answer for you.
- **The key device keeps advertising off your body.** The same thing happens if a
  strap that is off your wrist or on its charger keeps advertising. Whether it
  does is untested; `FINDINGS.md` lists it under open questions. If it stops
  advertising, the Mac locks instead (see below).
- **Warm-up.** If the app launches while the key is out of range, it has never
  seen the key and will not lock until it has seen it once.
- **A rotation at the wrong moment.** A colleague with the same model is not
  tracked, because an unknown same-named address is adopted only when no other
  same-named device was seen in the last 10 s. A device that rotates its address
  at the exact moment an impostor first appears could confuse this. It is
  recorded in the README under Known limits and is not defended against.

### Fails closed: the Mac locks when you are still there

- **The key device stops advertising.** Dead battery, powered off, in its case,
  or paired elsewhere first. The Mac locks.
- **Mitigation: the HID idle gate.** The lock needs keyboard and mouse idle time
  to have reached the whole away window. While you type or move the mouse, the
  lock is held. If you are seated and idle for the full window, it locks.

## Dependencies on the platform

- **Private API.** The lock calls `SACLockScreenImmediate` from `login.framework`,
  resolved with `dlopen` and `dlsym`. Apple does not document or support it. It
  can change or vanish in any macOS release. The call reports success even when
  nothing locks, so Waylock reads `CGSSessionScreenIsLocked` back for 3 s and
  logs the result. The private symbol makes the app ineligible for the App
  Store and for notarisation.
- **Bluetooth permission is bound to the code signature.** `build.sh` signs
  ad-hoc, and each build has a new signature. After a rebuild macOS treats the
  app as new and asks again. If the screen is locked, the prompt cannot appear.
  CoreBluetooth then never reports a state and the app scans nothing, while it
  keeps logging heartbeats. Check `~/Library/Logs/Waylock.log` and approve the
  prompt from an unlocked screen.
- **No unlock.** `login.framework` exports no unlock symbol. Touch ID or your
  password stays the unlock path.

## Reporting a vulnerability

Use a GitHub private security advisory: open the repository's Security tab and
choose "Report a vulnerability". Do not open a public issue for a vulnerability.

Waylock is a personal project. There is no response-time commitment.

Behaviour that is already listed above is a known limit, not a vulnerability.
Bugs in the matching or the lock decision that make it fail in a way not listed
here are worth reporting.
