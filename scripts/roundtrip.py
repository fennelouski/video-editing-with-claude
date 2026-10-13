"""
roundtrip.py — read an FCPXML back out of Final Cut and learn from what she changed.

    python scripts/roundtrip.py build/exports/video001.fcpxml ~/Desktop/video001-edited.fcpxml

`HANDOFF_claude_code.md` item 3. Stage 6 learns from frames it scores itself, which only ever
tells the pipeline whether it followed its own rules. This learns from the edit — and what she
*changed* is a far richer signal than what the pipeline got right, because every change is a
human disagreeing with a decision the pipeline made.

Four signals, in the order they matter:

  **Cuts restored.** She put footage back that Stage 2 removed. The highest-priority signal in
  the project: the pipeline deleted something it should not have, and unlike every other defect
  here, the evidence disappears unless someone looks for it.

  **Graphics deleted.** The pipeline proposed something unwanted.

  **Graphics retimed.** The §5.4 hold formula is wrong for that cue kind. The delta is reported
  so the constant can be *tuned* rather than guessed at.

  **Graphics moved.** Stage 3's anchoring is landing early or late; the direction says which.

Everything it writes is subject to [S-016]. The entries carry an unfilled rule line, because
turning an observation into a testable rule is a judgement the pipeline is not entitled to make
— so writing them **gates stages 3–5 until a human writes the rules**. That friction is the
design: an unread correction teaches nothing, and this reader is the main producer of them.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cli
import config as C          # noqa: E402


# Anything Final Cut can put on a spine that occupies time. `gap` is included because a gap
# shifts everything after it, so ignoring one would misread every subsequent offset.
TIMED = ("asset-clip", "clip", "ref-clip", "sync-clip", "mc-clip", "gap", "video", "audio",
         "title", "transition")

# How far a graphic may drift before it counts as moved rather than as frame-grid rounding.
# One frame is noise; two is a decision.
MOVE_EPSILON = 2 / C.FPS
RETIME_EPSILON = 2 / C.FPS


def seconds(value: str | None) -> float:
    """An FCPXML rational time -> seconds. `None`, `0s` and bare integers all appear in exports."""
    if not value:
        return 0.0
    value = value.strip().rstrip("s")
    if not value:
        return 0.0
    if "/" in value:
        num, den = value.split("/")
        return float(num) / float(den)
    return float(value)


# --------------------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------------------

@dataclass
class Item:
    """One thing on a timeline, at an absolute position."""
    name: str
    kind: str
    offset: float               # absolute timeline position
    duration: float
    source_start: float         # in-point within its own media
    lane: int = 0
    role: str = ""

    @property
    def end(self) -> float:
        return self.offset + self.duration


@dataclass
class Timeline:
    project: str = ""
    fps_num: int = 0
    fps_den: int = 0
    width: int = 0
    height: int = 0
    format_name: str = ""
    clips: list[Item] = field(default_factory=list)      # primary storyline
    graphics: list[Item] = field(default_factory=list)   # connected, lane >= 1
    markers: list[tuple[float, str]] = field(default_factory=list)
    chapters: list[tuple[float, str]] = field(default_factory=list)
    captions: list[tuple[float, float, str]] = field(default_factory=list)

    @property
    def duration(self) -> float:
        return max((c.end for c in self.clips), default=0.0)

    @property
    def frame_duration(self) -> str:
        return f"{self.fps_den}/{self.fps_num}s" if self.fps_num else ""

    def source_spans(self) -> list[tuple[float, float]]:
        """Which parts of the source media survive, in source time."""
        return sorted((c.source_start, c.source_start + c.duration) for c in self.clips)


def parse(path: Path) -> Timeline:
    """
    Read a timeline out of an FCPXML, ours or Final Cut's.

    Written to be forgiving about structure rather than about *values*. FCP's exports nest
    differently from what we generate — storylines inside storylines, `ref-clip` where we wrote
    `asset-clip`, gaps where we wrote nothing — and rejecting those would make the reader
    useless on the only input it exists to read.
    """
    root = ET.parse(path).getroot()
    tl = Timeline()

    fmt = root.find(".//format")
    if fmt is not None:
        tl.format_name = fmt.get("name", "")
        tl.width = int(fmt.get("width") or 0)
        tl.height = int(fmt.get("height") or 0)
        fd = fmt.get("frameDuration", "")
        if "/" in fd:
            den, num = fd.rstrip("s").split("/")
            tl.fps_den, tl.fps_num = int(den), int(num)

    project = root.find(".//project")
    tl.project = (project.get("name", "") if project is not None else "")

    sequence = root.find(".//sequence")
    if sequence is None:
        return tl
    spine = sequence.find("spine")
    if spine is None:
        return tl

    _walk_spine(spine, 0.0, tl)
    tl.clips.sort(key=lambda c: c.offset)
    tl.graphics.sort(key=lambda g: g.offset)
    tl.markers.sort()
    tl.chapters.sort()
    return tl


def _walk_spine(spine: ET.Element, base: float, tl: Timeline) -> None:
    """
    Walk a spine, resolving every offset to absolute timeline time.

    The one subtlety, and the reason CLAUDE.md flags it: a connected clip's `offset` is in its
    *parent's* local time, so its absolute position is
    `parent.offset + (child.offset - parent.start)`. Reading it as timeline time stacks every
    graphic near zero, which looks like a plausible timeline and is completely wrong.
    """
    for el in spine:
        if el.tag not in TIMED:
            continue
        offset = base + seconds(el.get("offset"))
        duration = seconds(el.get("duration"))
        start = seconds(el.get("start"))
        if el.tag == "gap":
            continue        # occupies time, carries nothing; children still resolve below

        tl.clips.append(Item(
            name=el.get("name", ""), kind=el.tag, offset=offset,
            duration=duration, source_start=start,
            role=el.get("videoRole") or el.get("audioRole") or el.get("role") or "",
        ))
        _walk_children(el, offset, start, tl)


def _walk_children(parent: ET.Element, parent_offset: float, parent_start: float,
                   tl: Timeline) -> None:
    for el in parent:
        tag = el.tag
        if tag in ("marker", "chapter-marker"):
            at = parent_offset + (seconds(el.get("start")) - parent_start)
            entry = (round(at, 4), el.get("value", ""))
            (tl.chapters if tag == "chapter-marker" else tl.markers).append(entry)
        elif tag == "spine":
            _walk_spine(el, parent_offset - parent_start, tl)
        elif tag in TIMED:
            absolute = parent_offset + (seconds(el.get("offset")) - parent_start)
            lane = int(el.get("lane") or 0)
            item = Item(
                name=el.get("name", ""), kind=tag, offset=absolute,
                duration=seconds(el.get("duration")), source_start=seconds(el.get("start")),
                lane=lane,
                role=el.get("videoRole") or el.get("audioRole") or el.get("role") or "",
            )
            (tl.graphics if lane >= 1 else tl.clips).append(item)
            _walk_children(el, absolute, item.source_start, tl)


# --------------------------------------------------------------------------------------
# Diff
# --------------------------------------------------------------------------------------

@dataclass
class Change:
    kind: str                   # restored-cut | graphic-deleted | graphic-retimed | graphic-moved
    subject: str
    detail: str
    category: str = "pacing"
    priority: int = 5


def cue_id(name: str) -> str:
    """
    The stable identity of a graphic across the round trip.

    Stage 5 names connected clips `c001 <text>`, and she may well rename one in the edit, so
    matching on the cue id rather than the whole name survives that.
    """
    m = re.match(r"\s*(c\d{3})\b", name)
    return m.group(1) if m else name.strip()


def merge_spans(spans: list[tuple[float, float]],
                tolerance: float = 1 / C.FPS) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1] + tolerance:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def subtract(spans: list[tuple[float, float]],
             removed: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Whatever in `spans` is not covered by `removed`."""
    out = []
    for a, b in spans:
        pieces = [(a, b)]
        for ra, rb in removed:
            nxt = []
            for pa, pb in pieces:
                if rb <= pa or ra >= pb:
                    nxt.append((pa, pb))
                    continue
                if pa < ra:
                    nxt.append((pa, ra))
                if rb < pb:
                    nxt.append((rb, pb))
            pieces = nxt
        out += [(x, y) for x, y in pieces if y - x > 2 / C.FPS]
    return out


