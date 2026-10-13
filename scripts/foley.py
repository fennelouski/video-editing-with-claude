"""
foley.py — a real sound at the moment each piece touches the table.

    ./run foley.py --project video001 --dry-run

`HANDOFF_claude_code.md` item 7, and taste_principles §8 calls it the secret weapon:
*"Every graphic placement gets a real sound: cardboard tap, paper slide, marker squeak, pencil
scratch. Record a foley library once — 30 minutes of table sounds buys the entire channel's
credibility."* It is ordinary work with disproportionate effect, and it is what makes the
graphics read as objects rather than as layers.

Two details decide whether it works:

**The hit lands on the place-down frame, not the entrance start.** The sound is the piece
*touching the table*, so it belongs where the motion reaches the surface — which is not the
beginning of the animation and not the end of it either. §5.3's settle overshoots, so contact
happens around three-quarters of the way through. That frame is *derived from the easing curve*
rather than hardcoded, so if the settle is ever retuned the foley follows it instead of
drifting quietly out of sync.

**The variation never repeats consecutively.** The same tap twice in a row is worse than no
foley at all — it announces that the sound is a sample rather than a thing happening. Selection
is seeded and deterministic, like everything else in `stepclock`, and structurally cannot pick
the same file twice in succession.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cli
import config as C          # noqa: E402
import corrections as CR    # noqa: E402
import stepclock as SC      # noqa: E402

# Cue kinds that put something on screen. The others are shot notes for her, and a sound
# against a note nobody rendered would be a sound with no picture.
RENDERED_KINDS = {"GFX", "CHAPTER"}


@dataclass
class Hit:
    """One foley sound at one moment."""
    cue_id: str
    element: str
    at: float               # timeline seconds
    category: str
    sound: Path

    @property
    def name(self) -> str:
        return f"{self.cue_id} {self.category} · {self.sound.stem}"


# --------------------------------------------------------------------------------------
# Timing
# --------------------------------------------------------------------------------------

def contact_frame(clock: SC.StepClock, place_frames: int = C.PLACE_FRAMES[1]) -> int:
    """
    The stepped frame at which a placed piece first reaches the surface.

    Read off `stepclock.place_in` rather than assumed. §5.3 places a piece from ~40 px above
    with a settle overshoot, so it arrives at rest *before* the animation ends and then dips
    slightly past — hardcoding either endpoint would put the tap early or late by several
    frames, which is precisely the "graphic arriving four frames late" the thesis rules out.
    """
    for frame in range(0, place_frames + 1, clock.step):
        if SC.place_in("contact-probe", frame, place_frames, clock).y >= 0.0:
            return frame
    return place_frames


def hits_for_plan(plan: dict, library: "Library", tmap=None,
                  clock: SC.StepClock | None = None) -> tuple[list[Hit], list[str]]:
    """
    One hit per element placed, in timeline time.

    A diagram assembled from five cutouts gets five taps, staggered by §5.3's 4 frames — which
    is what stop-motion assembly actually sounds like, and why the stagger exists at all.
    """
    clock = clock or SC.StepClock()
    contact = contact_frame(clock)
    hits: list[Hit] = []
    problems: list[str] = []
    previous: dict[str, int] = {}

    for cue in plan.get("cues", []):
        if cue.get("start") is None or cue.get("kind") not in RENDERED_KINDS:
            continue
        assets = cue.get("assets") or []
        if not assets:
            continue

        # Cue times are source time; the timeline is the cut. Remap or every hit lands late by
        # however much Stage 2 removed before it (CLAUDE.md § Source time vs timeline time).
        if tmap is not None:
            base, _ = tmap.nearest(cue["start"])
        else:
            base = cue["start"]

        category = cue.get("foley") or C.FOLEY_DEFAULT_CATEGORY
        if category not in library.categories:
            problems.append(
                f"{cue['id']}: no {category!r} sounds in "
                f"{C.path_label(C.FOLEY)}/ — recorded categories are "
                f"{', '.join(sorted(library.categories)) or 'none'}"
            )
            continue

        for index, _asset in enumerate(assets):
            frame = contact + SC.stagger_offset(index)
            at = base + frame * C.FPS_DEN / C.FPS_NUM
            chosen, previous[category] = library.pick(
                category, previous.get(category), key=f"{cue['id']}:{index}")
            hits.append(Hit(cue_id=cue["id"], element=f"{cue['id']}:{index}",
                            at=C.snap_seconds(at), category=category, sound=chosen))

    hits.sort(key=lambda h: h.at)
    return hits, problems


# --------------------------------------------------------------------------------------
# Library
# --------------------------------------------------------------------------------------

class Library:
    """
    The recorded sounds, grouped by category from their filename prefix: `tap_01.wav`.

    Selection is deterministic and structurally cannot repeat: the next index is chosen from
    the *other* files only, so "the same tap never fires twice consecutively" is a property of
    the arithmetic rather than something to remember to check.
    """

    def __init__(self, root: Path | None = None):
        self.root = root or C.FOLEY
        self.sounds: dict[str, list[Path]] = {}
        if not self.root.exists():
            return
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in C.FOLEY_AUDIO_SUFFIXES:
                continue
            category = path.stem.split("_")[0].lower()
            if category in C.FOLEY_CATEGORIES:
                self.sounds.setdefault(category, []).append(path)

    @property
    def categories(self) -> set[str]:
        return set(self.sounds)

    def __len__(self) -> int:
        return sum(len(v) for v in self.sounds.values())

    def pick(self, category: str, previous: int | None, key: str) -> tuple[Path, int]:
        """
        Choose a sound, never the one just used.

        With `n` files the choice is `previous + 1 + hash % (n - 1)`, which walks the whole
        library over time while excluding the previous index by construction. A plain seeded
        random would repeat by chance — the same defect the font's ordered `calt` cycling
        exists to avoid, in a different medium.
        """
        files = self.sounds[category]
        if len(files) == 1:
            return files[0], 0
        if previous is None:
            index = int(SC._hash_unit(key, "foley") * len(files)) % len(files)
        else:
            step = 1 + int(SC._hash_unit(key, "foley") * (len(files) - 1)) % (len(files) - 1)
            index = (previous + step) % len(files)
        return files[index], index


# --------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------

def to_connected(hits: list[Hit]) -> list:
    """Foley as connected audio clips on the §8 Effects.Foley role, below the storyline."""
    import fcpxml as FX

    out = []
    for hit in hits:
        info = FX.probe(hit.sound)
        out.append(FX.Connected(
            asset_path=hit.sound,
            offset=hit.at,
            duration=info["duration"] or 0.2,
            name=hit.name,
            lane=C.LANE_FOLEY,
            role=C.ROLE_EFFECTS,
            audio=True,
        ))
    return out


def main(argv: list[str] | None = None) -> int:
    cli.preflight()
    ap = argparse.ArgumentParser(description="Place foley at each graphic's place-down frame")
    ap.add_argument("plan", nargs="?", help="build/plan/<project>.plan.json")
    ap.add_argument("--library", help="foley library directory (default assets/foley/)")
    ap.add_argument("--edl", help="rough-cut EDL, so hits land on the cut timeline")
    ap.add_argument("--project", default="video001")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    CR.gate()

    plan_path = (cli.resolve_or_exit(args.plan, expect=(".json",), label="plan") if args.plan
                 else next(iter(sorted(C.PLAN_DIR.glob("*.plan.json"))), None))
    if not plan_path or not plan_path.exists():
        print("! no plan found — run stage 3 first")
        return 1
    plan = json.loads(plan_path.read_text())

    library = Library(cli.resolve_or_exit(args.library, label="foley library").parent
                      if args.library and Path(args.library).is_file()
                      else (Path(args.library).expanduser() if args.library else None))
    if not len(library):
        # §8 wants foley on every placement, but its absence is missing *polish*, not a missing
        # graphic — so this reports and stops rather than blocking the whole handoff the way
        # [S-001] blocks a missing cutout.
        print(f"! no foley recorded in {library.root}")
        print("  §8: half an hour of table sounds — cardboard taps, paper slides, marker")
        print("  squeaks — buys more credibility than anything in the visual spec.")
        print(f"  Name them by category: {', '.join(C.FOLEY_CATEGORIES)} → tap_01.wav")
        return 1

    tmap = None
    if args.edl:
        import fcpxml as FX
        edl = json.loads(cli.resolve_or_exit(args.edl, expect=(".json",), label="EDL").read_text())
        tmap = FX.TimelineMap(edl["keeps"])

    hits, problems = hits_for_plan(plan, library, tmap)
    clock = SC.StepClock()
    print(f"Foley — {len(library)} sound(s) in {len(library.categories)} categor(y/ies), "
          f"contact at frame {contact_frame(clock)} of {C.PLACE_FRAMES[1]}")
    if tmap is None:
        print("  ! no --edl given, so hits are in SOURCE time and will land late on the cut")

    for hit in hits:
        print(f"  {hit.at:7.3f}s  {hit.cue_id:<6} {hit.category:<7} {hit.sound.name}")
    for problem in problems:
        print(f"  ! {problem}")

    if not hits:
        print("  no graphic placements to sound")
        return 1
    if args.dry_run:
        print(f"\n  [dry run] {len(hits)} hit(s)")
        return 0

    out = C.PLAN_DIR / f"{args.project}.foley.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({
        "project": args.project,
        "contact_frame": contact_frame(clock),
        "hits": [{"cue": h.cue_id, "at": h.at, "category": h.category,
                  "sound": str(h.sound)} for h in hits],
    }, indent=2))
    print(f"\n  {len(hits)} hit(s) → {C.path_label(out)}")
    return 0 if not problems else 1


if __name__ == "__main__":
    raise SystemExit(main())
