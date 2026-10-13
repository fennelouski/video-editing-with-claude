"""
tools/sheet.py — shared preparation for the sheets she photographs and scans.

Two tools consume this. The **cutout segmenter** (`segment_sheet.py`) takes a photo of several
cardboard pieces on mid-grey seamless. The **font builder** takes a 1200 dpi scan of a grid of
hand-lettered glyphs. They differ in how regions are found — free-form pieces versus grid cells
— but everything before and after that is the same work: read the sheet, neutralise it against
a grey reference, and cut regions out without destroying the edge.

Two constraints from taste_principles shape most of this:

  §1.3  *Preserve fibre.* Cut and torn edges keep their irregularity. If the matte eats the
        fuzz, the matte is wrong. Never trace a cutout into a clean path. So every threshold
        here is deliberately generous at the boundary, and nothing erodes.

  §1.3  *Store the unmodified extraction.* All scaling, rotation, and shadow happen in comp.
        Nothing here deskews, straightens or re-squares a piece — §1.2 has her shoot every
        piece 1–3° off-square on purpose, and correcting that would be destroying the work.
        (Grid *sheets* are a different matter; see `find_cells`.)
"""

from __future__ import annotations

import math

import numpy as np
from scipy import ndimage

# Palette-independent: this module handles raw captures, which are graded later.


# --------------------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------------------

def load_rgb(path) -> np.ndarray:
    """Read an image as float RGB in [0, 1]. Alpha, if any, is discarded — this is a capture."""
    from PIL import Image

    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0


def save_rgba(path, rgb: np.ndarray, alpha: np.ndarray) -> None:
    """Write straight-alpha RGBA PNG. 8-bit; Pillow cannot write 16-bit RGBA."""
    from PIL import Image

    out = np.concatenate(
        [
            np.rint(np.clip(rgb, 0.0, 1.0) * 255.0).astype(np.uint8),
            np.rint(np.clip(alpha, 0.0, 1.0) * 255.0).astype(np.uint8)[..., None],
        ],
        axis=-1,
    )
    Image.fromarray(out, "RGBA").save(path)


# --------------------------------------------------------------------------------------
# White balance  (§1.2)
# --------------------------------------------------------------------------------------

def neutral_gains(patch: np.ndarray) -> tuple[float, float, float]:
    """
    Per-channel gains that make a patch neutral, normalised on green.

    §1.2 — "white-balance every session to the grey card. This single habit is what keeps
    kraft paper the same kraft across three months of shooting." The gains are returned rather
    than applied so one sheet's card can balance a whole session's sheets.
    """
    mean = patch.reshape(-1, 3).mean(axis=0)
    if not np.all(mean > 1e-6):
        raise ValueError("grey reference is black in at least one channel — wrong patch?")
    return tuple(float(mean[1] / mean[i]) for i in range(3))  # type: ignore[return-value]


def apply_gains(rgb: np.ndarray, gains: tuple[float, float, float]) -> np.ndarray:
    """
    Apply white-balance gains.

    Deliberately not clipped to 1.0. A gain above 1 can push a bright pixel past white, and
    clamping here would manufacture the blown highlight §7 calls the most "rendered"-looking
    thing in a warm frame. Callers clip once, at the edge, when they quantise.
    """
    return rgb * np.asarray(gains, dtype=np.float32)


# --------------------------------------------------------------------------------------
# Background
# --------------------------------------------------------------------------------------

