"""
tests/fixtures.py — synthetic inputs for the test suite.

Everything built here is a **stand-in**, and none of it is ever written into `assets/`.
That distinction matters: taste_principles §0.1 and style_guide [S-001] forbid generated
texture *on screen*. They govern what reaches the video, not what a test hands a function.
A generated blob standing in for a scanned cutout exercises `render_cue()` exactly as well
as her real artwork does, and it lets the suite run on a machine with no asset library.

The narration in `NARRATION` is the single source of truth: the transcript and the annotated
script are both derived from it, so anchors resolve the way they do in a real run instead of
by coincidence.

All randomness is seeded from `config.SEED`, per the determinism convention in CLAUDE.md.
"""

from __future__ import annotations

import json
import random
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

import config as C


# --------------------------------------------------------------------------------------
# Narration — the source both the transcript and the script are generated from
# --------------------------------------------------------------------------------------

@dataclass
class Beat:
    """One spoken run, plus whatever annotation sits after it in the script."""
    text: str
    gap_before: float = 0.30
    cue: str = ""                  # inline marker emitted after this beat
    heading: str = ""              # markdown heading emitted *before* this beat
    fenced: bool = False           # emit a fenced code block before this beat
    in_script: bool = True         # False = spoken but not scripted (a stumbled take)
    tag: str = ""                  # handle for tests to find this beat's words


# Gaps are chosen deliberately:
#   < 400 ms  (MIN_SILENCE_TO_CUT_MS) — left completely alone by Stage 2
#   > 400 ms                          — trimmed toward the breath floor, never past it
#   > 1.0 s                           — also a sentence boundary for group_sentences()
NARRATION: list[Beat] = [
    Beat("Most home bakers kill their yeast before it ever gets started.",
         gap_before=0.50, tag="hook",
         cue='[[CHAPTER: chapter_card | text="The temperature mistake"]]'),

    # 1.6 s of dead air after a sentence end -> paragraph breath (250 ms)
    Beat("The water is simply too hot.", gap_before=1.60, tag="too_hot"),

    # An isolated filler: > 120 ms of gap on both sides, so Stage 2 can excise it cleanly.
    Beat("Um", gap_before=0.55, in_script=False, tag="filler_um"),

    # A stumbled take, then the clean one. Stage 2 must keep the LATER of the two.
    Beat("Yeast is a living organism and, uh, heat kills it stone dead.",
         gap_before=0.42, in_script=False, tag="take_bad"),
    Beat("Yeast is a living organism and heat kills it stone dead.",
         gap_before=0.95, tag="take_good",
         cue='[[GFX: key_term | text="Thermal death point" | asset=cutout:yeast_cell]]'),

    Beat("Above forty six degrees the cell walls rupture.",
         gap_before=0.62, tag="rupture",
         cue='[[MACRO: bubbles rising through a warm starter]]'),

    Beat("So the starter never wakes up and the loaf stays flat.",
         gap_before=0.44, tag="flat",
         cue='[[BROLL: the dense under proofed loaf cut open on the board]]'),

    # Heading immediately before the marker — the anchor must not pick up its words.
    Beat("Blood warm is the whole trick, nothing more than that.",
         gap_before=1.30, tag="blood_warm",
         heading="## What actually works",
         cue='[[GFX: gauge | text="Proofing window" | asset=cutout:thermometer]]'),

    Beat("Proof it between twenty four and twenty eight degrees.",
         gap_before=0.52, tag="proof_window",
         cue='[[CAM: push in to the B camera for the pour]]'),

    # A fenced block before the marker — must not pollute the anchor either.
    Beat("Give it ninety minutes and watch the volume, never the clock.",
         gap_before=0.66, tag="ninety",
         fenced=True,
         cue='[[VO: this line is read over the timelapse]]'),

    Beat("That is the entire difference between a brick and a loaf.",
         gap_before=0.48, tag="difference",
         cue='[[NOTE: check the exact rupture temperature with her before locking this]]'),
]


# --------------------------------------------------------------------------------------
# Transcript
# --------------------------------------------------------------------------------------

