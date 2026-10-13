"""
Scan-sheet segmenter invariants (taste_principles §1.2, §1.3).

The two rules that carry the most weight here pull in opposite directions, which is why they
both need testing: the matte must be **feathered** so the edge is never vector-crisp, and it
must **preserve fibre** so the feather doesn't eat the fuzz off a torn edge. A matte that
satisfies one by sacrificing the other is the failure this file is looking for.
"""

from __future__ import annotations

import numpy as np
import pytest

import config as C
import fixtures as FX

pytest.importorskip("scipy")

import segment_sheet as SS      # noqa: E402
import sheet as S               # noqa: E402


@pytest.fixture(scope="module")
def sheet_photo(tmp_path_factory):
    return FX.write_sheet(tmp_path_factory.mktemp("sheets") / "session01_a.jpg")


@pytest.fixture(scope="module")
def segmented(tmp_path_factory, sheet_photo):
    """The sheet run through the tool exactly as the CLI runs it."""
    out = tmp_path_factory.mktemp("cutouts")
    code = SS.main([str(sheet_photo), "--keys", "yeast_cell-budding,thermometer",
                    "--variant", "a", "--out", str(out)])
    return out, code


def load_rgba(path):
    from PIL import Image

    with Image.open(path) as im:
        return np.asarray(im.convert("RGBA"), dtype=np.float32) / 255.0


# --------------------------------------------------------------------------------------
# Output shape and naming
# --------------------------------------------------------------------------------------

def test_every_piece_is_written(segmented):
    out, code = segmented
    assert code == 0, "the tool reported a problem on a sheet that should be clean"
    assert len(list(out.glob("*.png"))) == 2


def test_naming_follows_the_convention(segmented):
    """§1.3 — `assets/cutouts/<subject>_<descriptor>_v<NN>_<variant>.png`."""
    out, _ = segmented
    assert {p.name for p in out.glob("*.png")} == {
        "yeast_cell-budding_v01_a.png",
        "thermometer_v01_a.png",
    }


def test_output_is_rgba_with_real_transparency(segmented):
    out, _ = segmented
    for path in out.glob("*.png"):
        arr = load_rgba(path)
        alpha = arr[..., 3]
        assert alpha.min() == 0.0, f"{path.name} has no transparent region — matte failed"
        assert alpha.max() == 1.0, f"{path.name} has no opaque region — matte ate the piece"


def test_pieces_clear_the_resolution_floor(segmented):
    """§1.2 — every piece fills at least 2400 px on its long edge."""
    out, _ = segmented
    for path in out.glob("*.png"):
        h, w = load_rgba(path).shape[:2]
        assert max(h, w) >= SS.MIN_LONG_EDGE_PX


def test_unnamed_pieces_are_flagged_not_guessed(tmp_path, sheet_photo, capsys):
    """Fewer keys than pieces must be reported — a wrongly named cutout is worse than none."""
    code = SS.main([str(sheet_photo), "--keys", "yeast_cell-budding",
                    "--variant", "a", "--out", str(tmp_path)])
    out = capsys.readouterr().out
    assert code == 0
    assert "unnamed-02" in out
    assert "renamed" in out
    assert (tmp_path / "unnamed-02_v01_a.png").exists()


# --------------------------------------------------------------------------------------
# The matte  (§1.3)
# --------------------------------------------------------------------------------------

def test_matte_is_feathered_never_vector_crisp(segmented):
    """
    §1.3 — a 0 px matte gives the vector-crisp edge that is the exact tell we are avoiding,
    so the alpha must carry a real gradient rather than only 0 and 1.
    """
    out, _ = segmented
    for path in out.glob("*.png"):
        alpha = load_rgba(path)[..., 3]
        partial = ((alpha > 0.02) & (alpha < 0.98)).sum()
        perimeter = 2 * (alpha.shape[0] + alpha.shape[1])
        assert partial > perimeter, (
            f"{path.name}: only {partial} partial-alpha pixels — the matte is effectively binary"
        )