def diff(generated: Timeline, edited: Timeline) -> list[Change]:
    changes: list[Change] = []

    # --- Cuts restored. The highest-priority signal in the project. -------------------
    restored = subtract(merge_spans(edited.source_spans()),
                        merge_spans(generated.source_spans()))
    for a, b in restored:
        changes.append(Change(
            kind="restored-cut", category="pacing", priority=1,
            subject=f"source {a:.2f}s–{b:.2f}s",
            detail=(f"{b - a:.2f}s of source footage that Stage 2 removed is back in the edit "
                    f"(source {a:.2f}s–{b:.2f}s). Stage 2 cut something it should have kept."),
        ))

    gen = {cue_id(g.name): g for g in generated.graphics}
    cut = {cue_id(g.name): g for g in edited.graphics}

    for key, g in gen.items():
        if key not in cut:
            changes.append(Change(
                kind="graphic-deleted", category="layout", priority=2,
                subject=key,
                detail=(f"{key} ({g.name!r}) was in the handoff at {g.offset:.2f}s and is not in "
                        f"the edit. The pipeline proposed a graphic she did not want."),
            ))
            continue

        e = cut[key]
        d_dur = e.duration - g.duration
        if abs(d_dur) > RETIME_EPSILON:
            direction = "longer" if d_dur > 0 else "shorter"
            changes.append(Change(
                kind="graphic-retimed", category="motion", priority=3,
                subject=key,
                detail=(f"{key} was retimed {abs(d_dur):.2f}s {direction}: "
                        f"{g.duration:.2f}s → {e.duration:.2f}s. The §5.4 hold formula "
                        f"(max(1.6, words/2.8 + 0.8)) is off for this cue kind by that much."),
            ))

        d_off = e.offset - g.offset
        if abs(d_off) > MOVE_EPSILON:
            direction = "later" if d_off > 0 else "earlier"
            changes.append(Change(
                kind="graphic-moved", category="pacing", priority=4,
                subject=key,
                detail=(f"{key} was moved {abs(d_off):.2f}s {direction}: "
                        f"{g.offset:.2f}s → {e.offset:.2f}s. Stage 3's anchoring is landing "
                        f"{'early' if d_off > 0 else 'late'} for this cue."),
            ))

    changes.sort(key=lambda c: (c.priority, c.subject))
    return changes


