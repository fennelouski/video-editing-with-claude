"""
tools/geometry.py — capture squareness, measured and never corrected.

style_guide [S-015]. The §1.2 ≥2400 px long-edge check measures *apparent* pixels, and a piece
photographed a few degrees off-axis is foreshortened: it can pass while undersized, or fail
while fine. The tempting fix is a homography that straightens the capture. That instinct is
wrong twice over — §1.3 forbids resampling cutout geometry, and a perspective-distorted
photograph of flat artwork is already wrong. A rectangle shot off-axis is a trapezoid, and no
correction restores the fibre detail the foreshortened edge never resolved.

§1.2 already requires the sensor plane parallel to the table. So an off-axis shot is a capture
defect, not an input to accommodate, and the only useful things to do with the geometry are
measure the deviation, compute true dimensions for the size check, and say "level it and
reshoot".

**This module cannot return pixels, by construction.** `measure()` hands back a `Squareness`,
whose fields are all scalars and whose methods all return numbers. The homography exists — it
has to, to compute anything — but it lives in a private attribute with no accessor and no warp
method. [S-015]'s auto-check is precisely that: *if it cannot return pixels, the mistake is
unrepresentable rather than merely discouraged.*

Registration-mark *detection* is not here. It needs a real capture with real marks to tune
against, and inventing one from a synthetic fixture would be building to a guess.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np


# §1.2's "sensor plane parallel to the table" in practice. Beyond this, foreshortening across a
# 3000 px piece exceeds the tolerance the 2400 px floor is meant to enforce.
MAX_OFF_AXIS_DEG = 1.5

Point = tuple[float, float]


def _homography(src: list[Point], dst: list[Point]) -> np.ndarray:
    """Direct linear transform from four point correspondences."""
    if len(src) != 4 or len(dst) != 4:
        raise ValueError("a homography needs exactly four correspondences")
    rows = []
    for (x, y), (u, v) in zip(src, dst):
        rows.append([-x, -y, -1, 0, 0, 0, u * x, u * y, u])
        rows.append([0, 0, 0, -x, -y, -1, v * x, v * y, v])
    _, _, vt = np.linalg.svd(np.asarray(rows, dtype=np.float64))
    h = vt[-1].reshape(3, 3)
    if abs(h[2, 2]) < 1e-12:
        raise ValueError("degenerate marks — the four points are collinear or coincident")
    return h / h[2, 2]


def _apply(h: np.ndarray, points: np.ndarray) -> np.ndarray:
    homo = np.concatenate([points, np.ones((len(points), 1))], axis=1)
    out = homo @ h.T
    return out[:, :2] / out[:, 2:3]


def _vanishing_point(a: Point, b: Point, c: Point, d: Point) -> np.ndarray | None:
    """Intersection of lines ab and cd in homogeneous coordinates, or None if parallel."""
    l1 = np.cross([*a, 1.0], [*b, 1.0])
    l2 = np.cross([*c, 1.0], [*d, 1.0])
    p = np.cross(l1, l2)
    if abs(p[2]) < 1e-9:
        return None             # genuinely parallel: no tilt in this direction
    return p[:2] / p[2]


@dataclass(frozen=True)
class Squareness:
    """
    A measurement of how far a capture departs from square-on.

    Every field is a scalar and every method returns a number. There is deliberately no
    `warp`, `rectify` or `homography` here: the whole point of [S-015] is that this type
    cannot hand anyone corrected pixels, so "just straighten it" is not an available move.
    """

    off_axis_deg: float
    keystone: float             # fractional difference between opposite side lengths
    focal_px: float
    focal_estimated: bool

    # Private, and it stays that way. Named with a leading underscore and excluded from repr
    # so it does not turn up in a log and invite use.
    _h_inv: np.ndarray = None   # type: ignore[assignment]

    @property
    def is_square(self) -> bool:
        return self.off_axis_deg <= MAX_OFF_AXIS_DEG

    def true_size(self, box: tuple[slice, slice]) -> tuple[float, float]:
        """
        A region's dimensions as they would measure square-on, in the same pixel scale.

        This is what the §1.2 size gate should be checking. An apparent long edge is shortened
        by foreshortening, so a piece can read as 2380 px while genuinely being 2450.
        """
        ys, xs = box
        corners = np.array([
            [xs.start, ys.start], [xs.stop, ys.start],
            [xs.stop, ys.stop], [xs.start, ys.stop],
        ], dtype=np.float64)
        flat = _apply(self._h_inv, corners)
        width = (np.linalg.norm(flat[1] - flat[0]) + np.linalg.norm(flat[2] - flat[3])) / 2
        height = (np.linalg.norm(flat[3] - flat[0]) + np.linalg.norm(flat[2] - flat[1])) / 2
        return float(width), float(height)

    def advice(self) -> str:
        """What to actually do about it, in the terms §1.2 uses."""
        if self.is_square:
            return f"capture is square within {self.off_axis_deg:.2f}° — fine"
        about = "~" if self.focal_estimated else ""
        return (
            f"camera is {about}{self.off_axis_deg:.1f}° off-axis (tolerance "
            f"{MAX_OFF_AXIS_DEG}°) — level it and reshoot. §1.2 wants the sensor plane "
            f"parallel to the table; no correction recovers detail a foreshortened edge "
            f"never resolved."
            + ("\n  Angle is approximate: focal length was estimated from the frame width. "
               "Pass the real value for a firm number." if self.focal_estimated else "")
        )


def measure(marks: list[Point], *, image_size: tuple[int, int],
            focal_px: float | None = None) -> Squareness:
    """
    Measure a capture's squareness from four registration marks.

    `marks` are the marks as found in the image, in the order top-left, top-right,
    bottom-right, bottom-left. They are assumed to sit at the corners of a rectangle on the
    table; its aspect does not need to be known, because tilt shows up as *convergence* of
    edges that should be parallel, not as the aspect itself.

    Tilt is recovered from the vanishing points of the two edge directions: a square-on capture
    sends both to infinity, and the closer one falls to the frame, the steeper the tilt. That
    conversion needs a focal length, so `focal_px` should come from EXIF or a one-off
    calibration — the fallback assumes a ~55° horizontal field of view and says so.
    """
    if len(marks) != 4:
        raise ValueError(f"expected 4 registration marks, got {len(marks)}")

    width, height = image_size
    estimated = focal_px is None
    if estimated:
        focal_px = width / (2 * math.tan(math.radians(55.0) / 2))

    tl, tr, br, bl = marks
    # Refuse a degenerate quad up front. Left to the linear algebra, collinear marks produce a
    # near-singular matrix that sometimes inverts and returns confident nonsense — which is a
    # worse failure than not measuring at all.
    pts = np.asarray(marks, dtype=np.float64)
    area = 0.5 * abs(float(np.dot(pts[:, 0], np.roll(pts[:, 1], -1))
                           - np.dot(np.roll(pts[:, 0], -1), pts[:, 1])))
    span = float(np.linalg.norm(pts.max(axis=0) - pts.min(axis=0)))
    if area < max(1.0, 0.02 * span ** 2):
        raise ValueError(
            f"registration marks do not form a usable quadrilateral (area {area:.1f} px² "
            f"across a {span:.0f} px span) — they look collinear or coincident"
        )

    centre = np.array([width / 2.0, height / 2.0])

    angles = []
    for a, b, c, d in ((tl, tr, bl, br), (tl, bl, tr, br)):
        v = _vanishing_point(a, b, c, d)
        if v is None:
            angles.append(0.0)          # parallel in the image: square-on in this direction
            continue
        # Tilt about the axis perpendicular to this edge pair.
        angles.append(math.degrees(math.atan2(focal_px, float(np.linalg.norm(v - centre)))))

    top = np.linalg.norm(np.subtract(tr, tl))
    bottom = np.linalg.norm(np.subtract(br, bl))
    left = np.linalg.norm(np.subtract(bl, tl))
    right = np.linalg.norm(np.subtract(br, tr))
    keystone = max(
        abs(top - bottom) / max(top, bottom, 1e-9),
        abs(left - right) / max(left, right, 1e-9),
    )

    # Rectify to a rectangle whose sides average the observed ones, so `true_size` comes back
    # in the same pixel scale the apparent measurement used.
    w = (top + bottom) / 2
    h = (left + right) / 2
    flat = [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
    h_inv = np.linalg.inv(_homography(flat, list(marks)))

    return Squareness(
        off_axis_deg=float(max(angles)),
        keystone=float(keystone),
        focal_px=float(focal_px),
        focal_estimated=estimated,
        _h_inv=h_inv,
    )