def build_words(narration: list[Beat] | None = None, *, seed: int = C.SEED) -> list[dict]:
    """
    Word-level timings in the WhisperX shape Stage 1 emits: {word, start, end, score}.

    Word durations vary slightly so the fixture doesn't accidentally satisfy an invariant
    through perfect regularity — the same reason §2.3 exists for the artwork.
    """
    rng = random.Random(seed)
    words: list[dict] = []
    t = 0.0
    for beat in narration or NARRATION:
        t += beat.gap_before
        tokens = beat.text.split()
        for i, tok in enumerate(tokens):
            dur = 0.16 + 0.020 * len(tok) + rng.uniform(-0.02, 0.02)
            words.append({
                "word": tok,
                "start": round(t, 3),
                "end": round(t + dur, 3),
                "score": round(rng.uniform(0.86, 0.99), 3),
                "beat": beat.tag,          # test-only handle, ignored by every stage
            })
            t += dur
            if i < len(tokens) - 1:
                t += 0.055 + rng.uniform(0.0, 0.02)     # intra-phrase gap, well under the floor
    return words


def words_for(words: list[dict], tag: str) -> list[dict]:
    """Every word belonging to one narration beat."""
    return [w for w in words if w.get("beat") == tag]


def span_of(words: list[dict], tag: str) -> tuple[float, float]:
    """(start, end) of one narration beat in source time."""
    hits = words_for(words, tag)
    if not hits:
        raise KeyError(f"no beat tagged {tag!r}")
    return hits[0]["start"], hits[-1]["end"]


def write_transcript(dest: Path, *, clip: str = "a-cam_001",
                     source: str = "footage/a-cam/a-cam_001.mov") -> Path:
    """A `*.words.json` in the shape Stage 2 and Stage 3 read."""
    words = build_words()
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps({
        "clip": clip,
        "source": source,
        "language": "en",
        "duration": round(max(w["end"] for w in words) + 0.5, 3),
        "words": words,
    }, indent=2))
    return dest


# --------------------------------------------------------------------------------------
# Annotated script
# --------------------------------------------------------------------------------------

def build_script_md(narration: list[Beat] | None = None) -> str:
    """
    The annotated markdown Stage 3 parses — every cue kind in VALID_KINDS appears at least
    once, and headings and fenced blocks sit next to markers so the anchor cleaning is
    actually exercised rather than assumed.
    """
    out: list[str] = ["# Yeast — the chemistry home bakers miss", ""]
    for beat in narration or NARRATION:
        if not beat.in_script:
            continue
        if beat.heading:
            out += [beat.heading, ""]
        if beat.fenced:
            out += ["```", "shot note: locked off, 100mm macro, no marker in frame", "```", ""]
        out.append(beat.text)
        if beat.cue:
            out.append(beat.cue)
        out.append("")
    return "\n".join(out)


