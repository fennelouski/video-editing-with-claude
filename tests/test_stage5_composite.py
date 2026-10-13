"""
Compositing invariants (taste_principles §2.1, §4.3, §4.4, §5.2; §12 checks 1, 6, 9).

The idle-jitter test is the counter-intuitive one: it asserts that consecutive rendered
frames are *different* during the hold. A perfectly static graphic is a bug (§5.2) — real
stop-motion is never still, because a human hand touched the set between exposures.
"""

from __future__ import annotations

import pytest

import config as C
import stepclock as SC

Image = pytest.importorskip("PIL.Image")
import stage5_composite as S5          # noqa: E402


ASPECT = "16:9"


# A pixel at alpha `a` contributes a/255 of its colour to the composite. Below ~5% that is
# under one just-noticeable difference on any display, so it is not what §12's visual checks
# are asking about. Every threshold in this file uses the same number for the same reason.
VISIBLE_ALPHA = 13


@pytest.fixture(scope="module")
def rendered(tmp_path_factory, cutouts, grain):
    """
    One cue rendered to a PNG sequence, exactly as Stage 5 renders it.

    `find_variants` and `load_texture` read C.CUTOUTS / C.TEXTURES at call time, so pointing
    the constants at the fixture tree is enough and nothing is copied into the real assets/.
    The patch is undone as soon as the render returns — leaving it in place for the whole
    module would silently change what every other test in the file is measuring.
    """
    from _pytest.monkeypatch import MonkeyPatch

    out = tmp_path_factory.mktemp("frames")
    clock = SC.StepClock()
    cue = {
        "id": "c001",
        "kind": "GFX",
        "template": "key_term",
        "text": "Thermal death point",
        "assets": ["cutout:yeast_cell", "cutout:thermometer"],
        "hold": 2.0,
    }
    grain_img = Image.open(grain).convert("RGB").resize(C.ASPECTS[ASPECT]["author"],
                                                        Image.LANCZOS)
    mp = MonkeyPatch()
    try:
        mp.setattr(C, "CUTOUTS", next(iter(cutouts.values()))[0].parent)
        mp.setattr(C, "ROOT", out.parent)       # render_cue() logs relative to ROOT
        seq = S5.render_cue(cue, ASPECT, out, clock, grain_img)
    finally:
        mp.undo()
    assert seq is not None, "render_cue found no assets — the cutout fixture did not resolve"
    return seq, cue, clock


def frames_of(seq_dir):
    return sorted(seq_dir.glob("*.png"))


def visible_bbox(img, threshold: int = VISIBLE_ALPHA):
    """
    Bounding box of the pixels that actually read on screen.

    Thresholded rather than `getbbox()`, because a gaussian contact shadow trails off to
    alpha 1–2 for tens of pixels and that faint tail is not what §12 check 1 is about.
    """
    alpha = img.getchannel("A")
    return alpha.point(lambda v: 255 if v >= threshold else 0).getbbox()


def hold_window(cue, clock) -> tuple[int, int]:
    """
    Frame range where every element is placed and none has started leaving.

    §12 samples "a frame at the midpoint of every graphic's hold window", which is the right
    scope for the layout and palette checks: during the place-on and the pull-off a cutout is
    deliberately in motion and deliberately outside the frame.
    """
    last_start = SC.stagger_offset(len(cue["assets"]) - 1)
    return last_start + C.PLACE_FRAMES[1], C.PLACE_FRAMES[1] + clock.hold_frames(cue["hold"])


# --------------------------------------------------------------------------------------
# Alpha  ([S-006] — every graphic ships as its own alpha layer)
# --------------------------------------------------------------------------------------

def test_sequence_was_written(rendered):
    seq, cue, clock = rendered
    expected = (C.PLACE_FRAMES[1] + clock.hold_frames(cue["hold"]) + C.REMOVE_FRAMES[1]
                + SC.stagger_offset(len(cue["assets"]) - 1)) + 1
    assert len(frames_of(seq)) == expected


def test_every_frame_keeps_its_alpha_channel(rendered):
    seq, *_ = rendered
    for path in frames_of(seq):
        with Image.open(path) as img:
            assert img.mode == "RGBA", f"{path.name} lost its alpha ({img.mode})"