# --------------------------------------------------------------------------------------
# Writing corrections
# --------------------------------------------------------------------------------------

RULE_PLACEHOLDER = "_write this as a testable rule before the next run._"

HEADINGS = {
    "restored-cut": "Stage 2 removed footage she put back",
    "graphic-deleted": "Graphic deleted in the edit",
    "graphic-retimed": "Graphic retimed in the edit",
    "graphic-moved": "Graphic moved in the edit",
}


def write_entries(changes: list[Change], project: str, path: Path | None = None) -> int:
    """
    Append one entry per defect — never per occurrence.

    A single mis-anchored cue kind can produce a dozen moved graphics, and a dozen near-identical
    entries would bury the log and make §13's promotion rule meaningless. So changes are grouped
    by kind, with the instances listed inside one entry.
    """
    if not changes:
        return 0
    path = path or C.STYLE_GUIDE
    text = path.read_text()
    marker = "<!-- NEW ENTRIES GO DIRECTLY BELOW THIS LINE -->"
    if marker not in text:
        raise SystemExit(f"! {path.name} has no insertion marker; refusing to guess where to write")

    existing = len(re.findall(r"^### \[R-\d+\]", text, re.M))
    grouped: dict[str, list[Change]] = {}
    for change in changes:
        grouped.setdefault(change.kind, []).append(change)

    blocks = []
    for i, (kind, items) in enumerate(
            sorted(grouped.items(), key=lambda kv: kv[1][0].priority), start=existing + 1):
        # The subject is named separately rather than left to appear inside the detail text.
        # An entry that says what happened but not what it happened to is not actionable.
        listing = "\n".join(f"  - `{c.subject}` — {c.detail}" for c in items)
        blocks.append(
            f"\n### [R-{i:03d}] — {HEADINGS.get(kind, kind)}\n"
            f"- **Date:** {date.today().isoformat()}\n"
            f"- **Video / shot:** {project} · {len(items)} instance(s)\n"
            f"- **Source:** roundtrip\n"
            f"- **Status:** ACTIVE\n"
            f"- **Category:** {items[0].category}\n"
            f"- **What was wrong:**\n{listing}\n"
            f"- **Why it was wrong:** she changed it in the edit, so the pipeline's decision "
            f"disagreed with hers.\n"
            f"- **The rule going forward:** {RULE_PLACEHOLDER}\n"
            f"- **Auto-check:** {RULE_PLACEHOLDER}\n"
        )

    path.write_text(text.replace(marker, marker + "\n" + "\n".join(blocks)))
    return len(blocks)