def write_script_md(dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(build_script_md(), encoding="utf-8")
    return dest


# --------------------------------------------------------------------------------------
# Cutouts
# --------------------------------------------------------------------------------------

# Stand-in cutouts are built from palette colours on purpose. A fixture carrying a stray
# #000000 would make the §12 check-9 test pass or fail for reasons that have nothing to do
# with the compositor.
_CUTOUT_FILLS = ("kraft", "oat", "sage", "moss", "stone")


def _hex_rgb(name: str) -> tuple[int, int, int]:
    h = C.PALETTE[name].lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def make_cutout(dest: Path, key: str, variant: str, *, size: tuple[int, int] = (1200, 900),
                fill: str = "kraft", seed: int = C.SEED) -> Path:
    """
    One stand-in cutout: an irregular blob with a genuinely ragged alpha edge.

    The edge irregularity is the point. `fit_to_slot`, `contact_shadow` and `apply_transform`
    all behave differently on a clean rectangle than on a torn one, and §1.3's "preserve
    fibre" rule means the real inputs will never be rectangles.
    """
    from PIL import Image, ImageDraw, ImageFilter

    rng = random.Random(f"{seed}:{key}:{variant}")
    w, h = size
    cx, cy = w / 2, h / 2

    # Ragged outline: a many-sided polygon with per-vertex radius jitter, so the edge has
    # the small-scale noise a cut or torn edge has.
    points: list[tuple[float, float]] = []
    steps = 96
    for i in range(steps):
        ang = 2 * 3.141592653589793 * i / steps
        rx, ry = w * 0.42, h * 0.42
        wobble = 1.0 + rng.uniform(-0.075, 0.075)
        points.append((cx + rx * wobble * _cos(ang), cy + ry * wobble * _sin(ang)))

    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    # §1.3 — 1–2 px feather. A 0 px matte gives the vector-crisp edge we are avoiding.
    mask = mask.filter(ImageFilter.GaussianBlur(1.4))

    r, g, b = _hex_rgb(fill)
    sprite = Image.new("RGBA", size, (r, g, b, 0))
    # Mottle the fill so the cutout is not a flat colour field — flat fills are §10-banned,
    # and a flat sprite would hide any frame-to-frame delta bug in the hold test.
    px = sprite.load()
    for y in range(0, h, 3):
        for x in range(0, w, 3):
            d = rng.randint(-10, 10)
            for yy in range(y, min(y + 3, h)):
                for xx in range(x, min(x + 3, w)):
                    px[xx, yy] = (max(1, min(254, r + d)), max(1, min(254, g + d)),
                                  max(1, min(254, b + d)), 0)
    sprite.putalpha(mask)
    dest.parent.mkdir(parents=True, exist_ok=True)
    sprite.save(dest)
    return dest


def _cos(a: float) -> float:
    import math
    return math.cos(a)


def _sin(a: float) -> float:
    import math
    return math.sin(a)


def write_cutout_set(cutouts_dir: Path, keys: tuple[str, ...] = ("yeast_cell", "thermometer"),
                     variants: int = 5) -> dict[str, list[Path]]:
    """
    Five variants per key, per §1.2 — she shoots every piece 4–6 times and the variant cycle
    in `stepclock.variant_for` walks them. Naming follows §1.3: `<key>_v01_<a-f>.png`.
    """
    made: dict[str, list[Path]] = {}
    for i, key in enumerate(keys):
        made[key] = [
            make_cutout(cutouts_dir / f"{key}_v01_{chr(ord('a') + v)}.png", key,
                        chr(ord("a") + v), fill=_CUTOUT_FILLS[(i + v) % len(_CUTOUT_FILLS)])
            for v in range(variants)
        ]
    return made


# --------------------------------------------------------------------------------------
# Paper grain
# --------------------------------------------------------------------------------------

def write_grain(dest: Path, size: tuple[int, int] = (1920, 1080), *, seed: int = C.SEED) -> Path:
    """
    Stand-in for the flat-scanned paper grain of §4.3.

    Values stay in 205–255 because that is what a real flat scan of blank paper measures.
    It also keeps the multiply blend from driving a composited pixel to #000000, which would
    trip §12 check 9 for a reason that is about the fixture rather than the pipeline.
    """
    from PIL import Image

    rng = random.Random(seed)
    img = Image.new("RGB", size)
    px = img.load()
    w, h = size
    for y in range(h):
        for x in range(w):
            v = rng.randint(205, 255)
            px[x, y] = (v, v, max(200, v - 4))      # very slightly warm, never neutral grey
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest)
    return dest


# --------------------------------------------------------------------------------------
# Capture sheets
# --------------------------------------------------------------------------------------

SEAMLESS_VALUE = 0.46
# How far the fixture's contact shadow darkens the backdrop. She records the deepest shadow off
# the grey-card frame; here the number is known exactly, which is what lets the [S-014] test
# distinguish "darker than any shadow" from "dark piece" on real arithmetic rather than a guess.
SHADOW_DARKENING = 0.22

# A near-neutral dark piece: grey chipboard, a charcoal card, heavy walnut fill. Placed almost
# exactly on the backdrop ray, which is the dangerous case — it is invisible to a chroma test
# and reads as very deep shadow to a ray test with no floor.
CHIPBOARD_K = 0.39


