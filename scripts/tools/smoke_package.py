"""
smoke_package.py — build a self-contained package to import into a real Final Cut.

    python scripts/tools/smoke_package.py --out build/smoke
    # then in FCP: File ▸ Import ▸ XML…  (once per aspect)

The FCPXML contract is the one part of this pipeline no unit test can fully close. The DTD
check in `fcpxml.validate()` covers the *schema* — and it earned its place immediately, catching
a `role` attribute that FCP has no declaration for — but Final Cut also applies semantic rules a
DTD cannot express: whether a format name resolves, whether media comes in online, whether it
silently conforms a timebase.

So this builds everything an import needs, from the real code paths rather than from
hand-written XML: footage at 24000/1001, graphic layers rendered through `stage5.render_cue`
and encoded as ProRes 4444 with alpha, both aspects, plus markers, chapter markers and an
`.itt`. Times are chosen so a failure is *visible*: the connected clips sit at 1.5 s, 4.25 s and
6.75 s, inside three different parent clips, because everything landing at zero is exactly what
a parent-local offset bug looks like.

What to check after importing, in the inspector rather than by eye — the first is the one that
matters most, because if Final Cut conforms the timebase nothing downstream says so:

  1. Project timebase reads 23.98, never 24.
  2. Both aspects import at all. 9:16 uses `FFVideoFormatRateUndefined`, which is inferred from
     Apple's documented pattern for non-standard sizes rather than observed, so it is the
     likeliest rejection in the whole document.
  3. Connected clips sit at 1.5 s / 4.25 s / 6.75 s, not stacked at zero.
  4. Graphics show transparency, not black boxes — ProRes 4444 alpha surviving the round trip.
  5. Media is online, with no red missing-file placeholders — the `file://` URLs the DTD cannot
     check.
  6. Markers and chapter markers appear, and the `.itt` imports as captions in sync.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli
import config as C          # noqa: E402
import fcpxml as FX         # noqa: E402
import stepclock as SC      # noqa: E402

# Deliberately awkward positions: each connected clip lands inside a different parent clip, so
# the parent-local offset arithmetic is exercised rather than accidentally satisfied by a
# single-clip timeline where local and timeline time are identical.
CUTS = [(0.0, 0.0, 3.0), (3.0, 5.0, 3.0), (6.0, 9.0, 2.5)]      # offset, source in, duration
GRAPHICS = [(1.5, 2.0, "c001 thermal death point"),
            (4.25, 2.0, "c002 proofing window"),
            (6.75, 1.5, "c003 fermentation")]
MARKERS = [(0.75, "BROLL: bubbles rising in the starter"),
           (4.0, "MACRO: dead starter, no bubbles"),
           (7.0, "CAM: push in to B camera")]
CHAPTERS = [(0.0, "The temperature mistake"), (3.0, "What actually works"),
            (6.0, "Proof by volume")]


def render_footage(dest: Path, size: str, seconds: float = 12.0) -> Path:
    """Stand-in footage at exactly 24000/1001 — never a float rate ([S-007])."""
    subprocess.run([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", f"testsrc2=size={size}:rate={C.FPS_STR}:duration={seconds}",
        "-f", "lavfi", "-i", f"sine=frequency=220:sample_rate=48000:duration={seconds}",
        "-c:v", "libx264", "-crf", "24", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        "-r", C.FPS_STR, "-c:a", "aac", "-shortest", str(dest),
    ], check=True)
    return dest


def render_graphic(work: Path, aspect: str, tag: str) -> Path:
    """
    A graphic layer through the real Stage 5 path, so what gets imported is what ships.

    Hand-rolling a ProRes file here would test ffmpeg rather than the pipeline, and alpha
    surviving the round trip is one of the things the import is meant to prove.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tests"))
    import fixtures as FIX
    import stage5_composite as S5
    from PIL import Image

    cutouts = work / "cutouts"
    FIX.write_cutout_set(cutouts, keys=("yeast_cell", "thermometer"), variants=5)
    C.CUTOUTS = cutouts
    C.ROOT = work

    grain = Image.open(FIX.write_grain(work / "grain.png", size=(480, 270))).convert("RGB")
    seq = S5.render_cue(
        {"id": f"c001_{tag}", "assets": ["cutout:yeast_cell", "cutout:thermometer"], "hold": 2.5},
        aspect, work / "frames", SC.StepClock(), grain.resize(C.ASPECTS[aspect]["author"]),
    )
    return S5.encode_sequence(seq, work / f"graphic_{tag}.mov")


def build(out: Path) -> int:
    out.mkdir(parents=True, exist_ok=True)
    problems = 0

    for aspect, tag, size in (("16:9", "169", "1920x1080"), ("9:16", "916", "1080x1920")):
        src = render_footage(out / f"a-cam_{tag}.mp4", size)
        mov = render_graphic(out, aspect, tag)

        clips = [FX.Clip(asset_path=src, offset=o, start=s, duration=d,
                         name=f"{tag} seg {i + 1:02d}")
                 for i, (o, s, d) in enumerate(CUTS)]
        for at, text in MARKERS:
            for clip in clips:
                if clip.offset <= at < clip.offset + clip.duration:
                    clip.markers.append((at, text, True))
                    break
        connected = [FX.Connected(asset_path=mov, offset=o, duration=d, name=n)
                     for o, d, n in GRAPHICS]

        builder = FX.FCPXMLBuilder(project=f"smoke {aspect}", aspect=aspect)
        path = builder.write(builder.build(clips, connected, CHAPTERS),
                             out / f"smoke_{tag}.fcpxml")

        hand = FX.validate(path)
        schema = FX.dtd_problems(path)
        print(f"{aspect}  {path.name}")
        print(f"   format name : {C.ASPECTS[aspect]['fcp_format_name']}")
        print(f"   validate()  : {hand or 'clean'}")
        print(f"   FCP schema  : {'not installed' if schema is None else (schema or 'clean')}")
        problems += len(hand) + len(schema or [])

    words_path = out / "smoke.itt"
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tests"))
    import fixtures as FIX
    FX.build_itt(FIX.build_words(), words_path)
    print(f"\ncaptions  {words_path.name}")

    print("\nIn Final Cut: File ▸ Import ▸ XML… once per aspect, then check")
    print("  1. timebase reads 23.98, not 24          4. graphics are transparent, not black")
    print("  2. both aspects import                    5. media online, no red placeholders")
    print("  3. graphics at 1.5 / 4.25 / 6.75 s        6. markers, chapters, captions present")
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    cli.preflight(('numpy', 'PIL'))
    ap = argparse.ArgumentParser(description="Build an FCP import smoke-test package")
    ap.add_argument("--out", type=Path, default=C.BUILD / "smoke")
    return build(ap.parse_args(argv).out)


if __name__ == "__main__":
    raise SystemExit(main())
