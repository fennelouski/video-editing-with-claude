"""
Marker font invariants (font_character_set.md; taste_principles §3.2; style_guide [S-004]).

The acceptance criterion from `HANDOFF_claude_code.md` item 1 is the tripled-letter test:
render every letter three times in a row and assert no two adjacent glyphs share an outline
hash. It is checked here through **HarfBuzz shaping the compiled font**, not by inspecting the
feature source — the handoff warns that FontForge and fontmake disagree about `calt` ordering,
and a feature file that reads correctly can still compile to tables that do nothing.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

import config as C
import fixtures as FX

pytest.importorskip("fontTools")
hb = pytest.importorskip("uharfbuzz")

import build_font as BF     # noqa: E402
import trace as T           # noqa: E402


CHARS = ("e", "a", "t")
VERSIONS = 6


@pytest.fixture(scope="module")
def built(tmp_path_factory):
    """The whole pipeline: sheets → trace → calt → woff2."""
    work = tmp_path_factory.mktemp("font")
    sheets = [FX.write_marker_sheet(work / f"{ch}.png", ch, versions=VERSIONS) for ch in CHARS]
    manifest = work / "glyphs.json"
    manifest.write_text(json.dumps({f"{ch}.png": ch for ch in CHARS}))

    code = BF.main([str(s) for s in sheets] + [
        "--manifest", str(manifest), "--out", str(work / "fonts"), "--min-gap", "60",
    ])
    assert code == 0
    return work / "fonts"


@pytest.fixture(scope="module")
def shaper(built):
    """A HarfBuzz face over the compiled TTF."""
    data = (built / "HerMarker.ttf").read_bytes()
    face = hb.Face(data)
    return hb.Font(face), face


def shape(shaper, text: str, calt: bool = True) -> list[str]:
    """Glyph names produced for `text`, in visual order."""
    font, face = shaper
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(font, buf, {"calt": calt})
    order = _glyph_order(face)
    return [order[info.codepoint] for info in buf.glyph_infos]


def _glyph_order(face):
    from fontTools.ttLib import TTFont
    import io

    return TTFont(io.BytesIO(face.blob.data)).getGlyphOrder()


# --------------------------------------------------------------------------------------
# The acceptance criterion
# --------------------------------------------------------------------------------------

def test_tripled_letters_never_repeat_a_glyph(shaper):
    """
    HANDOFF item 1's acceptance test. `aaa bbb ccc` — no two adjacent glyphs may share an
    outline.

    This is the single tell that kills a handwriting font: the same drawing appearing twice,
    identically, side by side in one word.
    """
    text = " ".join(ch * 3 for ch in CHARS)
    names = shape(shaper, text)
    assert names, "shaping produced nothing"

    for a, b in zip(names, names[1:]):
        if a == "space" or b == "space":
            continue
        assert a != b, f"adjacent glyphs are identical in {text!r}: {names}"


def test_tripled_letters_have_distinct_outlines(shaper, built):
    """
    The stronger form of the same claim. Distinct glyph *names* would pass even if two
    alternates happened to carry identical geometry, which is exactly what a mis-segmented
    sheet produces — two cells cropped from the same drawing.
    """
    from fontTools.ttLib import TTFont

    font = TTFont(built / "HerMarker.ttf")
    glyf = font["glyf"]

    def outline_of(name):
        glyph = glyf[name]
        if glyph.numberOfContours == 0:
            return T.outline_hash([])
        coords, end_pts, _ = glyph.getCoordinates(glyf)
        contours, start = [], 0
        for end in end_pts:
            contours.append([tuple(map(float, p)) for p in coords[start:end + 1]])
            start = end + 1
        return T.outline_hash(contours)

    names = shape(shaper, " ".join(ch * 3 for ch in CHARS))
    hashes = [(n, outline_of(n)) for n in names if n != "space"]
    for (na, ha), (nb, hb_) in zip(hashes, hashes[1:]):
        assert ha != hb_, f"{na} and {nb} are different glyphs with identical outlines"


def test_every_alternate_is_a_distinct_drawing(built):
    """
    All twenty drawings of a letter must differ from each other, not merely from their
    neighbours. Two identical alternates silently shorten the cycle.
    """
    from fontTools.ttLib import TTFont

    font = TTFont(built / "HerMarker.ttf")
    glyf = font["glyf"]
    for ch in CHARS:
        base = BF.glyph_name(ch)
        names = [base] + [f"{base}.alt{i:02d}" for i in range(1, VERSIONS)]
        seen = {}
        for name in names:
            coords, end_pts, _ = glyf[name].getCoordinates(glyf)
            contours, start = [], 0
            for end in end_pts:
                contours.append([tuple(map(float, p)) for p in coords[start:end + 1]])
                start = end + 1
            h = T.outline_hash(contours)
            assert h not in seen, f"{name} is identical to {seen[h]}"
            seen[h] = name


def test_calt_actually_changes_the_output(shaper):
    """
    With the feature off, every `a` must be the same glyph. If that is *also* true with it on,
    the feature compiled to nothing — the failure the handoff warns about.
    """
    on = shape(shaper, "aaaa", calt=True)
    off = shape(shaper, "aaaa", calt=False)
    assert len(set(off)) == 1, "calt=0 should leave the base glyph everywhere"
    assert len(set(on)) > 1, "calt=1 changed nothing — the feature did not compile"
    assert on != off


def test_cycle_walks_in_order_not_at_random(shaper):
    """
    `font_character_set.md`: "Cycle deterministically, not randomly. Random selection repeats
    by chance, which is exactly the artifact we're avoiding."

    Ordered cycling means a run of N identical letters uses N *different* forms, in sequence,
    up to the cycle length. A random picker would collide well before then.
    """
    names = shape(shaper, "a" * VERSIONS)
    assert len(set(names)) == VERSIONS, (
        f"{VERSIONS} letters produced only {len(set(names))} distinct forms: {names}"
    )


def test_the_cycle_advances_per_position_not_per_letter(shaper):
    """
    The index depends on position in the run, not on which letter it is — that is what makes a
    word like `SUCCESS` vary its repeated letters rather than restarting at each one.
    """
    names = shape(shaper, "aeaeae")
    a_forms = [n for n in names if n.startswith("a")]
    assert len(set(a_forms)) == len(a_forms), f"interleaved letters reused a form: {names}"


def test_shaping_is_deterministic(shaper):
    text = "".join(CHARS) * 4
    assert shape(shaper, text) == shape(shaper, text)


# --------------------------------------------------------------------------------------
# Cycle period arithmetic
# --------------------------------------------------------------------------------------

@pytest.mark.parametrize("counts", [
    [20], [3], [8], [2], [3, 8, 20], [2, 3, 4, 5], [19, 20], [20, 8, 3, 2],
    list(range(2, 21)),
])
def test_no_alternate_repeats_across_the_wrap(counts):
    """
    The seam the scheme would otherwise miss. When a run resets, the last position holds
    `(P-1) % K` and the next holds 0; those collide exactly when K divides P-1.
    """
    period = BF.cycle_period(counts)
    for k in counts:
        if k > 1:
            assert (period - 1) % k != 0, f"K={k} repeats across the wrap at P={period}"


def test_cycle_period_is_at_least_the_largest_alternate_count():
    """A period below max(K) would waste drawings she spent an afternoon on."""
    assert BF.cycle_period([3, 8, 20]) >= 20
    assert BF.cycle_period([1]) == 1        # nothing to cycle


# --------------------------------------------------------------------------------------
# Outlines are not smoothed  (§3.2)
# --------------------------------------------------------------------------------------

def test_tolerance_zero_keeps_the_exact_pixel_boundary():
    """The floor of the promise: turn simplification off and the staircase comes back intact."""
    mask = np.zeros((40, 40), dtype=bool)
    mask[10:30, 10:30] = True
    exact = T.trace(mask, tolerance=0.0)
    assert len(exact) == 1
    assert len(exact[0]) == 4 * 20, "a 20 px square should trace to its 80 boundary steps"


def test_simplification_only_removes_points_it_never_moves_them():
    """
    Douglas-Peucker is subtractive: every surviving point is at a coordinate the bitmap
    actually produced. That is what separates it from curve fitting, which would smooth away
    the wobble the font exists to keep.
    """
    mask = np.zeros((80, 80), dtype=bool)
    yy, xx = np.mgrid[0:80, 0:80]
    mask[(xx - 40) ** 2 + (yy - 40) ** 2 < 25 ** 2] = True

    exact = set(map(tuple, T.trace(mask, tolerance=0.0)[0]))
    for tol in (0.5, 1.0, 4.0):
        simplified = T.trace(mask, tolerance=tol)[0]
        assert set(map(tuple, simplified)) <= exact, "simplification invented a point"


def test_lower_tolerance_keeps_more_detail():
    mask = np.zeros((120, 120), dtype=bool)
    yy, xx = np.mgrid[0:120, 0:120]
    mask[(xx - 60) ** 2 + (yy - 60) ** 2 < 50 ** 2] = True
    counts = [len(T.trace(mask, tolerance=t)[0]) for t in (0.0, 0.5, 2.0, 8.0)]
    assert counts == sorted(counts, reverse=True), counts


def test_marker_skips_survive_as_separate_contours():
    """
    A skip breaks a stroke into pieces. Both pieces must survive as their own contour — a
    tracer that closed the gap would be repairing the marker, which is the opposite of the job.
    """
    mask = np.zeros((60, 60), dtype=bool)
    mask[10:25, 20:40] = True
    mask[35:50, 20:40] = True
    assert len(T.trace(mask, tolerance=0.0)) == 2


def test_counters_are_punched_not_filled():
    """An `e` has a counter. Outer and inner contours must wind oppositely or it fills solid."""
    mask = np.zeros((60, 60), dtype=bool)
    mask[10:50, 10:50] = True
    mask[22:38, 22:38] = False
    contours = T.trace(mask, tolerance=0.0)
    assert len(contours) == 2
    areas = [T.signed_area(c) for c in contours]
    assert areas[0] * areas[1] < 0, "counter has the same winding as the outline"


# --------------------------------------------------------------------------------------
# Metrics and spacing  (§3.2)
# --------------------------------------------------------------------------------------

def test_alternates_share_a_baseline(built):
    """
    Every drawing of a letter is measured against the ruled cell, not its own ink box. Letting
    each alternate normalise to its bounding box makes the line bounce as the cycle advances —
    far more visible than the repeated glyph the alternates exist to prevent.
    """
    from fontTools.ttLib import TTFont

    glyf = TTFont(built / "HerMarker.ttf")["glyf"]
    for ch in CHARS:
        base = BF.glyph_name(ch)
        bottoms = []
        for name in [base] + [f"{base}.alt{i:02d}" for i in range(1, VERSIONS)]:
            coords, _, _ = glyf[name].getCoordinates(glyf)
            bottoms.append(min(y for _, y in coords))
        spread = max(bottoms) - min(bottoms)
        assert spread < BF.UPM * 0.12, (
            f"{ch!r} alternates sit {spread} units apart at the baseline — the line will bounce"
        )


def test_sidebearings_are_loose(built):
    """
    §3.2 — "Loose spacing. Hand block lettering is not tightly kerned. Over-kerning makes it
    look like a font, which defeats the point."
    """
    from fontTools.ttLib import TTFont

    font = TTFont(built / "HerMarker.ttf")
    hmtx, glyf = font["hmtx"], font["glyf"]
    for ch in CHARS:
        name = BF.glyph_name(ch)
        advance, lsb = hmtx[name]
        coords, _, _ = glyf[name].getCoordinates(glyf)
        ink_width = max(x for x, _ in coords) - min(x for x, _ in coords)
        assert advance > ink_width, f"{ch!r} has no sidebearing at all"
        assert lsb >= BF.UPM * 0.03, f"{ch!r} left sidebearing {lsb} is tight for marker type"


def test_font_declares_no_faux_bold(built):
    """§3.2 — never let software generate a bold; faux-bold on a marker font looks like a smudge."""
    from fontTools.ttLib import TTFont

    os2 = TTFont(built / "HerMarker.ttf")["OS/2"]
    assert os2.usWeightClass in (400, 0) or os2.usWeightClass < 600


def test_woff2_is_written_and_loads(built):
    from fontTools.ttLib import TTFont

    woff2 = built / "HerMarker.woff2"
    assert woff2.exists() and woff2.stat().st_size > 0
    font = TTFont(woff2)
    assert font.flavor == "woff2"
    assert "GSUB" in font, "the woff2 lost its features"


def test_feature_file_is_written_for_inspection(built):
    fea = (built / "HerMarker.features.fea").read_text()
    assert "feature calt" in fea
    assert "@CYC0" in fea and "lookup step1" in fea


# --------------------------------------------------------------------------------------
# Kerning  (§3.2, font_character_set.md "Build outputs")
# --------------------------------------------------------------------------------------

def test_kerning_comes_from_the_checked_in_data_file(tmp_path):
    """
    Kerning is data, not editor state. There is no UFO and no hand-editing, so the font stays
    a pure function of the scans plus this file — the determinism convention in CLAUDE.md.
    """
    drawings = {
        "T": [BF.Drawing("T", i, [[(0, 0)]], 100) for i in range(3)],
        "o": [BF.Drawing("o", i, [[(0, 0)]], 100) for i in range(3)],
    }
    code, unknown = BF.build_kern(drawings, {"To": -55})
    assert "feature kern" in code and "-55" in code
    assert not unknown
    # One entry must cover every alternate of both sides, or a 20x20 pair needs 400 lines.
    assert "T.uc T.uc.alt01 T.uc.alt02" in code
    assert "o o.alt01 o.alt02" in code


def test_kerning_pairs_for_undrawn_characters_are_reported(tmp_path):
    """A typo in the data file must surface, not vanish."""
    drawings = {"T": [BF.Drawing("T", 0, [[(0, 0)]], 100)]}
    code, unknown = BF.build_kern(drawings, {"TZ": -40, "QQQ": -10})
    assert not code
    assert any("TZ" in u for u in unknown) and any("QQQ" in u for u in unknown)


def test_missing_kerning_file_is_not_an_error(tmp_path):
    """§3.2 asks only for pairs that collide; early on there may be none worth setting."""
    assert BF.load_kerning(tmp_path / "absent.json") == {}


def test_shipped_kerning_file_parses_and_is_restrained():
    """
    §3.2 — "kern only the pairs that actually collide. Over-kerning makes it look like a font."
    A full matrix here would be the failure, so the count is part of the spec.
    """
    pairs = BF.load_kerning(C.FONTS / "kerning.json")
    assert pairs, "the shipped kerning file did not parse"
    assert len(pairs) < 80, f"{len(pairs)} pairs is a matrix, not a collision list"
    assert all(len(k) == 2 for k in pairs), "every key must be a two-character pair"
    assert all(-120 < v < 40 for v in pairs.values()), "a kern value is implausibly large"
