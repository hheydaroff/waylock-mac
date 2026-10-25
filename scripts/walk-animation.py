#!/usr/bin/env python3
"""Render the walk-away recording as a looping video.

    uv run --with pillow scripts/walk-animation.py /tmp/walk.log

Reads `waylock-watch` output, writes docs/data/walk-away.json (timings and RSSI
only — no UUIDs, no MACs, so it is safe to publish) and draws frames with Pillow
for ffmpeg.

Why a drawing rather than a screen recording: the interesting part happens over
21 seconds of silence, which is unwatchable at real speed and looks like a
frozen app. Playing it at 4x against a chart of the same packets says the same
thing in 15 seconds and shows why the window works.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W = H = 1080
BG, INK, MUTED, DIM = "#0b0d0f", "#e8e6e1", "#6b737c", "#1b2126"
AMBER, GREEN = "#f0b429", "#5fd08a"

FPS = 30
DURATION_S = 15.0
PLAY = 0.80          # first 80% of the video sweeps the trace, the rest holds
WINDOW = 15.0        # the shipped default, the line that means "away"

PAD = 72
CHART_TOP, CHART_BOT = 300, 700


def load(path: Path) -> list[dict]:
    """Packets as {t, rssi}. Deliberately drops the UUID and company bytes."""
    out = []
    pat = re.compile(r"^\s*([\d.]+)s\s+rssi=(-?\d+)\s+(\S+)")
    for line in path.read_text().splitlines():
        m = pat.match(line)
        if m:
            out.append({"t": float(m.group(1)), "rssi": int(m.group(2))})
    if not out:
        sys.exit(f"no packets parsed from {path}")
    return out


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    # Menlo ships with macOS; index 1 is the bold face inside the collection.
    return ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", size, index=1 if bold else 0)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("log", type=Path)
    ap.add_argument("--out", type=Path, default=Path("docs/assets/walk-away.mp4"))
    ap.add_argument("--poster", type=Path, default=Path("docs/assets/walk-away-poster.png"))
    ap.add_argument("--data", type=Path, default=Path("docs/data/walk-away.json"))
    ap.add_argument("--frames", type=Path, default=Path("/tmp/waylock-frames"))
    args = ap.parse_args()

    packets = load(args.log)
    packets.sort(key=lambda p: p["t"])
    ts = sorted({p["t"] for p in packets})
    gaps = [(b - a, a, b) for a, b in zip(ts, ts[1:])]
    span = ts[-1]
    longest = max(gaps)
    if longest[0] < WINDOW:
        sys.exit(
            f"longest silence is {longest[0]:.1f}s, under the {WINDOW:.0f}s window: "
            "this recording cannot show a lock, and faking one would be worthless"
        )

    args.data.parent.mkdir(parents=True, exist_ok=True)
    args.data.write_text(json.dumps({
        "recording": "waylock-watch",
        "device": "Amazfit Helio Strap",
        "seconds": round(span, 2),
        "window": WINDOW,
        "silences_over_window": [round(g[0], 2) for g in gaps if g[0] >= WINDOW],
        "packets": packets,
    }, indent=1) + "\n")

    # The view is the excursion plus lead-in and recovery, not the whole file.
    big = [g for g in gaps if g[0] >= WINDOW]
    t0 = max(0.0, big[0][1] - 22.0)
    t1 = min(span, big[-1][2] + 14.0)

    LEFT, RIGHT = 150, W - PAD

    def x_of(t: float) -> float:
        return LEFT + (t - t0) / (t1 - t0) * (RIGHT - LEFT)

    top_r, bot_r = -38, -95          # the RSSI range that matters on this device

    def y_rssi(v: float) -> float:
        v = max(min(v, top_r), bot_r)
        return 470 + (top_r - v) / (top_r - bot_r) * 165

    f_kick, f_head, f_sub = font(20), font(50, True), font(22)
    f_axis, f_state, f_foot = font(16), font(38, True), font(17)

    def absence(t: float) -> tuple[float, float]:
        """(seconds since the last packet, the gap this moment sits in)."""
        prev = ts[0]
        for p in ts:
            if p <= t:
                prev = p
            else:
                return t - prev, p - prev
        return t - prev, t - prev

    def state_at(t: float) -> str:
        """The app's phase at this instant: present -> counting -> lockedOut -> re-armed.

        Ordered by silence rather than layered, so the tail settles on "present"
        instead of holding the last lock forever.
        """
        for duration, start, end in big:
            if start <= t < start + WINDOW:
                return "silent, counting"
            if start + WINDOW <= t <= end:
                return "AWAY  →  locked"
            if end < t <= end + 4.0:
                return "key back  →  re-armed"
        return "key present"

    def frame(t: float) -> Image.Image:
        im = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(im, "RGBA")

        d.text((PAD, 62), "measured walk, not a mock-up", font=f_kick, fill=MUTED)
        d.text((PAD, 100), "It fades at -88 dBm,", font=f_head, fill=INK)
        d.text((PAD, 162), "then it just goes quiet.", font=f_head, fill=INK)
        d.text((PAD, 234), f"Amazfit Helio Strap · {span:.0f} s at 4x · window {WINDOW:.0f} s",
               font=f_sub, fill=MUTED)

        # ---- silences over the window: the measurement, shaded -------------
        for duration, start, end in big:
            if start > t:
                continue
            xs, xe = x_of(start), x_of(min(end, t))
            d.rectangle([xs, 300, xe, 640], fill=(240, 180, 41, 16))
            if xe - xs > 60:
                d.text((xs + 10, 306), f"{duration:.1f} s silent", font=f_axis, fill=AMBER)

        # ---- one tick per advertisement -----------------------------------
        d.text((PAD, 300), "packets", font=f_axis, fill=MUTED)
        for i, p in enumerate(packets):
            if not (t0 <= p["t"] <= t):
                continue
            x = x_of(p["t"])
            y = 340 + (i % 5) * 13
            d.ellipse([x - 2.2, y - 2.2, x + 2.2, y + 2.2], fill=(232, 230, 225, 160))

        # ---- the signal: the number that decides nothing ------------------
        d.text((PAD, 400), "dBm", font=f_axis, fill=MUTED)
        for v in (top_r, -60, bot_r):
            d.line([LEFT, y_rssi(v), RIGHT, y_rssi(v)], fill=DIM, width=1)
            d.text((PAD + 8, y_rssi(v) - 9), f"{v}", font=f_axis, fill=MUTED)
        pts = [(x_of(p["t"]), y_rssi(p["rssi"])) for p in packets if t0 <= p["t"] <= t]
        if len(pts) > 1:
            d.line(pts, fill=(120, 132, 142, 120), width=2)
        seen = [p for p in packets if t0 <= p["t"] <= t]
        if seen:
            last = max(seen, key=lambda p: p["t"])
            x, y = x_of(last["t"]), y_rssi(last["rssi"])
            d.ellipse([x - 4, y - 4, x + 4, y + 4], fill=AMBER)
            d.text((min(x + 12, RIGHT - 60), y - 22), f"{last['rssi']} dBm", font=f_axis, fill=AMBER)

        # ---- time axis ----------------------------------------------------
        d.line([LEFT, 652, RIGHT, 652], fill=DIM, width=1)
        tick = int(t0 // 10 * 10) + 10
        while tick < t1:
            if tick >= t0:
                d.line([x_of(tick), 652, x_of(tick), 658], fill=DIM, width=1)
                d.text((x_of(tick) - 12, 664), f"{tick}s", font=f_axis, fill=MUTED)
            tick += 10

        # ---- absence bar: the thing that actually fills -------------------
        absent, gap = absence(t)
        bar_y, bar_h = 706, 16
        d.rectangle([LEFT, bar_y, RIGHT, bar_y + bar_h], fill="#141a1f", outline=DIM)
        frac = min(absent / WINDOW, 1.0) if gap >= 1.0 else 0.0
        if frac > 0:
            d.rectangle([LEFT, bar_y, LEFT + frac * (RIGHT - LEFT), bar_y + bar_h],
                        fill=AMBER if frac >= 1 else (240, 180, 41, 150))
        xw = LEFT + (RIGHT - LEFT)
        d.text((PAD, bar_y - 6), "silence", font=f_axis, fill=MUTED)
        d.text((RIGHT - 150, bar_y + bar_h + 10), f"{WINDOW:.0f} s = away", font=f_axis,
               fill=AMBER if frac >= 1 else MUTED)
        d.text((LEFT, bar_y + bar_h + 10), f"{absent:4.1f} s", font=f_axis, fill=MUTED)

        label = state_at(t)
        colour = AMBER if "AWAY" in label else GREEN if "re-armed" in label else INK
        d.text((PAD, 792), label, font=f_state, fill=colour)

        # The argument, stated at the moment it matters: RSSI was still civil.
        locked_now = any(st + WINDOW <= t <= en for _, st, en in big)
        if locked_now and seen:
            d.text((PAD, 862), f"RSSI at this instant: {seen[-1]['rssi']} dBm.", font=f_sub, fill=MUTED)
            d.text((PAD, 894), "No signal-strength threshold fires here. Absence does.",
                   font=f_sub, fill=MUTED)
        elif t > big[-1][2] + 4.0:
            d.text((PAD, 862), "Two silences in three minutes, both past the window.", font=f_sub, fill=MUTED)
            d.text((PAD, 894), "Not once did signal strength cross a threshold worth trusting.",
                   font=f_sub, fill=MUTED)

        d.text((PAD, 1006), "ticks are real advertisements · the lock is what the app does at the line",
               font=f_foot, fill=MUTED)
        return im

    args.frames.mkdir(parents=True, exist_ok=True)
    total = int(FPS * DURATION_S)
    for i in range(total):
        p = i / (total - 1)
        t = t0 + min(1.0, p / PLAY) * (t1 - t0)
        frame(t).save(args.frames / f"f{i:04d}.png")
        if i == 0:
            pass
        # the poster is the moment the window is full: the honest freeze-frame
        if abs(t - (big[0][1] + WINDOW + 1.5)) < (t1 - t0) / total:
            frame(t).save(args.poster)

    print(f"frames {total} · {args.frames}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS),
        "-i", str(args.frames / "f%04d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20",
        "-movflags", "+faststart", str(args.out),
    ], check=True)
    print(f"wrote {args.out} ({args.out.stat().st_size // 1024} KB) and {args.poster}")
    print(f"silences over the window: {[round(g[0], 1) for g in gaps if g[0] >= WINDOW]}")


if __name__ == "__main__":
    main()