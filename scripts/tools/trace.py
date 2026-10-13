"""
tools/trace.py — bitmap → polygon outlines, without smoothing anything.

This exists because every off-the-shelf tracer's default behaviour is the one thing the font
must not do. `font_character_set.md`: *"Don't smooth the outlines when vectorising. The wobble
is the point."* taste_principles §3.2 says the same thing twice — keep the bleed, the skips and
the chisel-edge variation, because those artifacts are the value.

So the outline is built from the exact pixel boundary and then reduced by Douglas–Peucker,
which only ever *removes* points that already lie within `tolerance` of the line they sit on.
It never invents a curve, never fits a spline, and never moves a point. Turn the tolerance down
to zero and you get the staircase back, bit for bit.

Everything here is deterministic: same bitmap in, same points out, no seeded randomness needed.
"""

from __future__ import annotations

import numpy as np


# --------------------------------------------------------------------------------------
# Boundary extraction
# --------------------------------------------------------------------------------------

def _boundary_edges(mask: np.ndarray) -> dict[tuple[int, int], tuple[int, int]]:
    """
    Every pixel-boundary edge, directed so the edges chain into closed loops.

    Each ink pixel contributes one edge per side that faces empty space. The four directions
    are chosen so that ink always sits on the same hand of travel, which makes the loops close
    without any neighbourhood search, and makes outer boundaries and hole boundaries come out
    with opposite winding for free.
    """
    padded = np.pad(mask, 1, constant_values=False)
    ink = padded[1:-1, 1:-1]

    up = ink & ~padded[:-2, 1:-1]
    down = ink & ~padded[2:, 1:-1]
    left = ink & ~padded[1:-1, :-2]
    right = ink & ~padded[1:-1, 2:]

    edges: dict[tuple[int, int], tuple[int, int]] = {}
    for flags, start, end in (
        (up,    lambda r, c: (c + 1, r),     lambda r, c: (c, r)),
        (left,  lambda r, c: (c, r),         lambda r, c: (c, r + 1)),
        (down,  lambda r, c: (c, r + 1),     lambda r, c: (c + 1, r + 1)),
        (right, lambda r, c: (c + 1, r + 1), lambda r, c: (c + 1, r)),
    ):
        for r, c in zip(*np.nonzero(flags)):
            edges[start(int(r), int(c))] = end(int(r), int(c))
    return edges


def _chain_loops(edges: dict[tuple[int, int], tuple[int, int]]) -> list[list[tuple[int, int]]]:
    """Walk the directed edges into closed rings."""
    loops: list[list[tuple[int, int]]] = []
    remaining = dict(edges)
    while remaining:
        start = next(iter(remaining))
        loop = [start]
        point = remaining.pop(start)
        while point != start:
            loop.append(point)
            nxt = remaining.pop(point, None)
            if nxt is None:        # open chain: only possible on a malformed mask
                break
            point = nxt
        if len(loop) >= 4:
            loops.append(loop)
    return loops


def signed_area(points: list[tuple[float, float]]) -> float:
    """Shoelace. Sign carries the winding, which is what the caller actually wants."""
    if len(points) < 3:
        return 0.0
    xs = np.asarray([p[0] for p in points], dtype=np.float64)
    ys = np.asarray([p[1] for p in points], dtype=np.float64)
    return 0.5 * float(np.dot(xs, np.roll(ys, -1)) - np.dot(np.roll(xs, -1), ys))


# --------------------------------------------------------------------------------------
# Simplification
# --------------------------------------------------------------------------------------

def douglas_peucker(points: list[tuple[float, float]], tolerance: float) -> list[tuple[float, float]]:
    """
    Drop points that lie within `tolerance` of the chord they sit on.

    Chosen over curve fitting precisely because it is subtractive. A point that survives is at
    the exact coordinate the bitmap put it — so every wobble larger than the tolerance is the
    real edge of her marker stroke, not an approximation of it.

    Iterative rather than recursive: a 1200 dpi glyph outline runs to tens of thousands of
    points and the recursive form hits Python's stack limit on real input.
    """
    if tolerance <= 0 or len(points) < 3:
        return points

    pts = np.asarray(points, dtype=np.float64)
    keep = np.zeros(len(pts), dtype=bool)
    keep[0] = keep[-1] = True

    stack = [(0, len(pts) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi <= lo + 1:
            continue
        a, b = pts[lo], pts[hi]
        seg = b - a
        length = float(np.hypot(*seg))
        chunk = pts[lo + 1:hi] - a
        if length < 1e-12:
            dist = np.hypot(chunk[:, 0], chunk[:, 1])
        else:
            # Perpendicular distance to the chord. Written out rather than via np.cross,
            # which dropped its 2-D form in numpy 2.
            dist = np.abs(seg[0] * chunk[:, 1] - seg[1] * chunk[:, 0]) / length
        idx = int(np.argmax(dist))
        if dist[idx] > tolerance:
            split = lo + 1 + idx
            keep[split] = True
            stack.append((lo, split))
            stack.append((split, hi))

    return [tuple(p) for p in pts[keep]]


# --------------------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------------------

def trace(mask: np.ndarray, tolerance: float = 2.0) -> list[list[tuple[float, float]]]:
    """
    Binary ink mask → closed contours in image coordinates (x right, y down).

    Contours come back with outer boundaries and holes in opposite windings, which is what a
    non-zero fill rule needs to punch the counter out of an `o` rather than filling it in.
    A glyph made of several disjoint strokes — which most marker glyphs are, once a skip breaks
    a stem — returns one contour per stroke, all in the same list.
    """
    if not mask.any():
        return []
    loops = _chain_loops(_boundary_edges(mask))
    out = []
    for loop in loops:
        # Close the ring before simplifying. Douglas-Peucker anchors its endpoints, so on an
        # open list the closing edge is never examined and the last few steps of the staircase
        # survive untouched — a visible flat spot on one side of every glyph.
        ring = [(float(x), float(y)) for x, y in loop]
        simplified = douglas_peucker(ring + [ring[0]], tolerance)[:-1]
        if len(simplified) >= 3 and abs(signed_area(simplified)) > 0.0:
            out.append(simplified)
    return out


def outline_hash(contours: list[list[tuple[float, float]]]) -> str:
    """
    A stable digest of a glyph's geometry, for asserting two drawings really are different.

    Rotation-invariant per contour: a ring has no natural first point, so the same outline
    chained from a different starting edge must hash the same or the acceptance test would
    pass on an accident. Each contour is rotated to its lexicographically smallest form and
    the contours are then sorted, so only the geometry survives.
    """
    import hashlib

    normalised = []
    for contour in contours:
        pts = [(round(x, 4), round(y, 4)) for x, y in contour]
        if pts and pts[0] == pts[-1]:
            pts = pts[:-1]
        if not pts:
            continue
        k = min(range(len(pts)), key=lambda i: pts[i:] + pts[:i])
        normalised.append(tuple(pts[k:] + pts[:k]))
    normalised.sort()
    return hashlib.sha256(repr(normalised).encode()).hexdigest()[:16]