# --------------------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------------------

def describe(tl: Timeline, label: str) -> None:
    rate = f"{tl.fps_num}/{tl.fps_den}" if tl.fps_num else "unknown"
    print(f"  {label}: {tl.project or '(unnamed)'}")
    print(f"     format {tl.format_name or '(none)'} · {tl.width}x{tl.height} · {rate}"
          f" · {tl.duration:.2f}s")
    print(f"     {len(tl.clips)} clip(s), {len(tl.graphics)} graphic(s), "
          f"{len(tl.markers)} marker(s), {len(tl.chapters)} chapter(s)")


def main(argv: list[str] | None = None) -> int:
    cli.preflight()
    ap = argparse.ArgumentParser(description="Diff an FCP export against the pipeline's handoff")
    ap.add_argument("generated", type=Path, help="what the pipeline emitted")
    ap.add_argument("edited", nargs="?", type=Path, help="what Final Cut exported after editing")
    ap.add_argument("--project", default="video001")
    ap.add_argument("--dry-run", action="store_true", help="report without writing entries")
    args = ap.parse_args(argv)

    # Final Cut 11 exports a .fcpxmld bundle, so that is what anyone will hand this. Both
    # arguments go through the same resolution: the handoff is ours, the edit is FCP's.
    generated = cli.resolve_or_exit(
        args.generated, expect=(".fcpxml",), label="pipeline handoff")
    handoff = parse(generated)
    print("Round trip")
    describe(handoff, "handoff ")

    if not args.edited:
        # Inspection mode. Useful on its own: it reports the format Final Cut actually built,
        # which is the only way to see what a name like FFVideoFormatRateUndefined resolved to.
        return 0
    export = parse(cli.resolve_or_exit(
        args.edited, expect=(".fcpxml",), label="Final Cut export"))
    describe(export, "edit    ")

    if handoff.frame_duration and export.frame_duration \
            and handoff.frame_duration != export.frame_duration:
        print(f"\n  ! TIMEBASE CHANGED: {handoff.frame_duration} → {export.frame_duration}")
        print("    Final Cut conformed the sequence. Every downstream time is now wrong,")
        print("    and nothing else in the pipeline would report it. See [S-007].")

    changes = diff(handoff, export)
    if not changes:
        print("\n  no differences — she kept the handoff as it was")
        return 0

    print(f"\n  {len(changes)} change(s):")
    for c in changes:
        print(f"    [{c.kind}] {c.detail}")

    if args.dry_run:
        print("\n  [dry run] nothing written")
        return 0

    written = write_entries(changes, args.project)
    print(f"\n  {written} entry/entries appended to {C.STYLE_GUIDE.name}")
    print("  Each carries an unfilled rule line, so stages 3–5 will refuse to run until")
    print("  they are written ([S-016]). That is deliberate: an unread correction teaches")
    print("  the pipeline nothing, and this is the point at which it can still be written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
