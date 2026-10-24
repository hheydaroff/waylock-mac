# 0002. Identify the key by name plus a learned address set

## Status

Accepted.

## Context

Pinning one CoreBluetooth UUID failed. The same buds advertise under several
addresses at once. One pin landed on a stream at 0.09 Hz while the same device
advertised at 0.77 Hz under another address.

Matching on name alone fails open. A colleague with the same model is another
matching channel, the union never goes silent, and the Mac stays unlocked after
you leave, silently.

## Decision

Identity is a case-insensitive substring of the advertised name, plus a
persisted set of up to 8 learned addresses.

- A known address is the key.
- A new same-name address is adopted only when no other same-name peripheral
  was seen in the last 10 s. That is what a rotation looks like.
- A new same-name address that arrives beside a known one is an impostor and is
  not adopted.

## Consequences

- A colleague's identical device is not tracked. The Mac still counts as away
  when you leave.
- Residual risk: a rotation that coincides with an impostor's first sighting.
- The impostor case cannot be staged with hardware. Tests drive `KeyIdentity`
  directly.

## Evidence

- [FINDINGS: Identity over time, and impostors](../../FINDINGS.md#identity-over-time-and-impostors)
- [README](../../README.md), sections "When someone else owns the same model"
  and "Known limits"