def test_feather_width_stays_inside_the_documented_band(segmented):
    """
    1–2 px, not more. An over-soft matte is its own tell: a cut cardboard edge is sharp, and
    a 6 px halo reads as a bad key rather than as paper.

    Width is band area over true perimeter. A σ=0.75 gaussian — the 1.5 px default — spans
    about 2.5 px between 5% and 95%, so anything near 6 is a genuinely soft matte and not
    measurement noise.
    """
    from scipy import ndimage

    out, _ = segmented
    for path in out.glob("*.png"):
        alpha = load_rgba(path)[..., 3]
        covered = alpha >= 0.5
        perimeter = (covered & ~ndimage.binary_erosion(covered)).sum()
        assert perimeter > 0

        band = ((alpha > 0.05) & (alpha < 0.95)).sum()
        assert band / perimeter < 6.0, (
            f"{path.name}: feather averages {band / perimeter:.1f} px, well past the 1–2 px §1.3 asks for"
        )


def test_partial_alpha_hugs_the_edge(segmented):
    """
    The soft band belongs at the perimeter. Partial alpha scattered through the interior would
    mean the matte is speckling on the artwork's own texture rather than following its outline.
    """
    from scipy import ndimage

    out, _ = segmented
    for path in out.glob("*.png"):
        alpha = load_rgba(path)[..., 3]
        covered = alpha >= 0.5
        edge = ndimage.binary_dilation(covered & ~ndimage.binary_erosion(covered), iterations=4)
        stray = (((alpha > 0.05) & (alpha < 0.95)) & ~edge).sum()
        assert stray == 0, f"{path.name}: {stray} partial-alpha pixels away from the outline"


def test_feather_does_not_move_the_edge(sheet_photo):
    """
    A symmetric blur leaves the 50% contour where the hard mask was, so feathering costs no
    coverage. A feather implemented as an erosion would quietly shave fibre off every piece.
    """
    mask = np.zeros((400, 400), dtype=bool)
    mask[100:300, 120:280] = True
    for px in (1.0, 1.5, 2.0):
        soft = S.feather(mask, px)
        assert abs((soft >= 0.5).sum() - mask.sum()) <= 2 * (200 + 160) * 0.02


def test_matte_preserves_attached_fibre():
    """
    §1.3 — "If the matte eats the fuzz, redo the matte."

    A thin, faint wisp attached to the body of a piece is a torn fibre and must survive. An
    equally faint speck that touches nothing is dust and must not. A single threshold cannot
    tell them apart; hysteresis can, and that is the whole reason it is there.
    """
    distance = np.zeros((200, 200), dtype=np.float32)
    distance[60:140, 60:140] = 1.0        # solid body
    distance[95:105, 140:180] = 0.08      # faint fibre, attached
    distance[20:30, 20:30] = 0.08         # equally faint speck, isolated

    mask = S.hysteresis_mask(distance, high=0.14, low=0.045)
    assert mask[100, 175], "an attached fibre was eaten by the matte"
    assert not mask[25, 25], "an isolated speck was kept as if it were part of a piece"


def test_holes_are_filled_but_open_bays_are_not():
    """A punched hole is interior and closes; a bay cut in from the edge is shape, and stays."""
    mask = np.zeros((200, 200), dtype=bool)
    mask[40:160, 40:160] = True
    mask[90:110, 90:110] = False          # hole through the middle
    mask[60:80, 40:100] = False           # bay open to the left edge of the piece

    solid = S.solidify(mask)
    assert solid[100, 100], "an interior hole was not filled"
    assert not solid[70, 45], "a bay cut in from the edge was filled in"


# --------------------------------------------------------------------------------------
# Edge extend
# --------------------------------------------------------------------------------------

