# Waylock — the words this code uses

The domain, so the names in the code and the names in a conversation mean the
same thing.

**Key device** — the one Bluetooth thing whose presence means "I am at my desk".
Currently an Amazfit Helio Strap. Chosen by name substring, so any named
advertiser can be a key; phones and watches do not advertise a name.

**Channel** — one BLE address the key device is currently advertising from. A
device may use several at once and rotates addresses over time, so channels come
and go while the device stays.

**Sighting** — one advertisement from one channel: name, address, RSSI.

**Arrival** — the gap between two sightings on *any* key channel. The union, not
per channel, because a single slow channel goes quiet for 30 s while the device
is sitting on the desk.

**Away window** — how long the union must be silent before the Mac counts as
away. Per device, learned from that device's own arrival distribution
(`worst kept gap × 1.5`, clamped 12–60 s), with a 20 s warm-up while learning and
a manual override that always wins.

**Absent for** — seconds since the last arrival. `nil` means never seen, which is
different from "seen long ago".

**Present / away** — present is `absent < window`. There is no distance, no
threshold in dBm, and no "5 metres": RSSI could not be relied on at desk
distance, so absence is the signal.

**Phase** — `noKey` (never seen, or disabled), `armed` (present), `away`
(silent, counting), `lockedOut` (locked, waiting for the key to come back).

**Judgment** — the pair of (phase, action) that the lock decision returns. It is
a value, so every gate can be tested without a radio or a screen.

**Gate** — a reason not to lock, checked in a fixed order: enabled, re-arm,
away window, cooldown, activity, already locked, dry run.

**Address set** — the addresses learned to belong to the key device, up to 8.
This is what distinguishes your strap from a colleague's identical one.

**Rival** — another same-named address seen within the last 10 s. A new address
arriving while there is a rival is an impostor; arriving alone is a rotation.

**Learned window** vs **manual window** — measured automatically, or picked from
the menu. Manual wins; "Automatic" clears it and re-learns.

**Dry run** — `WAYLOCK_DRYRUN=1`. Prints what it would do. It is a real gate, not
a debug print: it is checked in the same decision as everything else.