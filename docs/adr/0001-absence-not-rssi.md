# 0001. Detect absence, not signal strength

## Status

Accepted.

## Context

The obvious design locks when RSSI falls below a threshold. On earbuds that
does not work: the antenna is against your head, and the body blocks 2.4 GHz.
Measured on macOS 27.0.1:

- At the desk, the buds wandered between -70 and -83 dBm. A 22 s capture ranged
  from -88 to -52 dBm.
- On returning from a walk, RSSI read -89 dBm at re-entry.
- At-desk RSSI overlaps departure RSSI. No threshold separates them, and a
  threshold near -85 dBm fires during normal wear.

## Decision

The key device is present if any of its channels was heard recently. It is
away when the union of all channels has been silent for the away window. RSSI is
logged and shown, and never compared against a threshold.

The window was sized from a 10-minute, 600-sample at-desk baseline of the union
gap: median 1.0 s, p90 3.3 s, p95 4.5 s, p99 7.6 s, max 10.2 s. A 10 s window
false-locked at the desk. A 15 s window did not.

## Consequences

- Waylock locks when the key device leaves BLE range. It does not measure 5 m.
- Lock latency is the window plus up to one 0.5 s tick. A larger window costs
  seconds once. A smaller one costs a locked screen mid-work.

## Evidence

- [FINDINGS: RSSI as a distance proxy](../../FINDINGS.md#rssi-as-a-distance-proxy--unusable-for-earbuds),
  [FINDINGS: Threshold selection](../../FINDINGS.md#threshold-selection)
- [README: How the window is chosen](../../README.md#how-the-window-is-chosen),
  and the README section "Why phones and the Apple Watch mostly do not work"