def test_transparent_side_of_the_edge_carries_artwork_colour(segmented):
    """
    The reason this exists: FCP resamples these layers whenever she scales a graphic, and that
    resampler is not ours. Colour bled outward here is correct for every downstream resampler,
    including the ones that do not premultiply.
    """
    out, _ = segmented
    for path in out.glob("*.png"):
        arr = load_rgba(path)
        rgb, alpha = arr[..., :3], arr[..., 3]
        interior = rgb[alpha > 0.99].mean(axis=0)

        # A ring just outside the matte, where a naive resampler would sample.
        from scipy import ndimage
        outside = ndimage.binary_dilation(alpha > 0.0, iterations=6) & (alpha == 0.0)
        assert outside.sum() > 0
        just_outside = rgb[outside].mean(axis=0)

        assert np.abs(just_outside - interior).max() < 0.25, (
            f"{path.name}: colour under the matte is {just_outside.round(3)} against an "
            f"interior of {interior.round(3)} — edge extend did not run"
        )


def test_edge_extend_leaves_covered_pixels_untouched():
    """It fills outward only. Changing a pixel the artwork actually covers would be retouching."""
    rgb = np.zeros((60, 60, 3), dtype=np.float32)
    rgb[20:40, 20:40] = [0.8, 0.72, 0.58]
    alpha = np.zeros((60, 60), dtype=np.float32)
    alpha[20:40, 20:40] = 1.0

    out = S.edge_extend(rgb, alpha, radius=8)
    assert np.array_equal(out[alpha > 0], rgb[alpha > 0])
    assert np.allclose(out[19, 30], [0.8, 0.72, 0.58])          # one px outside, filled
    assert np.allclose(out[5, 30], 0.0)                          # beyond the radius, untouched


def test_edge_extend_is_bounded_by_its_radius():
    """Unbounded fill would destroy PNG compression on a 3000 px capture for no benefit."""
    rgb = np.zeros((200, 200, 3), dtype=np.float32)
    rgb[90:110, 90:110] = 0.7
    alpha = np.zeros((200, 200), dtype=np.float32)
    alpha[90:110, 90:110] = 1.0

    filled = S.edge_extend(rgb, alpha, radius=10) > 0
    assert filled[..., 0].sum() < 200 * 200 * 0.25


# --------------------------------------------------------------------------------------
# White balance  (§1.2)
# --------------------------------------------------------------------------------------

def test_white_balance_neutralises_the_capture_cast(tmp_path):
    """
    §1.2 — "white-balance every session to the grey card. This single habit is what keeps
    kraft paper the same kraft across three months of shooting."
    """
    cast = (1.06, 1.0, 0.90)
    photo = FX.write_sheet(tmp_path / "cast.jpg", cast=cast)
    rgb = S.load_rgb(photo)

    gains, source = SS.resolve_gains(rgb, None, None)
    assert "background" in source
    for got, applied in zip(gains, cast):
        assert got == pytest.approx(1.0 / applied, rel=0.05)

    balanced = S.apply_gains(rgb, gains)
    bg = S.estimate_background(balanced)
    assert bg.max() - bg.min() < 0.01, f"seamless is still not neutral: {bg}"


def test_explicit_gains_win_so_a_session_stays_consistent(tmp_path):
    photo = FX.write_sheet(tmp_path / "s.jpg")
    rgb = S.load_rgb(photo)
    gains, source = SS.resolve_gains(rgb, None, "1.1,1.0,0.9")
    assert gains == (1.1, 1.0, 0.9)
    assert source == "explicit --gains"


def test_gains_are_not_clipped_into_a_blown_highlight():
    """
    §7 — never clip to pure white; a blown highlight is the most "rendered"-looking thing in a
    warm frame. Clipping inside the balance step would bake that in before the grade sees it.
    """
    bright = np.full((4, 4, 3), 0.99, dtype=np.float32)
    assert S.apply_gains(bright, (1.2, 1.0, 1.0))[..., 0].max() > 1.0


# --------------------------------------------------------------------------------------
# Refusals  ("failures are loud and actionable")
# --------------------------------------------------------------------------------------