def estimate_background(rgb: np.ndarray, border: int = 24) -> np.ndarray:
    """
    The seamless colour, taken as the median of a border frame.

    Median rather than mean: a piece overhanging the edge of frame shifts a mean and barely
    moves a median. §1.2 has the pieces raised ~10 mm on foam tape, so the border also catches
    their cast shadow — one more reason not to average.
    """
    h, w, _ = rgb.shape
    b = max(1, min(border, h // 4, w // 4))
    edges = np.concatenate([
        rgb[:b].reshape(-1, 3), rgb[-b:].reshape(-1, 3),
        rgb[:, :b].reshape(-1, 3), rgb[:, -b:].reshape(-1, 3),
    ])
    return np.median(edges, axis=0)


def shadow_floor_from(background: np.ndarray, deepest_shadow: np.ndarray) -> float:
    """
    The darkest scale along the backdrop ray that a real shadow reaches.

    Derived from a measured sample, never chosen ([S-014]). She records the deepest shadow in
    the same frame as the grey card, exactly as [S-013] has her record the seamless — a guessed
    constant would put a lighting-dependent number in code, which is the thing [S-013] exists
    to prevent. Change the lights and this changes with them.
    """
    b = np.asarray(background, dtype=np.float32)
    denom = float(b @ b)
    if denom < 1e-8:
        return 0.0
    return float(np.asarray(deepest_shadow, dtype=np.float32) @ b) / denom


def background_distance(rgb: np.ndarray, background: np.ndarray,
                        shadow_floor: float = 0.0) -> np.ndarray:
    """
    How far each pixel sits from the seamless, measured so that shading does not count.

    The measurement is the distance from the *ray* through the background colour, not from the
    background colour itself. §1.2 raises every piece ~10 mm on foam tape, so a real sheet
    always carries some contact shadow, and a shadow is the backdrop scaled down — same hue,
    lower value — which puts it on that ray. Lighting falloff across a large seamless is the
    same thing more gently.

    Measuring absolute difference instead makes a shadow look exactly like a dark piece, and
    the two pieces on a sheet get bridged by the shadow between them into one region. That
    only stayed hidden while the reference was inferred from the sheet's own border, which
    already sat partway into the shadow. Now [S-013] supplies a measured value, the shading
    has to be handled rather than accidentally cancelled.

    What survives: any pixel whose *hue* differs from the backdrop, which is every material in
    §1.1 — kraft, oat, sage, moss all carry real chroma against a neutral grey.
    """
    b = np.asarray(background, dtype=np.float32)
    denom = float(b @ b)
    if denom < 1e-8:
        return np.linalg.norm(rgb - b, axis=-1)

    # Component of each pixel along the backdrop ray, then what is left over.
    k = (rgb @ b) / denom
    residual = np.linalg.norm(rgb - k[..., None] * b, axis=-1)

    # The ray alone is not sufficient, and the gap it leaves is dangerous ([S-014]). A
    # near-neutral *dark* subject — heavy walnut fill, a charcoal card, grey chipboard — also
    # lies on this ray, and residual would call it a very deep shadow and eat it. The stone
    # test does not catch that case: stone is light and slightly warm, while the one that bites
    # is dark and neutral.
    #
    # What separates them is depth. Shadow depth is bounded by the lighting ratio §1.2
    # specifies; a marker fill is far darker than that lighting can cast. So a pixel counts as
    # backdrop only if it is on the ray *and* no darker than the deepest plausible shadow.
    # Below that floor, how far below is itself the signal.
    depth = np.clip(shadow_floor - k, 0.0, None) * math.sqrt(denom)
    return np.maximum(residual, depth)


# --------------------------------------------------------------------------------------
# Matte  (§1.3)
# --------------------------------------------------------------------------------------

def hysteresis_mask(distance: np.ndarray, high: float, low: float) -> np.ndarray:
    """
    Two-threshold mask: seed on `high`, grow into anything above `low` connected to a seed.

    This is what preserves fibre. A single threshold either eats the fuzz on a torn edge or
    fills the frame with sensor noise; hysteresis keeps a wisp that is faint but attached,
    and drops a speck that is faint and isolated. §1.3: "If the matte eats the fuzz, redo
    the matte."
    """
    strong = distance >= high
    weak = distance >= low
    labels, n = ndimage.label(weak)
    if n == 0:
        return np.zeros_like(distance, dtype=bool)
    keep = np.zeros(n + 1, dtype=bool)
    keep[np.unique(labels[strong])] = True
    keep[0] = False
    return keep[labels]


def solidify(mask: np.ndarray) -> np.ndarray:
    """
    Fill interior holes.

    A piece with a hole punched through it is real and must survive, so only holes that do not
    touch the frame edge are filled — and `binary_fill_holes` already has that property, since
    a hole open to the border is not enclosed.
    """
    return ndimage.binary_fill_holes(mask)


def feather(mask: np.ndarray, pixels: float = 1.5) -> np.ndarray:
    """
    §1.3 — feather the matte 1–2 px. A 0 px matte gives a vector-crisp edge, which is the
    exact tell we are avoiding, so this is a requirement rather than a nicety.

    Applied as a small blur of the binary mask. It softens the boundary without moving it:
    a symmetric blur leaves the 50% contour where it was, so the piece neither grows nor
    shrinks and no fibre is lost.
    """
    return ndimage.gaussian_filter(mask.astype(np.float32), sigma=float(pixels) / 2.0)


# A pixel this covered is confidently artwork, so its colour is the artwork's colour. Below
# it, the captured pixel is a blend of artwork and seamless, which is not what straight alpha
# wants stored — see `edge_extend`.
SOLID_ALPHA = 0.9


def edge_extend(rgb: np.ndarray, alpha: np.ndarray, radius: int = 16,
                solid: float = SOLID_ALPHA, inset: int = 3) -> np.ndarray:
    """
    Replace the colour of every under-covered pixel with the nearest confidently-covered one.

    This does two jobs, and the second is the one that is easy to miss.

    **It gives downstream resamplers something real to sample.** Any resampler that scales this
    PNG without premultiplying alpha blends whatever sits under the transparent pixels into the
    visible edge. Stage 5 premultiplies (style_guide [S-011]) — but Final Cut resamples these
    layers too, every time she scales a graphic in the timeline, and that resampler is not ours.

    **It removes the seamless from the edge.** The piece is cropped out of a photograph, so a
    half-covered pixel captured a genuine optical blend of cardboard *and* mid-grey background.
    Storing that blend as the straight-alpha colour bakes the seamless into the matte: composite
    it over `--bone` and the grey gets counted a second time, which is a grey rim on warm paper.
    The colour must be the artwork at full strength, with coverage carried by alpha alone.

    Only colour moves. Alpha is untouched, so the matte shape — and every fibre §1.3 requires
    preserving — is exactly as it was.

    `inset` is why this is not simply "bleed from the opaque pixels". The matte's edge and the
    *optical* edge do not coincide: a lens renders a cut edge over a few pixels, so a pixel the
    matte calls solid can still be a genuine blend of cardboard and seamless. Sampling there
    propagates grey outward and achieves nothing. Eroding the source first means the colour
    comes from where the piece is unambiguously the piece.

    The cost, stated plainly: the outermost few pixels of RGB inside the matte are replaced by
    colour from just inside them, so a torn edge whose fibres are genuinely lighter loses a
    little of that variation *in colour*. The matte shape keeps it, which is where §1.3's
    "preserve fibre" actually lives, and the alternative is baking the seamless into every
    edge — a grey rim that shows on any background the piece is later composited over.

    `radius` bounds the bleed so most of the background stays uniform and the PNG still
    compresses; 16 px is far more than any sane downscale reaches for.
    """
    source = alpha >= solid
    if inset > 0:
        eroded = ndimage.binary_erosion(source, iterations=inset)
        # A piece thinner than the inset — a hand-drawn rule, a bracket — has no unambiguous
        # interior to sample. Falling back to the un-eroded matte is better than bleeding
        # nothing, and far better than raising on a legitimate shape.
        if eroded.any():
            source = eroded

    if not source.any():
        # Nothing is confidently covered at all. Bleeding from an arbitrary partial pixel
        # would invent a colour, so leave it alone.
        return rgb

    distance, (iy, ix) = ndimage.distance_transform_edt(~source, return_indices=True)
    return np.where((distance <= radius + inset)[..., None], rgb[iy, ix], rgb)


# --------------------------------------------------------------------------------------
# Region finding
# --------------------------------------------------------------------------------------

def find_pieces(mask: np.ndarray, min_area: int = 4096) -> list[tuple[slice, slice]]:
    """
    Free-form regions: one bounding box per connected piece, in reading order.

    Used by the cutout segmenter, where she lays several pieces on a seamless with no grid.
    Reading order is top-to-bottom then left-to-right, banded by row, so `--keys` can be given
    in the order the pieces actually sit on the sheet.
    """
    labels, n = ndimage.label(mask)
    if n == 0:
        return []
    boxes = [b for b in ndimage.find_objects(labels)
             if b is not None and _area(b) >= min_area]
    return _reading_order(boxes)


def find_cells(mask: np.ndarray, min_gap: int) -> list[tuple[slice, slice]]:
    """
    Grid regions: split a sheet into cells on its empty rows and columns.

    Used by the font builder, where each cell holds one drawn glyph. Derived from projection
    profiles rather than from connected components, because a glyph is often several disjoint
    strokes — an `i` is two pieces, and a marker skip can break a stem into three — and
    component labelling would file each fragment as its own glyph.

    `min_gap` is required, not defaulted, because it is the entire correctness condition and
    there is no value that is right for every sheet. **It must be larger than the widest gap
    *inside* a glyph and smaller than the gap *between* cells.** Too small and the space between
    an `i`'s stem and its dot splits one glyph into two; too large and neighbouring cells merge.
    On a ruled sheet the safe choice is a little under the cell pitch. Guessing a default here
    would turn a geometry question the caller can answer into a silent mis-segmentation the
    caller never sees.
    """
    rows, cols = find_grid(mask, min_gap)
    return [(r, c) for r in rows for c in cols]


def find_grid(mask: np.ndarray, min_gap: int) -> tuple[list[slice], list[slice]]:
    """
    The occupied row bands and column bands of a grid sheet, separately.

    `find_cells` crosses these into cells, but the font builder needs them apart: a cell that
    hugs its ink has lost where the baseline was, so the builder rebuilds a *regular* grid from
    the band spacing and measures each glyph inside that. Two glyphs normalised to their own ink
    boxes would sit at two different heights, and the line would bounce.
    """
    return _runs(mask.any(axis=1), min_gap), _runs(mask.any(axis=0), min_gap)


def _runs(occupied: np.ndarray, min_gap: int) -> list[slice]:
    """Contiguous occupied spans, merging any gap shorter than `min_gap`."""
    labels, n = ndimage.label(occupied)
    spans = [s[0] for s in ndimage.find_objects(labels)] if n else []
    merged: list[slice] = []
    for s in spans:
        if merged and s.start - merged[-1].stop < min_gap:
            merged[-1] = slice(merged[-1].start, s.stop)
        else:
            merged.append(s)
    return merged


def _area(box: tuple[slice, slice]) -> int:
    ys, xs = box
    return (ys.stop - ys.start) * (xs.stop - xs.start)


def _reading_order(boxes: list[tuple[slice, slice]]) -> list[tuple[slice, slice]]:
    """
    Top-to-bottom, then left-to-right, banded so pieces that sit side by side stay on one row
    even when their tops differ by a centimetre — which they will, since she places by hand.
    """
    if not boxes:
        return []
    heights = [b[0].stop - b[0].start for b in boxes]
    band = max(8, int(np.median(heights) * 0.5))
    return sorted(boxes, key=lambda b: (b[0].start // band, b[1].start))
