"""
Capture squareness (style_guide [S-015]).

The load-bearing test in this file is `test_it_cannot_return_pixels`. [S-015]'s auto-check is
that the camera path returns a *measurement*, so that "just straighten it" is unrepresentable
rather than merely discouraged — a rule enforced by the type is one nobody has to remember.
"""

from __future__ import annotations

import math

import numpy as np
import pytest

import geometry as G


def project(marks_flat, *, tilt_deg: float, focal: float = 3000.0,
            distance: float = 4000.0, centre=(2000.0, 1500.0)):
    """
    Where four table-plane points land when the camera is tilted by `tilt_deg`.

    A real pinhole projection rather than a fudge, so the recovered angle is checked against
    the geometry that actually produced the image.
    """
    t = math.radians(tilt_deg)
    out = []
    for x, y in marks_flat:
        # Rotate the plane about the x axis, then project.
        yz = y * math.cos(t)
        z = distance + y * math.sin(t)
        out.append((centre[0] + focal * x / z, centre[1] + focal * yz / z))
    return out


SQUARE = [(-800.0, -600.0), (800.0, -600.0), (800.0, 600.0), (-800.0, 600.0)]


def as_marks(points):
    """project() returns tl, tr, br, bl in the order SQUARE lists them."""
    return [tuple(p) for p in points]


# --------------------------------------------------------------------------------------
# [S-015] — the type cannot hand back pixels
# --------------------------------------------------------------------------------------

def test_it_cannot_return_pixels():
    """
    [S-015]'s auto-check. Every public field is a scalar and every public method returns a
    number or a string. Nothing here can produce a corrected image, so nobody can reach for
    one — which is the difference between a rule and a guarantee.
    """
    marks = as_marks(project(SQUARE, tilt_deg=4.0))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)

    public = [n for n in dir(result) if not n.startswith("_")]
    for name in public:
        value = getattr(result, name)
        if callable(value):
            continue
        assert isinstance(value, (int, float, bool)), (
            f"public field {name!r} is {type(value).__name__}; a measurement type must not "
            f"carry anything that could be applied to an image"
        )

    assert result.true_size((slice(0, 100), slice(0, 100))) is not None
    assert isinstance(result.advice(), str)

    for forbidden in ("warp", "rectify", "correct", "homography", "apply", "undistort"):
        assert forbidden not in public, f"{forbidden!r} is exposed — [S-015] forbids it"


def test_the_homography_is_private():
    marks = as_marks(project(SQUARE, tilt_deg=0.0))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)
    assert not hasattr(result, "homography")
    assert "_h_inv" in {f.name for f in result.__dataclass_fields__.values()}


def test_squareness_is_frozen():
    """A measurement of a capture that already happened should not be editable after the fact."""
    marks = as_marks(project(SQUARE, tilt_deg=0.0))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)
    with pytest.raises(Exception):
        result.off_axis_deg = 0.0        # type: ignore[misc]


# --------------------------------------------------------------------------------------
# Measurement
# --------------------------------------------------------------------------------------

def test_square_on_capture_measures_square():
    marks = as_marks(project(SQUARE, tilt_deg=0.0))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)
    assert result.off_axis_deg < 0.1
    assert result.keystone < 1e-6
    assert result.is_square


@pytest.mark.parametrize("tilt", [2.0, 5.0, 10.0, 20.0])
def test_tilt_is_recovered_from_the_marks(tilt):
    """The angle must track the geometry that produced the image, not just rank captures."""
    marks = as_marks(project(SQUARE, tilt_deg=tilt))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)
    assert result.off_axis_deg == pytest.approx(tilt, abs=0.6), result.off_axis_deg


def test_off_axis_capture_is_refused_with_advice():
    marks = as_marks(project(SQUARE, tilt_deg=6.0))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)
    assert not result.is_square

    advice = result.advice()
    assert "off-axis" in advice and "reshoot" in advice
    assert "§1.2" in advice
    # It must not offer to fix it — that is the instinct [S-015] exists to block.
    assert "correct" not in advice.lower().replace("no correction", "")


def test_keystone_grows_with_tilt():
    values = [G.measure(as_marks(project(SQUARE, tilt_deg=t)),
                        image_size=(4000, 3000), focal_px=3000.0).keystone
              for t in (0.0, 2.0, 6.0, 15.0)]
    assert values == sorted(values)


def test_estimated_focal_is_flagged():
    """An approximate angle must announce itself rather than read as measured."""
    marks = as_marks(project(SQUARE, tilt_deg=8.0))
    guessed = G.measure(marks, image_size=(4000, 3000))
    known = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)

    assert guessed.focal_estimated and not known.focal_estimated
    assert "approximate" in guessed.advice()
    assert "approximate" not in known.advice()


# --------------------------------------------------------------------------------------
# True dimensions for the §1.2 size gate
# --------------------------------------------------------------------------------------

def test_true_size_matches_apparent_when_square_on():
    marks = as_marks(project(SQUARE, tilt_deg=0.0))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)
    box = (slice(1200, 1800), slice(1500, 2500))
    w, h = result.true_size(box)
    assert w == pytest.approx(1000, rel=0.02)
    assert h == pytest.approx(600, rel=0.02)


def test_true_size_exceeds_apparent_on_a_foreshortened_edge():
    """
    The reason this exists: foreshortening makes a piece read shorter than it is, so a capture
    can pass or fail the §1.2 floor for the wrong reason.
    """
    marks = as_marks(project(SQUARE, tilt_deg=15.0))
    result = G.measure(marks, image_size=(4000, 3000), focal_px=3000.0)

    # Tilting about the x axis pushes the bottom of the frame away from the camera, so that is
    # where the plane is compressed. The top edge is *nearer* and therefore magnified — a box
    # there measures smaller than it looks, which is the same defect in the other direction.
    far = (slice(1700, 1900), slice(1800, 2200))
    near = (slice(1000, 1200), slice(1800, 2200))
    apparent = 200

    _, far_h = result.true_size(far)
    _, near_h = result.true_size(near)
    assert far_h > apparent, f"far edge measured {far_h:.0f}, not foreshortened"
    assert near_h < apparent, f"near edge measured {near_h:.0f}, not magnified"
    assert far_h > near_h


def test_degenerate_marks_are_refused():
    collinear = [(0.0, 0.0), (100.0, 0.0), (200.0, 0.0), (300.0, 0.0)]
    with pytest.raises((ValueError, np.linalg.LinAlgError)):
        G.measure(collinear, image_size=(4000, 3000), focal_px=3000.0)


def test_wrong_number_of_marks_is_refused():
    with pytest.raises(ValueError):
        G.measure([(0.0, 0.0), (1.0, 0.0), (1.0, 1.0)], image_size=(4000, 3000))