def test_undersized_piece_is_reported_and_skipped(tmp_path, capsys):
    """§1.2 — below 2400 px on the long edge the edit cannot push in, so it is not usable."""
    photo = FX.write_sheet(tmp_path / "small.jpg", pieces=("kraft",),
                           piece_size=(1200, 900), gap=120)
    code = SS.main([str(photo), "--keys", "yeast_cell", "--out", str(tmp_path / "out")])
    out = capsys.readouterr().out

    assert code != 0, "an unusable capture exited 0"
    assert "2400" in out and "§1.2" in out
    assert "Reshoot" in out
    assert not list((tmp_path / "out").glob("*.png")), "an undersized piece was written anyway"


def test_zero_feather_is_refused(tmp_path, sheet_photo, capsys):
    """A 0 px matte is the vector-crisp edge the whole asset system exists to avoid."""
    code = SS.main([str(sheet_photo), "--feather", "0", "--out", str(tmp_path)])
    assert code == 2
    assert "vector-crisp" in capsys.readouterr().out


def test_out_of_range_variant_is_refused(tmp_path, sheet_photo, capsys):
    code = SS.main([str(sheet_photo), "--variant", "z", "--out", str(tmp_path)])
    assert code == 2
    assert "4–6 variants" in capsys.readouterr().out


def test_seamless_must_be_measured_not_inferred(tmp_path, sheet_photo):
    """
    [S-013] — the backdrop value is measured from the grey-card frame, never inferred from the
    sheet being matted. Inferring it makes the [S-012] direction check circular: colour would
    be judged to move "away from the seamless" against a reference derived from the same
    pixels.
    """
    orphan = tmp_path / "no-sidecar.jpg"
    orphan.write_bytes(sheet_photo.read_bytes())        # copied without its capture sidecar

    with pytest.raises(SystemExit) as exc:
        SS.main([str(orphan), "--out", str(tmp_path / "out")])
    message = str(exc.value)
    assert "S-013" in message and "S-014" in message
    assert "--seamless" in message and "no-sidecar.capture.json" in message
    assert not list((tmp_path / "out").glob("*.png")) if (tmp_path / "out").exists() else True


def test_seamless_accepts_both_scales(sheet_photo):
    """0–1 and 0–255 are both natural ways to read a value off a grey-card frame."""
    unit = SS.parse_rgb("0.49,0.46,0.41", "seamless")
    bytes_ = SS.parse_rgb("125,117,105", "seamless")
    assert unit.max() <= 1.0 and bytes_.max() <= 1.0
    assert np.abs(unit - bytes_).max() < 0.02


def test_capture_sidecar_is_used_when_no_flags_are_given(sheet_photo):
    seamless, shadow = SS.resolve_references(sheet_photo, None, None)
    # The fixture's cast is (1.06, 1.0, 0.90) on a 0.46 seamless.
    assert np.allclose(seamless, [0.46 * 1.06, 0.46, 0.46 * 0.90], atol=1e-4)
    assert np.all(shadow < seamless), "the recorded shadow must be darker than the backdrop"


def test_drift_from_the_recorded_seamless_is_reported(tmp_path, sheet_photo, capsys):
    """A backdrop far from the recorded value means the lighting moved — say so."""
    SS.main([str(sheet_photo), "--keys", "a,b", "--seamless", "0.20,0.20,0.20",
             "--dry-run", "--out", str(tmp_path)])
    out = capsys.readouterr().out
    assert "drift" in out
    assert "lighting has not moved" in out


# --------------------------------------------------------------------------------------
# The shadow floor  [S-014]
# --------------------------------------------------------------------------------------

def test_shadow_and_falloff_measure_as_backdrop():
    """
    A shadow is the backdrop scaled down, so it lies on the ray through the backdrop colour
    and must measure ~0. Lighting falloff across a large seamless is the same thing, gentler.
    """
    bg = np.array([0.49, 0.46, 0.41], dtype=np.float32)
    floor = S.shadow_floor_from(bg, bg * 0.70)
    for scale in (1.0, 0.95, 0.85, 0.75, 0.70, 1.06):
        px = (bg * scale)[None, None, :]
        assert float(S.background_distance(px, bg, shadow_floor=floor)[0, 0]) < 1e-3