def test_alpha_survives_compositing(rendered):
    """
    A layer that came out fully opaque would have flattened its background in, which is the
    [S-006] failure: the graphic stops being something she can move independently.

    Frames before the place-on completes are legitimately empty — the graphic has not
    arrived yet — so emptiness is asserted over the sequence, not over every frame.
    """
    seq, cue, clock = rendered
    non_empty = 0
    for path in frames_of(seq):
        with Image.open(path) as img:
            lo, hi = img.getchannel("A").getextrema()
        assert lo == 0, f"{path.name} has no transparent pixels — background baked in"
        non_empty += hi > 0

    start, end = hold_window(cue, clock)
    assert non_empty >= end - start, "the graphic is absent during frames it should be held"


def test_alpha_has_a_soft_edge(rendered):
    """
    §1.3 — a 0 px matte gives the vector-crisp edge we are specifically avoiding, so the
    composited alpha must carry intermediate values, not just 0 and 255.
    """
    seq, *_ = rendered
    mid = frames_of(seq)[len(frames_of(seq)) // 2]
    with Image.open(mid) as img:
        values = set(img.getchannel("A").get_flattened_data())
    assert len(values - {0, 255}) > 32, "alpha is binary — the matte feather was lost"


# --------------------------------------------------------------------------------------
# Safe zones  (§2.1 — §12 check 1)
# --------------------------------------------------------------------------------------

def test_bounding_boxes_land_inside_the_safe_box(rendered):
    """
    Nothing crosses the §2.1 margins — not a glyph, not a cutout.

    Scoped to the hold window. §5.3 has objects *pulled off frame* over 4–6 frames, so a
    cutout mid-exit is outside the margins by design; asserting over the exit would be
    testing against the vocabulary the spec asks for.
    """
    seq, cue, clock = rendered
    spec = C.ASPECTS[ASPECT]
    bx, by, bw, bh = S5.content_box(spec)
    start, end = hold_window(cue, clock)

    for frame in range(start, end):
        path = seq / f"{frame:05d}.png"
        with Image.open(path) as img:
            box = visible_bbox(img)
        assert box is not None, f"{path.name}: nothing on screen during the hold"
        left, top, right, bottom = box
        assert left >= bx, f"{path.name}: crosses the left margin ({left} < {bx})"
        assert top >= by, f"{path.name}: crosses the top margin ({top} < {by})"
        assert right <= bx + bw, f"{path.name}: crosses the right margin ({right} > {bx + bw})"
        assert bottom <= by + bh, f"{path.name}: crosses the bottom margin ({bottom} > {by + bh})"


def test_content_box_matches_the_documented_usable_area():
    """§2.1 — usable box is 1680 x 900 at origin (120, 80)."""
    assert S5.content_box(C.ASPECTS["16:9"]) == (120, 80, 1680, 900)


def test_nothing_is_rendered_outside_the_canvas(rendered):
    seq, *_ = rendered
    w, h = C.ASPECTS[ASPECT]["author"]
    for path in frames_of(seq):
        with Image.open(path) as img:
            assert img.size == (w, h)


# --------------------------------------------------------------------------------------
# Pure values  (§4.1 — §12 check 9, non-negotiable 5)
# --------------------------------------------------------------------------------------

def pure_value_pixels(img, min_alpha: int):
    """Pure black or pure white pixels at or above a given alpha."""
    return [(r, g, b, a) for r, g, b, a in img.convert("RGBA").get_flattened_data()
            if a >= min_alpha and (r, g, b) in ((0, 0, 0), (255, 255, 255))]


def test_no_pure_black_or_white_in_the_graphic_layer(rendered):
    """
    §12 check 9 / non-negotiable 5 — no pure values anywhere in the graphic layer, at any
    alpha above fully transparent.

    Held by alpha-correct resampling and a float grain pass ([S-011]). Asserted at alpha >= 1
    rather than at a "visible" threshold on purpose: a threshold would have to be chosen to
    accommodate whatever fringe the compositor happens to produce, which is fitting the test
    to the code instead of to the rule.
    """
    seq, *_ = rendered
    for path in frames_of(seq):
        with Image.open(path) as img:
            bad = pure_value_pixels(img, 1)
        assert not bad, f"{path.name}: {len(bad)} pure-value pixel(s), e.g. {bad[0]}"


def test_resampling_does_not_darken_the_matte_edge(cutouts):
    """
    [S-011] — the mechanism, tested directly so a regression names the cause.

    A cutout whose transparent region carries RGB 0 (what a PNG round-trip leaves) must not
    bleed that black into its feathered edge when scaled or rotated. Straight-alpha LANCZOS
    does exactly that; premultiplied resampling does not.
    """
    src = Image.open(next(iter(cutouts.values()))[0]).convert("RGBA")

    for op in (lambda im: S5.resize_rgba(im, (220, 165)),
               lambda im: S5.rotate_rgba(im, 1.7)):
        out = op(src)
        assert not pure_value_pixels(out, 1)

        # Every partially-covered pixel must still carry a plausible cutout colour rather
        # than something dragged toward black by the resampler's negative lobes.
        edge = [(r, g, b) for r, g, b, a in out.get_flattened_data() if 1 <= a < 250]
        assert edge, "no soft edge survived the resample"
        assert min(max(px) for px in edge) > 24, (
            "a partially-covered edge pixel is nearly black — alpha is not premultiplied"
        )


def test_resampling_matches_a_float_reference(cutouts):
    """
    The composited result must match an independent premultiplied reference. This is the
    check that would have caught the original defect: the fringe was invisible over most
    backgrounds, so only a numeric comparison shows it.
    """
    import numpy as np

    src = Image.open(next(iter(cutouts.values()))[0]).convert("RGBA")
    size = (220, 165)

    a = np.asarray(src, dtype=np.float64) / 255.0
    pm = a.copy()
    pm[..., :3] *= a[..., 3:4]
    bands = [Image.fromarray(pm[..., i].astype(np.float32), "F").resize(size, Image.LANCZOS)
             for i in range(4)]
    ref = np.stack([np.asarray(b) for b in bands], axis=-1).astype(np.float64)
    ref_a = np.clip(ref[..., 3], 0, 1)

    got = np.asarray(S5.resize_rgba(src, size), dtype=np.float64) / 255.0
    bone = np.array([0xF2, 0xED, 0xE1]) / 255.0

    # Compare what actually reaches the screen: colour composited over the paper surface.
    over_got = got[..., :3] * got[..., 3:4] + bone * (1 - got[..., 3:4])
    over_ref = np.clip(ref[..., :3], 0, 1) + bone * (1 - ref_a[..., None])
    assert np.abs(over_got - over_ref).max() * 255 < 2.0


def test_grain_pass_never_drives_a_pixel_to_black(grain):
    """
    [S-011] — multiply can only darken, so the darkest legal channel must survive it. The
    integer path truncated twice and turned a channel of 1 into 0.
    """
    dark = Image.new("RGBA", (64, 64), (1, 1, 1, 255))
    grain_img = Image.open(grain).convert("RGB").resize((64, 64))
    out = S5.grain_pass(dark, grain_img, max(C.GRAIN_OPACITY))
    assert not pure_value_pixels(out, 1)


def test_shadow_is_warm_not_black(cutouts):
    """§4.4 — the contact shadow is --walnut at low alpha, never pure black."""
    assert C.SHADOW["rgb"] == (74, 60, 46)
    sprite = Image.open(next(iter(cutouts.values()))[0]).convert("RGBA")
    shadowed = S5.contact_shadow(sprite.resize((120, 90), Image.LANCZOS))
    assert not pure_value_pixels(shadowed, VISIBLE_ALPHA)


def test_palette_contains_no_pure_values():
    for name, value in C.PALETTE.items():
        assert value.upper() not in C.FORBIDDEN_EXACT, f"{name} is a pure value"


# --------------------------------------------------------------------------------------
# Idle jitter  (§5.2 — §12 check 6)
# --------------------------------------------------------------------------------------

def test_frame_to_frame_delta_is_nonzero_through_the_hold(rendered):
    """
    §5.2 — a perfectly static graphic is a bug. Compared step to step, because odd frames
    deliberately reuse the previous step's composite (§5.1).
    """
    from PIL import ImageChops

    seq, cue, clock = rendered
    start, end = hold_window(cue, clock)
    assert end - start >= 4 * C.GRAPHIC_STEP, "hold window too short to test"

    steps = list(range(start + (start % C.GRAPHIC_STEP), end, C.GRAPHIC_STEP))
    for a, b in zip(steps, steps[1:]):
        with Image.open(seq / f"{a:05d}.png") as ia, Image.open(seq / f"{b:05d}.png") as ib:
            diff = ImageChops.difference(ia.convert("RGBA"), ib.convert("RGBA"))
        assert diff.getbbox() is not None, (
            f"frames {a} and {b} are identical — the graphic is frozen during its hold"
        )


def test_odd_frames_reuse_the_previous_step(rendered):
    """
    The other half of §5.1: an odd frame must be byte-identical to the step before it. If it
    isn't, something in the graphic layer moved on an odd frame.
    """
    from PIL import ImageChops

    seq, cue, clock = rendered
    start, end = hold_window(cue, clock)
    for even in range(start + (start % C.GRAPHIC_STEP), end - 1, C.GRAPHIC_STEP):
        a, b = seq / f"{even:05d}.png", seq / f"{even + 1:05d}.png"
        if not b.exists():
            continue
        with Image.open(a) as ia, Image.open(b) as ib:
            diff = ImageChops.difference(ia.convert("RGBA"), ib.convert("RGBA"))
        assert diff.getbbox() is None, (
            f"frame {even + 1} differs from step {even} — the graphic moved on an odd frame"
        )


def test_no_static_run_exceeds_the_rubric_limit(rendered):
    """§12 check 6 — zero frame-to-frame delta for more than 12 frames is a fail."""
    from PIL import ImageChops

    seq, cue, clock = rendered
    start, end = hold_window(cue, clock)
    run = 0
    worst = 0
    paths = [seq / f"{f:05d}.png" for f in range(start, end)]
    for a, b in zip(paths, paths[1:]):
        with Image.open(a) as ia, Image.open(b) as ib:
            same = ImageChops.difference(ia.convert("RGBA"), ib.convert("RGBA")).getbbox() is None
        run = run + 1 if same else 0
        worst = max(worst, run)
    assert worst < C.STATIC_FRAMES_FAIL, f"{worst} identical consecutive frames"


# --------------------------------------------------------------------------------------
# Grain  (§4.3 — §12 check 14)
# --------------------------------------------------------------------------------------

def test_grain_pass_preserves_alpha(cutouts, grain):
    sprite = Image.open(next(iter(cutouts.values()))[0]).convert("RGBA").resize((200, 150))
    grain_img = Image.open(grain).convert("RGB").resize((200, 150))
    out = S5.grain_pass(sprite, grain_img, 0.11)
    assert out.mode == "RGBA"
    assert list(out.getchannel("A").get_flattened_data()) == list(sprite.getchannel("A").get_flattened_data())


def test_grain_pass_actually_changes_the_image(cutouts, grain):
    from PIL import ImageChops

    sprite = Image.open(next(iter(cutouts.values()))[0]).convert("RGBA").resize((200, 150))
    grain_img = Image.open(grain).convert("RGB").resize((200, 150))
    out = S5.grain_pass(sprite, grain_img, 0.11)
    assert ImageChops.difference(out.convert("RGB"), sprite.convert("RGB")).getbbox() is not None


def test_grain_opacity_stays_in_the_documented_band():
    lo, hi = C.GRAIN_OPACITY
    assert (lo, hi) == (0.08, 0.14)


def test_missing_texture_is_a_loud_failure():
    """
    §4.3 and [S-001] — a missing grain scan blocks the render. Substituting a flat fill or
    generated noise is exactly what the channel does not do.
    """
    with pytest.raises(FileNotFoundError) as exc:
        S5.load_texture("definitely-not-a-real-texture", (64, 64))
    assert "§4.3" in str(exc.value) or "forbids" in str(exc.value)


# --------------------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------------------

def test_layout_slots_stay_inside_the_content_box():
    spec = C.ASPECTS[ASPECT]
    bx, by, bw, bh = S5.content_box(spec)
    for n in range(1, 6):
        for sx, sy, sw, sh in S5.layout_slots(n, spec):
            assert sx >= bx and sy >= by
            assert sx + sw <= bx + bw + 1
            assert sy + sh <= by + bh + 1


def test_fit_to_slot_only_ever_scales_down(cutouts):
    """Upscaling a scan past 1:1 destroys the fibre detail that is the reason to shoot big."""
    sprite = Image.open(next(iter(cutouts.values()))[0]).convert("RGBA")
    big = S5.fit_to_slot(sprite, 10_000, 10_000)
    assert big.size == sprite.size

    small = S5.fit_to_slot(sprite, 200, 200)
    assert small.width <= 200 and small.height <= 200
