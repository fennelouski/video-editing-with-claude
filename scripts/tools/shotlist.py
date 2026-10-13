"""
shotlist.py — every shot in the assembly, as a table someone can work from.

Generated from the picks file rather than written by hand, because a hand-written shot list is
out of date the first time anyone moves an edit point. Timeline timecodes are computed the same
way the timeline computes them, from frame-snapped durations, so they match the FCPXML and the
preview exactly rather than approximately.

    ./run tools/shotlist.py cuts/intro001/picks.json -o cuts/intro001/shot-list.md
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli
import config as C
import fcpxml as FX
from assemble import load_music, load_picks


def tc(seconds: float) -> str:
    """m:ss.ff — frames, not hundredths, because the timeline is counted in frames."""
    frames = C.frames(seconds)
    f = frames % round(C.FPS)
    total = frames // round(C.FPS)
    return f"{total // 60}:{total % 60:02d}.{f:02d}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Shot list for an assembly")
    ap.add_argument("picks")
    ap.add_argument("-o", "--out", help="markdown file (default: stdout)")
    args = ap.parse_args(argv)

    path = cli.resolve_or_exit(args.picks, expect=(".json",), label="picks file")
    project, picks, spec = load_picks(path)
    total = sum(p["end"] - p["start"] for p in picks)
    cues = load_music(spec, total)

    by_source: dict[str, list[float]] = {}
    rows, timeline = [], 0.0
    for i, p in enumerate(picks):
        span = p["end"] - p["start"]
        name = p["path"].name
        by_source.setdefault(name, []).append(span)
        picture = p.get("video")
        rows.append({
            "n": i + 1,
            "at": tc(timeline),
            "dur": f"{span:.1f}s",
            "sound": f"{name} @ {p['start']:.2f}",
            "picture": (f"**{picture['path'].name} @ {picture['start']:.2f}**"
                        if picture else "—"),
            "note": p.get("note", ""),
            "gain": f"{p['gain_db']:+.1f} dB" if p.get("gain_db") else "",
            "text": p.get("text", ""),
        })
        timeline += span

    out = [
        f"# {project} — shot list",
        "",
        f"Every shot in the assembly, in order. **{len(picks)} shots, {tc(total)}**, "
        f"23.976p, 1920×1080.",
        "",
        "Generated from `picks.json`, so it cannot drift from the timeline. *Sound* is where "
        "the audio comes from; *picture* is only filled in where the shot is a split edit and "
        "the picture comes from somewhere else.",
        "",
        "## Sources",
        "",
        "| Clip | Shots | On screen |",
        "|---|---|---|",
    ]
    for name, spans in sorted(by_source.items(), key=lambda kv: -sum(kv[1])):
        out.append(f"| `{name}` | {len(spans)} | {tc(sum(spans))} |")

    if cues:
        out += ["", "## Music", "", "| Track | In | Out | Level |", "|---|---|---|---|"]
        for cue in cues:
            out.append(f"| {cue['path'].stem} | {tc(cue['at'])} | {tc(cue['until'])} | "
                       f"{cue.get('under_db', 13):.0f} dB under the voice |")

    out += ["", "## Shots", "",
            "| # | At | Dur | Sound | Picture | What it is |", "|---|---|---|---|---|---|"]
    for r in rows:
        note = r["note"] + (f" · sound {r['gain']}" if r["gain"] else "")
        out.append(f"| {r['n']} | {r['at']} | {r['dur']} | `{r['sound']}` | {r['picture']} | "
                   f"{note} |")

    out += ["", "## What each shot says", ""]
    for r in rows:
        if r["text"]:
            out.append(f"**{r['n']}. {r['at']}** — {r['text']}")
            out.append("")

    text = "\n".join(out) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"  ✓ {args.out}  ({len(picks)} shots)")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