def test_dark_neutral_subject_is_not_mistaken_for_deep_shadow():
    """
    [S-014] — the case the ray test alone gets wrong. Grey chipboard, a charcoal card and a
    heavy walnut fill all sit on the backdrop ray; only their *depth* distinguishes them from
    shade, and a marker fill is far darker than the §1.2 lighting can cast.
    """
    bg = np.array([0.49, 0.46, 0.41], dtype=np.float32)
    floor = S.shadow_floor_from(bg, bg * 0.70)

    chipboard = (bg * 0.30)[None, None, :]
    with_floor = float(S.background_distance(chipboard, bg, shadow_floor=floor)[0, 0])
    without_floor = float(S.background_distance(chipboard, bg, shadow_floor=0.0)[0, 0])

    assert without_floor < 1e-3, "fixture is not actually on the ray — test proves nothing"
    assert with_floor > 0.15, "a dark neutral piece still reads as backdrop"


def test_shadow_floor_comes_from_the_measurement():
    """Change the lights, and the floor moves with them — it is never a constant in code."""
    bg = np.array([0.49, 0.46, 0.41], dtype=np.float32)
    assert S.shadow_floor_from(bg, bg * 0.70) == pytest.approx(0.70, abs=1e-5)
    assert S.shadow_floor_from(bg, bg * 0.40) == pytest.approx(0.40, abs=1e-5)

    subject = (bg * 0.55)[None, None, :]
    lit = S.shadow_floor_from(bg, bg * 0.70)        # shallow shadows -> 0.55 is a piece
    murky = S.shadow_floor_from(bg, bg * 0.40)      # deep shadows    -> 0.55 is shade
    assert float(S.background_distance(subject, bg, shadow_floor=lit)[0, 0]) > 0.05
    assert float(S.background_distance(subject, bg, shadow_floor=murky)[0, 0]) < 1e-3


def test_dark_piece_beside_a_shadowed_gap_segments_intact(tmp_path, capsys):
    """
    [S-014]'s auto-check, end to end on a rendered sheet: a near-neutral dark piece next to a
    gap full of cast shadow must come out as its own piece, with its interior intact.

    Before the floor, the ray test classified the whole piece as very deep shadow — so it was
    not merely mis-matted, it disappeared, and the shadow it sat in merged its neighbours.
    """
    photo = FX.write_sheet(tmp_path / "dark.jpg", pieces=("kraft", "chipboard"))
    out = tmp_path / "out"
    code = SS.main([str(photo), "--keys", "flour_sack,chipboard_card",
                    "--variant", "a", "--out", str(out)])
    assert code == 0, capsys.readouterr().out

    written = sorted(p.name for p in out.glob("*.png"))
    assert written == ["chipboard_card_v01_a.png", "flour_sack_v01_a.png"], (
        f"expected two separate pieces, got {written}"
    )

    dark = load_rgba(out / "chipboard_card_v01_a.png")
    solid = dark[..., 3] > 0.99
    assert solid.mean() > 0.35, "the dark piece came out mostly transparent — its middle was eaten"

    # And it really is the dark near-neutral material, not something lighter mis-detected.
    interior = dark[..., :3][solid].mean(axis=0)
    assert interior.max() < 0.40, f"interior {interior.round(3)} is not the dark piece"
    assert float(interior.max() - interior.min()) < 0.06, "piece should be near-neutral"


def test_missing_input_is_named(tmp_path):
    """
    Path resolution moved into `cli.resolve_or_exit`, so a bad path now exits with one
    sentence rather than printing and returning. `tests/test_cli.py` holds this contract for
    every entry point; this keeps the segmenter's own coverage honest about it.
    """
    with pytest.raises(SystemExit) as exc:
        SS.main([str(tmp_path / "nope.jpg"), "--out", str(tmp_path)])
    assert "nope.jpg" in str(exc.value)


def test_dry_run_writes_nothing(tmp_path, sheet_photo, capsys):
    code = SS.main([str(sheet_photo), "--keys", "a,b", "--dry-run", "--out", str(tmp_path)])
    assert code == 0
    assert "would be written" in capsys.readouterr().out
    assert not list(tmp_path.glob("*.png"))