def write_sheet(dest: Path, pieces: tuple[str, ...] = ("kraft", "sage"), *,
                piece_size: tuple[int, int] = (3000, 2200), gap: int = 300,
                cast: tuple[float, float, float] = (1.06, 1.0, 0.90),
                seed: int = C.SEED) -> Path:
    """
    A stand-in for one of her overhead sheet photographs: several ragged pieces laid out on a
    neutral mid-grey seamless, under a warm light cast.

    Three details make it a real test rather than a shape on a background. The pieces are
    **larger than the §1.2 floor** so they survive the resolution gate. They carry the same
    ragged, feathered edges `make_cutout` produces, so the matte has actual fibre to preserve
    or destroy. And the whole frame is multiplied by a colour cast, so the white-balance step
    has something to correct — a perfectly neutral fixture would let a broken balance pass.
    """
    from PIL import Image

    rng = random.Random(seed)
    pw, ph = piece_size
    w = gap + len(pieces) * (pw + gap)
    h = ph + gap * 2

    # Mid-grey seamless, with the low-frequency unevenness real lighting always has.
    canvas = np.full((h, w, 3), SEAMLESS_VALUE, dtype=np.float32)
    yy, xx = np.mgrid[0:h, 0:w]
    canvas *= (1.0 + 0.02 * np.sin(xx / (w / 3.0)) + 0.015 * np.cos(yy / (h / 2.0)))[..., None]
    blotches = np.asarray(
        [[[rng.uniform(-0.004, 0.004) for _ in range(3)] for _ in range(8)] for _ in range(8)],
        dtype=np.float32,
    )
    canvas += blotches.repeat(h // 8 + 1, axis=0)[:h].repeat(w // 8 + 1, axis=1)[:, :w]

    tmp = dest.parent / "_piece.png"
    for i, fill in enumerate(pieces):
        make_cutout(tmp, f"sheet-{fill}", chr(ord("a") + i), size=piece_size,
                    fill=fill if fill in C.PALETTE else "kraft", seed=seed + i)
        with Image.open(tmp) as im:
            arr = np.asarray(im.convert("RGBA"), dtype=np.float32) / 255.0
        if fill == "chipboard":
            # Repaint on the backdrop ray: same hue as the seamless, far darker than any
            # shadow it can cast. Chroma cannot see it; a ray test without a floor eats it.
            arr[..., :3] = np.full(3, SEAMLESS_VALUE, dtype=np.float32) * CHIPBOARD_K
        x0, y0 = gap + i * (pw + gap), gap
        region = canvas[y0:y0 + ph, x0:x0 + pw]
        a = arr[..., 3:4]
        # Contact shadow from the ~10 mm foam-tape lift in §1.2, so the border median that
        # estimates the background has something to be robust against.
        shadow = np.clip(a[..., 0], 0, 1)
        shadow = np.roll(np.roll(shadow, 26, axis=0), 22, axis=1) * SHADOW_DARKENING
        region *= (1.0 - shadow)[..., None]
        canvas[y0:y0 + ph, x0:x0 + pw] = arr[..., :3] * a + region * (1 - a)
    tmp.unlink(missing_ok=True)

    canvas *= np.asarray(cast, dtype=np.float32)
    dest.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(
        np.rint(np.clip(canvas, 0, 1) * 255).astype(np.uint8), "RGB"
    ).save(dest, quality=95)

    # [S-013] — the seamless value is measured, not inferred. In production it comes off the
    # session's grey-card frame; here it comes from the value the sheet was built with, which
    # is the same thing: a number that did not come from the pixels being matted.
    seamless = [SEAMLESS_VALUE * c for c in cast]
    dest.with_suffix(".capture.json").write_text(json.dumps({
        "seamless": [round(v, 6) for v in seamless],
        # The deepest shadow a piece on foam tape casts under this lighting. [S-014] floors the
        # backdrop ray here, so anything darker is a piece rather than shade.
        "deepest_shadow": [round(v * (1.0 - SHADOW_DARKENING), 6) for v in seamless],
    }, indent=2) + "\n")
    return dest


def write_glyph_grid(dest: Path, rows: int = 3, cols: int = 4, *,
                     cell: int = 200, seed: int = C.SEED) -> Path:
    """
    A stand-in for a 1200 dpi glyph sheet: a grid of ink marks on paper white.

    Each cell holds two disjoint strokes, which is the case `find_cells` exists for — a glyph
    is routinely several separate marks, and connected-component labelling would file each
    stroke as its own glyph.
    """
    from PIL import Image, ImageDraw

    rng = random.Random(seed)
    pad = 40
    img = Image.new("L", (cols * cell + pad * 2, rows * cell + pad * 2), 245)
    draw = ImageDraw.Draw(img)
    for r in range(rows):
        for c in range(cols):
            cx = pad + c * cell + cell // 2
            cy = pad + r * cell + cell // 2
            for dx in (-cell // 6, cell // 6):      # two disjoint strokes per cell
                jitter = rng.randint(-4, 4)
                draw.line(
                    [(cx + dx + jitter, cy - cell // 4), (cx + dx, cy + cell // 4)],
                    fill=30, width=9,
                )
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest)
    return dest


def write_marker_sheet(dest: Path, char: str = "e", versions: int = 6, *,
                       cols: int = 3, cell: int = 240, seed: int = C.SEED) -> Path:
    """
    A stand-in for one of her 1200 dpi glyph sheets: N hand-drawn versions of one character,
    on a regular grid.

    Every version is deliberately *different* — stroke endpoints, thickness and the position of
    a marker skip all vary per cell. That is the property the whole font depends on, and a
    fixture drawing the same shape N times would let a broken `calt` pass its acceptance test
    while proving nothing.

    Drawn with a consistent baseline across cells, because that is what her ruled sheet gives
    and what `regular_grid` exists to recover.
    """
    from PIL import Image, ImageDraw

    rng = random.Random(f"{seed}:{char}")
    rows = (versions + cols - 1) // cols
    pad = cell // 3
    img = Image.new("L", (cols * cell + pad * 2, rows * cell + pad * 2), 248)
    draw = ImageDraw.Draw(img)

    for v in range(versions):
        r, c = divmod(v, cols)
        x0 = pad + c * cell
        y0 = pad + r * cell
        # A consistent baseline and x-height per cell — the ruled sheet's job.
        base = y0 + int(cell * 0.78)
        top = y0 + int(cell * 0.34)
        w = cell // 2
        cx = x0 + cell // 2

        wob = lambda a: rng.randint(-a, a)      # noqa: E731 — per-version hand wobble
        weight = rng.randint(11, 16)

        # A crude two-stroke letterform: a bowl and a crossbar, both wobbling per version.
        draw.arc(
            [cx - w // 2 + wob(5), top + wob(5), cx + w // 2 + wob(5), base + wob(4)],
            start=rng.randint(15, 45), end=rng.randint(300, 340), fill=35, width=weight,
        )
        draw.line(
            [(cx - w // 2 + wob(6), (top + base) // 2 + wob(6)),
             (cx + w // 2 + wob(6), (top + base) // 2 + wob(6))],
            fill=35, width=weight,
        )
        # A marker skip: a small gap punched through a stroke, as a real pen leaves.
        sx = cx + wob(w // 2)
        sy = (top + base) // 2 + wob(8)
        draw.ellipse([sx - 4, sy - weight, sx + 4, sy + weight], fill=248)

    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest)
    return dest


def write_foley_library(dest: Path, counts: dict[str, int] | None = None) -> Path:
    """
    A stand-in foley library: short synthesised clicks, one file per take.

    Stands in for the half hour of real table sounds §8 asks for. Each file differs in pitch
    and decay so a repeated selection is *audible* in a test rather than merely equal — a
    library of identical files would let a broken variation selector pass.
    """
    counts = counts or {"tap": 5, "slide": 3, "squeak": 2}
    dest.mkdir(parents=True, exist_ok=True)
    for category, n in counts.items():
        for i in range(1, n + 1):
            freq = 180 + 90 * i + (37 if category == "squeak" else 0)
            decay = 0.06 + 0.02 * i
            subprocess.run([
                "ffmpeg", "-y", "-v", "error",
                "-f", "lavfi", "-i", f"sine=frequency={freq}:duration={decay}",
                "-af", f"afade=t=out:st=0:d={decay}",
                str(dest / f"{category}_{i:02d}.wav"),
            ], check=True)
    return dest


# --------------------------------------------------------------------------------------
# Synthetic footage
# --------------------------------------------------------------------------------------

def write_video(dest: Path, seconds: float = 8.0) -> Path:
    """
    A short clip at exactly 24000/1001, with audio.

    Not a float. Passing `-r 23.976` writes a 23976/1000 timebase, every FCPXML time lands
    off the frame grid, and Final Cut shifts clips by a frame — style_guide [S-007].
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", f"testsrc2=size=1920x1080:rate={C.FPS_STR}:duration={seconds}",
        "-f", "lavfi", "-i", f"sine=frequency=220:sample_rate=48000:duration={seconds}",
        "-c:v", "libx264", "-crf", "28", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-r", C.FPS_STR,
        "-c:a", "aac", "-b:a", "128k",
        "-shortest", str(dest),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"fixture video render failed:\n{proc.stderr[-800:]}")
    return dest
