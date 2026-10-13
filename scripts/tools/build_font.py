"""
build_font.py — scanned glyph sheets → HerMarker.woff2, with `calt` wired up.

    python scripts/tools/build_font.py sheets/e_v01-20.png --glyph e --min-gap 90
    python scripts/tools/build_font.py sheets/*.png --manifest sheets/glyphs.json

She is lettering ~1,320 glyphs (`font_character_set.md`), so nothing here can require a
per-glyph decision. One sheet is one character's versions, laid out on a ruled grid.

Two things decide whether this reads as handwriting or as a font, and both are easy to get
subtly wrong:

**The outlines are not smoothed.** `font_character_set.md` and taste_principles §3.2 both say
it outright — the wobble, the bleed and the marker skips are the value. `trace.py` only ever
removes points already lying within tolerance of the line through them, and the tolerance is
exposed in *font units* so it means the same thing at any scan resolution.

**The alternates cycle in order, not at random.** Random selection repeats by chance, which is
the exact artifact the alternates exist to prevent — with 20 drawings a random pick shows a
visible repeat every few words. The `calt` feature below advances one step per glyph position,
so a letter cannot repeat until the whole cycle has run. See style_guide [S-004].

Deviation from `HANDOFF_claude_code.md` item 1, stated rather than buried: the handoff says
"assemble a UFO with fontTools/fontmake". This builds the TTF directly with
`fontTools.fontBuilder`. `ufo2ft`, `defcon` and `fontmake` are not installed and would add four
dependencies to produce an intermediate nothing else consumes — and the usual reason to want a
UFO, hand-editing outlines, is a thing this font must not do.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import cli
import config as C          # noqa: E402
import sheet as S           # noqa: E402
import trace as T           # noqa: E402


UPM = 1000

# §3.2 — "Loose spacing. Hand block lettering is not tightly kerned. Set generous sidebearings
# and kern only the pairs that actually collide. Over-kerning makes it look like a font."
DEFAULT_SIDEBEARING = 0.055        # of the em

# Where the baseline sits inside a ruled cell, as a fraction from the top. The real value comes
# off her test sheet; this is a placeholder that keeps every alternate of a letter consistent
# with every other, which is the part that actually matters before the sheet exists.
DEFAULT_BASELINE = 0.78

# Simplification tolerance in font units, so it means the same thing whatever the scan
# resolution. 1.5/1000 em is ~0.2 px on a 120 px marker headline — well under anything visible,
# and far below the amplitude of a real marker wobble.
DEFAULT_TOLERANCE_UNITS = 1.5

# Ink threshold on a 0–1 luminance sheet. Applied after loading, never baked into the scan:
# font_character_set.md wants "bitonal threshold after review, never before".
DEFAULT_INK_THRESHOLD = 0.55


@dataclass
class Drawing:
    """One drawn version of one character."""
    char: str
    index: int
    contours: list[list[tuple[float, float]]]
    advance: int

    @property
    def name(self) -> str:
        base = glyph_name(self.char)
        return base if self.index == 0 else f"{base}.alt{self.index:02d}"


def glyph_name(char: str) -> str:
    """A legal, stable glyph name. Font formats will not take arbitrary characters."""
    if char.isascii() and char.isalpha():
        return f"{char}.uc" if char.isupper() else char
    if char.isascii() and char.isdigit():
        return "zero one two three four five six seven eight nine".split()[int(char)]
    return f"uni{ord(char):04X}"


# --------------------------------------------------------------------------------------
# Sheet -> drawings
# --------------------------------------------------------------------------------------

def regular_grid(spans: list[slice], extent: int) -> list[tuple[int, int]]:
    """
    Turn ink-hugging bands into evenly pitched cell boundaries.

    A cell that hugs its ink has thrown away where the baseline was, so every drawing would be
    normalised to its own bounding box and the alternates would sit at different heights — the
    line bounces, which is worse than any repeated glyph. Boundaries are placed midway between
    neighbouring bands, so each drawing keeps its true position inside its cell.
    """
    if not spans:
        return []
    if len(spans) == 1:
        return [(spans[0].start, spans[0].stop)]

    centres = [(s.start + s.stop) / 2 for s in spans]
    pitch = float(np.median(np.diff(centres)))
    edges = [centres[0] - pitch / 2]
    edges += [(a + b) / 2 for a, b in zip(centres, centres[1:])]
    edges += [centres[-1] + pitch / 2]
    return [(max(0, int(round(a))), min(extent, int(round(b))))
            for a, b in zip(edges, edges[1:])]


def read_sheet(path: Path, min_gap: int, threshold: float) -> tuple[np.ndarray, list, list]:
    """Load a glyph sheet and return its ink mask plus the regular cell grid."""
    grey = S.load_rgb(path).mean(axis=-1)
    ink = grey < threshold
    if not ink.any():
        raise SystemExit(f"! {path.name}: no ink found at threshold {threshold}. "
                         f"Sheet is blank, inverted, or the threshold needs raising.")
    rows, cols = S.find_grid(ink, min_gap)
    return ink, regular_grid(rows, ink.shape[0]), regular_grid(cols, ink.shape[1])


def drawings_from_sheet(path: Path, char: str, *, min_gap: int, threshold: float,
                        tolerance_units: float, baseline: float,
                        sidebearing: float) -> list[Drawing]:
    """
    Every version of one character on one sheet, in reading order.

    All cells share one scale factor, derived from the cell height, so alternates keep their
    relative size. Scaling each drawing to fill its own box would flatten exactly the variation
    §2.3 and the 20-versions exercise exist to preserve.
    """
    ink, row_cells, col_cells = read_sheet(path, min_gap, threshold)
    if not row_cells or not col_cells:
        raise SystemExit(f"! {path.name}: could not find a grid — try adjusting --min-gap")

    cell_h = float(np.median([b - a for a, b in row_cells]))
    scale = UPM / cell_h                       # font units per source pixel
    tolerance_px = tolerance_units / scale

    out: list[Drawing] = []
    for r0, r1 in row_cells:
        for c0, c1 in col_cells:
            cell = ink[r0:r1, c0:c1]
            if not cell.any():
                continue        # a short last row is normal; an empty cell is not a glyph
            contours = T.trace(cell, tolerance=tolerance_px)
            if not contours:
                continue

            baseline_px = r0 + baseline * (r1 - r0)
            placed = [
                [((c0 + x) * scale, (baseline_px - (r0 + y)) * scale) for x, y in contour]
                for contour in contours
            ]
            # Shift so the ink starts at the sidebearing rather than at the cell's left edge,
            # which is where the pencil grid happened to be.
            left = min(x for contour in placed for x, _ in contour)
            side = sidebearing * UPM
            placed = [[(x - left + side, y) for x, y in contour] for contour in placed]
            right = max(x for contour in placed for x, _ in contour)

            out.append(Drawing(char=char, index=len(out),
                               contours=[[(round(x), round(y)) for x, y in c] for c in placed],
                               advance=int(round(right + side))))
    return out


# --------------------------------------------------------------------------------------
# calt — ordered cycling
# --------------------------------------------------------------------------------------

def cycle_period(counts: list[int]) -> int:
    """
    A period that never lets a glyph repeat across the wrap.

    The cycle advances one step per glyph position and resets when a run ends. At the reset the
    previous position holds index `(P-1) % K` and the next holds 0, so a glyph with K versions
    repeats across that seam exactly when K divides P-1. Stepping P past those cases costs
    nothing and removes the one adjacency the scheme would otherwise miss.
    """
    usable = [k for k in counts if k > 1]
    if not usable:
        return 1
    period = max(usable)
    while any((period - 1) % k == 0 for k in usable):
        period += 1
    return period


def build_calt(drawings: dict[str, list[Drawing]]) -> tuple[str, int]:
    """
    A `calt` feature that walks the alternates in order.

    Each class holds one form per character: `@CYC3` is every character's fourth drawing, or
    its `3 % K`th where it has fewer. One rule per step advances a glyph whose predecessor sat
    at step i to step i+1, so the index depends on *position in the run*, not on which letter it
    is — which is what makes `SUCCESS` come out with four different `S`s.

    There is deliberately no rule for the last step. Its absence is the wrap: nothing matches,
    the glyph stays at step 0, and the run starts over.
    """
    cycling = {ch: ds for ch, ds in drawings.items() if len(ds) > 1}
    if not cycling:
        return "", 1

    chars = sorted(cycling)
    period = cycle_period([len(cycling[ch]) for ch in chars])

    lines = ["languagesystem DFLT dflt;", "languagesystem latn dflt;", ""]
    for step in range(period):
        names = [cycling[ch][step % len(cycling[ch])].name for ch in chars]
        lines.append(f"@CYC{step} = [{' '.join(names)}];")
    lines.append("")

    for step in range(1, period):
        lines.append(f"lookup step{step} {{")
        lines.append(f"    sub @CYC0 by @CYC{step};")
        lines.append(f"}} step{step};")
    lines.append("")

    lines.append("feature calt {")
    for step in range(period - 1):
        lines.append(f"    sub @CYC{step} @CYC0' lookup step{step + 1};")
    lines.append("} calt;")
    return "\n".join(lines) + "\n", period


# --------------------------------------------------------------------------------------
# Kerning
# --------------------------------------------------------------------------------------

def build_kern(drawings: dict[str, list[Drawing]], pairs: dict[str, int]) -> tuple[str, list[str]]:
    """
    Compile the checked-in kerning table into a `kern` feature.

    Kerning lives in a data file rather than in a font editor, because there is no editor in
    this pipeline: scans compile straight to woff2, and a hand-edited source could not be
    regenerated from the scans (`font_character_set.md`, "Build outputs"). Keeping it as data
    means the font stays a pure function of the drawings plus this file.

    Each pair is emitted against *every* alternate of both characters, so one entry covers all
    400 combinations of a 20x20 pair. That is the only sane way to kern a font whose glyphs
    each have twenty forms.

    Returns the feature source and any pairs that referenced characters not yet drawn — those
    are reported rather than dropped silently, since the usual cause is a typo in the data file.
    """
    if not pairs:
        return "", []

    lines, unknown = [], []
    rules = []
    for pair, value in sorted(pairs.items()):
        if len(pair) != 2:
            unknown.append(f"{pair!r} (not a two-character pair)")
            continue
        left, right = pair[0], pair[1]
        if left not in drawings or right not in drawings:
            missing = [c for c in (left, right) if c not in drawings]
            unknown.append(f"{pair!r} (no drawings for {', '.join(map(repr, missing))})")
            continue
        lhs = " ".join(d.name for d in drawings[left])
        rhs = " ".join(d.name for d in drawings[right])
        rules.append(f"    pos [{lhs}] [{rhs}] {int(value)};")

    if not rules:
        return "", unknown

    lines.append("feature kern {")
    lines.extend(rules)
    lines.append("} kern;")
    return "\n".join(lines) + "\n", unknown


def load_kerning(path: Path | None) -> dict[str, int]:
    """
    Read the kerning data file. Absent is legitimate — §3.2 only wants the pairs that actually
    collide, and early in the alphabet there may be none worth setting.
    """
    if path is None or not path.exists():
        return {}
    data = json.loads(path.read_text())
    pairs = data.get("pairs", data) if isinstance(data, dict) else {}
    return {k: int(v) for k, v in pairs.items() if not k.startswith("_")}


# --------------------------------------------------------------------------------------
# Font assembly
# --------------------------------------------------------------------------------------

def build_font(drawings: dict[str, list[Drawing]], family: str) -> "object":
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen

    flat = [d for ds in drawings.values() for d in ds]
    order = [".notdef"] + [d.name for d in flat]

    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({ord(ch): ds[0].name for ch, ds in drawings.items()})

    glyphs, metrics = {}, {".notdef": (int(UPM * 0.4), 0)}
    pen = TTGlyphPen(None)
    glyphs[".notdef"] = pen.glyph()

    for d in flat:
        pen = TTGlyphPen(None)
        for contour in d.contours:
            pen.moveTo(contour[0])
            for point in contour[1:]:
                pen.lineTo(point)
            pen.closePath()
        glyphs[d.name] = pen.glyph()
        left = min((x for c in d.contours for x, _ in c), default=0)
        metrics[d.name] = (d.advance, int(left))

    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)

    ascent, descent = int(UPM * 0.80), int(UPM * 0.20)
    fb.setupHorizontalHeader(ascent=ascent, descent=-descent, lineGap=int(UPM * 0.12))
    fb.setupNameTable({
        "familyName": family,
        "styleName": "Regular",
        "uniqueFontIdentifier": f"{family};handmade-pipeline",
        "fullName": family,
        "psName": family.replace(" ", ""),
        "version": "Version 1.000",
    })
    fb.setupOS2(sTypoAscender=ascent, sTypoDescender=-descent, usWinAscent=ascent,
                usWinDescent=descent, sxHeight=int(UPM * 0.52), sCapHeight=int(UPM * 0.72),
                fsType=0)
    fb.setupPost(isFixedPitch=0)
    return fb


def compile_font(fb, feature_code: str, out_ttf: Path, out_woff2: Path) -> None:
    from fontTools.feaLib.builder import addOpenTypeFeaturesFromString

    if feature_code:
        addOpenTypeFeaturesFromString(fb.font, feature_code)

    out_ttf.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(out_ttf))

    fb.font.flavor = "woff2"
    fb.font.save(str(out_woff2))


# --------------------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------------------

def collect(sheets: list[Path], chars: list[str], **kw) -> dict[str, list[Drawing]]:
    drawings: dict[str, list[Drawing]] = {}
    for path, char in zip(sheets, chars):
        found = drawings_from_sheet(path, char, **kw)
        if not found:
            print(f"  ! {path.name}: no drawings found")
            continue
        drawings.setdefault(char, []).extend(found)
        print(f"  {path.name}: {len(found)} version(s) of {char!r}, "
              f"{sum(len(c) for d in found for c in d.contours)} points total")
    # Re-index after merging sheets so alt numbering is contiguous per character.
    for char, ds in drawings.items():
        for i, d in enumerate(ds):
            d.index = i
    return drawings


def main(argv: list[str] | None = None) -> int:
    cli.preflight(('numpy', 'fontTools', 'PIL'))
    ap = argparse.ArgumentParser(description="Build the marker font from scanned glyph sheets")
    ap.add_argument("sheets", nargs="+", type=Path)
    ap.add_argument("--glyph", help="the character these sheets carry (single-sheet use)")
    ap.add_argument("--manifest", type=Path,
                    help='JSON mapping sheet filename -> character, e.g. {"e_v01.png": "e"}')
    ap.add_argument("--out", type=Path, default=C.FONTS)
    ap.add_argument("--family", default=C.FONT_MARKER)
    ap.add_argument("--min-gap", type=int, required=True,
                    help="smallest empty run counting as a grid line, in px. Must exceed the "
                         "largest gap *inside* a glyph and stay under the cell pitch.")
    ap.add_argument("--threshold", type=float, default=DEFAULT_INK_THRESHOLD)
    ap.add_argument("--tolerance", type=float, default=DEFAULT_TOLERANCE_UNITS,
                    help="simplification tolerance in font units (1000/em). Low on purpose — "
                         "the wobble is the value. 0 keeps the exact pixel boundary.")
    ap.add_argument("--baseline", type=float, default=DEFAULT_BASELINE,
                    help="baseline position as a fraction down the cell; set from the test sheet")
    ap.add_argument("--sidebearing", type=float, default=DEFAULT_SIDEBEARING)
    ap.add_argument("--kerning", type=Path, default=C.FONTS / "kerning.json",
                    help="checked-in kerning data. §3.2 wants only the pairs that collide.")
    args = ap.parse_args(argv)

    sheets = [cli.resolve_or_exit(s, expect=(".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".webp"), label="glyph sheet")
              for s in args.sheets]

    if args.manifest:
        manifest = cli.resolve_or_exit(args.manifest, expect=(".json",), label="manifest")
        mapping = json.loads(manifest.read_text())
        chars = [mapping.get(p.name) for p in sheets]
        missing = [p.name for p, c in zip(sheets, chars) if not c]
        if missing:
            print(f"! {manifest.name} has no character for: {', '.join(missing)}")
            return 2
    elif args.glyph:
        chars = [args.glyph] * len(sheets)
    else:
        print("! give --glyph for a single character, or --manifest mapping sheets to characters")
        return 2

    print(f"Building {args.family} from {len(sheets)} sheet(s)")
    drawings = collect(
        sheets, chars,
        min_gap=args.min_gap, threshold=args.threshold,
        tolerance_units=args.tolerance, baseline=args.baseline,
        sidebearing=args.sidebearing,
    )
    if not drawings:
        print("! nothing traced")
        return 1

    thin = [ch for ch, ds in drawings.items() if len(ds) < 3]
    if thin:
        print(f"  ! only {min(len(drawings[c]) for c in thin)}–"
              f"{max(len(drawings[c]) for c in thin)} version(s) of {', '.join(map(repr, thin))} "
              f"— §3.2 wants 3–5 minimum, and a single version cannot cycle at all")

    feature_code, period = build_calt(drawings)
    print(f"  calt: {period}-step cycle over {sum(1 for ds in drawings.values() if len(ds) > 1)} "
          f"cycling character(s)")

    kern_code, unknown = build_kern(drawings, load_kerning(args.kerning))
    if kern_code:
        print(f"  kern: {kern_code.count('    pos ')} pair(s) from {args.kerning.name}")
    else:
        print(f"  kern: no applicable pairs in {args.kerning.name} — sidebearings only")
    for entry in unknown:
        print(f"    - skipped {entry}")
    feature_code = feature_code + ("\n" + kern_code if kern_code else "")

    fb = build_font(drawings, args.family)
    stem = args.family.replace(" ", "")
    ttf = args.out / f"{stem}.ttf"
    woff2 = args.out / f"{stem}.woff2"
    compile_font(fb, feature_code, ttf, woff2)

    (args.out / f"{stem}.features.fea").write_text(feature_code)
    print(f"  ✓ {woff2}  ({woff2.stat().st_size // 1024} KB)")
    print(f"  ✓ {ttf}  ({ttf.stat().st_size // 1024} KB)")
    print("\n  Templates must set font-feature-settings: \"calt\" 1 — see style_guide [S-004].")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