# --------------------------------------------------------------------------------------
# Nothing is straightened  (§1.2, §1.3)
# --------------------------------------------------------------------------------------

def rebuild_boxes(sheet_photo):
    """Re-derive the piece boxes from the sheet, the way `segment()` does."""
    rgb = S.load_rgb(sheet_photo)
    gains, _ = SS.resolve_gains(rgb, None, None)
    balanced = S.apply_gains(rgb, gains)
    seamless, shadow = SS.resolve_references(sheet_photo, None, None)
    background = S.apply_gains(seamless[None, None, :], gains)[0, 0]
    floor = S.shadow_floor_from(background, S.apply_gains(shadow[None, None, :], gains)[0, 0])
    distance = S.background_distance(balanced, background, shadow_floor=floor)
    mask = S.solidify(S.hysteresis_mask(distance, SS.MATTE_HIGH * distance.max(),
                                        SS.MATTE_LOW * distance.max()))
    return balanced, S.find_pieces(mask, min_area=SS.MIN_PIECE_AREA_PX)


NAMES = ["yeast_cell-budding_v01_a.png", "thermometer_v01_a.png"]


def test_the_extraction_is_never_resampled(sheet_photo, segmented):
    """
    §1.3 — "store the *unmodified* extraction. All scaling, rotation, and shadow happen in
    comp." §1.2 has her shoot every piece 1–3° off-square deliberately, so a tool that squared
    them up would be destroying the work rather than cleaning it.

    Pixel dimensions equal to the detected bounding box is the strongest single proof of that:
    any deskew, straighten or rescale would change them.
    """
    out, _ = segmented
    _, boxes = rebuild_boxes(sheet_photo)
    for (ys, xs), name in zip(boxes, NAMES):
        arr = load_rgba(out / name)
        assert arr.shape[:2] == (ys.stop - ys.start, xs.stop - xs.start), (
            f"{name} is not the size of its bounding box — it was rotated or rescaled"
        )


def test_the_artwork_interior_is_pixel_for_pixel_the_capture(sheet_photo, segmented):
    """
    Away from the boundary, every pixel is exactly what the camera recorded (after white
    balance). No sharpening, no denoise, no cleanup.
    """
    from scipy import ndimage

    out, _ = segmented
    balanced, boxes = rebuild_boxes(sheet_photo)
    for (ys, xs), name in zip(boxes, NAMES):
        arr = load_rgba(out / name)
        interior = ndimage.binary_erosion(arr[..., 3] > 0.99, iterations=6)
        assert interior.sum() > 0

        expected = np.clip(balanced[ys, xs], 0.0, 1.0)
        assert np.abs(arr[..., :3][interior] - expected[interior]).max() < 0.01, (
            f"{name}: interior pixels differ from the capture — something retouched the artwork"
        )


def test_only_the_contaminated_boundary_ring_is_rewritten(sheet_photo, segmented):
    """
    The one place colour deliberately changes, and the reason it has to.

    The matte is derived from colour distance, so its boundary lands where the capture is
    roughly half cardboard and half seamless — a lens renders a cut edge over a few pixels.
    Those pixels sit at full alpha, so storing their captured colour puts a grey rim on the
    piece at full opacity, visible over any background it is later composited on.

    Shrinking the matte instead would eat fibre and break §1.3, so the matte stays generous
    and `edge_extend` corrects the colour. This test pins the scope of that correction: it is
    confined to a thin ring, and it always moves *away* from the seamless, never toward it.
    """
    from scipy import ndimage

    out, _ = segmented
    balanced, boxes = rebuild_boxes(sheet_photo)
    gains, _ = SS.resolve_gains(S.load_rgb(sheet_photo), None, None)
    seamless, _ = SS.resolve_references(sheet_photo, None, None)
    background = S.apply_gains(seamless[None, None, :], gains)[0, 0]

    for (ys, xs), name in zip(boxes, NAMES):
        arr = load_rgba(out / name)
        rgb, alpha = arr[..., :3], arr[..., 3]
        expected = np.clip(balanced[ys, xs], 0.0, 1.0)

        covered = alpha > 0.99
        changed = (np.abs(rgb - expected).max(axis=-1) > 0.01) & covered

        # Confined to the boundary: nothing more than a few px in from the matte edge.
        deep = ndimage.binary_erosion(covered, iterations=6)
        assert not (changed & deep).any(), f"{name}: colour changed deep inside the piece"
        assert changed.sum() < covered.sum() * 0.02, (
            f"{name}: {changed.sum()} of {covered.sum()} covered pixels rewritten — too broad"
        )

        # And it moves away from the seamless. If edge_extend ever bled the background inward
        # this flips sign, which is the failure that would look like a grey rim.
        before = np.abs(expected[changed] - background).mean()
        after = np.abs(rgb[changed] - background).mean()
        assert after > before, (
            f"{name}: the rewritten ring moved toward the seamless, not away from it"
        )


