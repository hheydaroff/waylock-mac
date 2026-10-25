#!/usr/bin/env python3
"""Put a recorded gap trace into the pages that display it.

Both pages are static and self-contained — no fetch, no build step, no CDN — which
is why the trace is inlined rather than loaded. This script owns that inlining so
the numbers in the repo are never hand-edited.

    waylock-tools --export-gaps 10 --out /tmp/gaps.json
    uv run python scripts/embed_trace.py /tmp/gaps.json

Idempotent by construction: it rewrites the existing `const DATA = ...;` /
`const GAPS = ...;` lines, so running it twice changes nothing after the first
run, and the placeholder is only needed the first time.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SIMULATOR = ROOT / "docs" / "window-simulator.html"
CARD = ROOT / "docs" / "assets" / "social-preview.html"
HERO = ROOT / "docs" / "assets" / "trace.html"

# Historical traces stay in the file, so recording a second device does not wipe the
# first: whatever is already embedded is parsed back out and re-emitted.
DEFAULT_WINDOW = 15


def app_rule(gaps):
    """The window the app itself would learn, restated from Core/Arrivals.swift."""
    s = sorted(gaps)
    median = s[len(s) // 2]
    cutoff = max(10 * median, 15.0)
    kept = [g for g in s if g <= cutoff]
    worst = kept[-1] if kept else 0.0
    return min(60.0, max(12.0, round(worst * 1.5, 1))), cutoff


def load(path):
    trace = json.loads(pathlib.Path(path).read_text())
    gaps = [round(float(g), 3) for g in trace["gaps"]]
    if len(gaps) < 20:
        sys.exit(f"only {len(gaps)} gaps — too few to publish as evidence")
    window, cutoff = app_rule(gaps)
    if trace.get("recommended") is not None and abs(trace["recommended"] - window) > 0.15:
        print(f"warning: binary said {trace['recommended']} s, this rule says {window} s")
    return {
        "device": trace["device"],
        "seconds": trace["seconds"],
        "samples": len(gaps),
        "appWindow": trace.get("appWindow"),
        "recommended": trace.get("recommended", window),
        "cutoff": round(cutoff, 1),
        "gaps": gaps,
    }


def replace_line(text, pattern, replacement):
    new, n = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if n != 1:
        sys.exit(f"expected exactly one match for {pattern!r}, found {n}")
    return new


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    fresh = load(argv[1])

    datasets = []
    sim = SIMULATOR.read_text()
    existing = re.search(r"^const DATA = (.+);$", sim, re.MULTILINE)
    if existing:
        try:
            datasets = json.loads(existing.group(1)).get("datasets", [])
        except json.JSONDecodeError:
            datasets = []          # first run, still the placeholder
    datasets = [fresh] + [d for d in datasets if d.get("device") != fresh["device"]]

    payload = {"defaultWindow": DEFAULT_WINDOW, "datasets": datasets}
    sim = replace_line(sim, r"^const DATA = .*;$", "const DATA = " + json.dumps(payload) + ";")
    SIMULATOR.write_text(sim)

    # Both charts draw the same gaps at different sizes; only the card needs the cutoff.
    gaps_line = "const GAPS = " + json.dumps(fresh["gaps"]) + ";"
    for path, cutoff in ((CARD, True), (HERO, False)):
        text = path.read_text()
        text = replace_line(text, r"^const GAPS = .*;$", gaps_line)
        if cutoff:
            text = replace_line(text, r"^const CUTOFF = .*;", f"const CUTOFF = {fresh['cutoff']};")
        path.write_text(text)

    print(f"embedded {fresh['samples']} gaps from '{fresh['device']}' "
          f"({fresh['seconds']:.0f} s, cutoff {fresh['cutoff']} s, app window {fresh['recommended']} s)")
    for p in (SIMULATOR, CARD, HERO):
        print(f"  {p.relative_to(ROOT)}")


if __name__ == "__main__":
    main(sys.argv)