# --------------------------------------------------------------------------------------
# Shared cell detection  (used by the Phase 3 font builder)
# --------------------------------------------------------------------------------------

# The fixture's cell pitch is 200 px with two strokes ~66 px apart inside each cell, so any
# min_gap between those two numbers is correct. This is the constraint find_cells documents.
GLYPH_MIN_GAP = 90


def test_find_cells_splits_a_glyph_grid(tmp_path):
    """
    The font builder's half of the shared module. A glyph is routinely several disjoint
    strokes — an `i` is two, and a marker skip breaks a stem into three — so cells come from
    projection profiles rather than connected components, which would file each stroke as its
    own glyph.
    """
    grid = FX.write_glyph_grid(tmp_path / "grid.png", rows=3, cols=4)
    ink = S.load_rgb(grid).mean(axis=-1) < 0.5

    cells = S.find_cells(ink, min_gap=GLYPH_MIN_GAP)
    assert len(cells) == 12, f"expected a 3x4 grid, got {len(cells)} cells"

    for ys, xs in cells:
        assert ink[ys, xs].any(), "an empty cell was returned"
    # Every stroke landed in exactly one cell.
    assert sum(int(ink[ys, xs].sum()) for ys, xs in cells) == int(ink.sum())


def test_find_cells_keeps_disjoint_strokes_together(tmp_path):
    """Two strokes in one cell stay one cell — the failure mode component labelling would hit."""
    grid = FX.write_glyph_grid(tmp_path / "g.png", rows=1, cols=1)
    ink = S.load_rgb(grid).mean(axis=-1) < 0.5

    from scipy import ndimage
    _, components = ndimage.label(ink)
    assert components == 2, "fixture should contain two disjoint strokes"
    assert len(S.find_cells(ink, min_gap=GLYPH_MIN_GAP)) == 1


def test_find_cells_min_gap_below_the_intra_glyph_gap_over_splits(tmp_path):
    """
    The documented failure mode, pinned so Phase 3 inherits it as a known constraint rather
    than rediscovering it on a real sheet. A min_gap smaller than the space inside a glyph
    splits that glyph into pieces — which is why find_cells refuses to default the value.
    """
    grid = FX.write_glyph_grid(tmp_path / "g.png", rows=1, cols=1)
    ink = S.load_rgb(grid).mean(axis=-1) < 0.5
    assert len(S.find_cells(ink, min_gap=8)) == 2      # one glyph, wrongly split in two


def test_pieces_come_back_in_reading_order():
    """`--keys` is given in the order the pieces sit on the sheet, so the order must be stable."""
    mask = np.zeros((600, 900), dtype=bool)
    mask[40:240, 500:800] = True        # top-right
    mask[60:250, 60:300] = True         # top-left, a little lower
    mask[350:560, 300:600] = True       # bottom-middle

    boxes = S.find_pieces(mask, min_area=1000)
    assert [(b[0].start, b[1].start) for b in boxes] == [(60, 60), (40, 500), (350, 300)]
