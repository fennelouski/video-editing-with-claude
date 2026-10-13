"""
Source time vs timeline time (CLAUDE.md § Conventions).

Stage 3 anchors cues to the transcript, which is source time. Stage 2 then removes ~30% of
that source. Anything positioned on the timeline must be remapped. This has already caused
two separate bugs; the convention says to assume it is the cause of any "graphic in the
wrong place" report, which makes it worth pinning down hard.
"""

from __future__ import annotations

import pytest

import config as C
from fcpxml import TimelineMap


# Three keeps with two removed spans between them:
#   source 0–10  -> timeline 0–10
#   source 10–14 REMOVED
#   source 14–20 -> timeline 10–16
#   source 20–25 REMOVED
#   source 25–40 -> timeline 16–31
KEEPS = [
    {"start": 0.0, "end": 10.0},
    {"start": 14.0, "end": 20.0},
    {"start": 25.0, "end": 40.0},
]


@pytest.fixture
def tmap() -> TimelineMap:
    return TimelineMap(KEEPS)


def test_duration_is_the_sum_of_the_keeps(tmap):
    assert tmap.duration == pytest.approx(31.0)


@pytest.mark.parametrize("src,expected", [
    (0.0, 0.0),
    (5.0, 5.0),
    (9.999, 9.999),
    (14.0, 10.0),        # first frame after the first removed span
    (17.0, 13.0),
    (19.999, 15.999),
    (25.0, 16.0),        # first frame after the second removed span
    (30.0, 21.0),
    (39.999, 30.999),
])
def test_source_maps_onto_the_cut_timeline(tmap, src, expected):
    assert tmap.to_timeline(src) == pytest.approx(expected)


@pytest.mark.parametrize("src", [10.0, 12.0, 13.999, 20.0, 22.5, 24.999, 40.0, 100.0])
def test_removed_and_past_the_end_return_none(tmap, src):
    """An exact mapping must refuse rather than guess — `nearest()` is the deliberate choice."""
    assert tmap.to_timeline(src) is None


def test_mapping_is_monotonic(tmap):
    """Time cannot run backwards across a cut, whatever the keeps look like."""
    seen = [tmap.to_timeline(s / 10) for s in range(0, 400)]
    kept = [v for v in seen if v is not None]
    assert all(a < b for a, b in zip(kept, kept[1:]))


def test_mapping_never_exceeds_the_timeline(tmap):
    for s in range(0, 400):
        v = tmap.to_timeline(s / 10)
        assert v is None or 0.0 <= v <= tmap.duration


# --------------------------------------------------------------------------------------
# nearest() — the snap
# --------------------------------------------------------------------------------------

def test_nearest_is_exact_when_the_moment_survived(tmap):
    for src in (0.0, 5.0, 14.0, 17.0, 25.0, 30.0):
        mapped, snapped = tmap.nearest(src)
        assert snapped is False
        assert mapped == pytest.approx(tmap.to_timeline(src))


@pytest.mark.parametrize("src,expected", [
    (10.5, 10.0),     # just inside the removed span -> snaps back to the outgoing edge
    (13.5, 10.0),     # near the far edge -> snaps forward to the incoming edge
    (12.0, 10.0),     # dead centre — both edges map to the same timeline frame
    (21.0, 16.0),
    (24.0, 16.0),
])
def test_cue_inside_a_removed_span_snaps_to_a_surviving_frame(tmap, src, expected):
    """
    A cue anchored to footage that was cut still has to land somewhere real. Both edges of a
    removed span collapse onto the same timeline instant, which is why the expected value is
    the same from either side.
    """
    mapped, snapped = tmap.nearest(src)
    assert snapped is True
    assert mapped == pytest.approx(expected)


def test_nearest_always_lands_inside_the_timeline(tmap):
    for s in range(-50, 500):
        mapped, _ = tmap.nearest(s / 10)
        assert 0.0 <= mapped <= tmap.duration


def test_nearest_snaps_a_surviving_instant_it_can_reach(tmap):
    """
    Whatever `nearest` returns must be a moment that actually exists in the cut — not a
    timeline position that lands in the middle of nothing.
    """
    for s in range(0, 500):
        mapped, _ = tmap.nearest(s / 10)
        # every timeline position in [0, duration] is by construction covered by some keep
        assert any(
            tl <= mapped <= tl + (e - st) + 1e-9
            for st, e, tl in tmap.spans
        ), f"source {s / 10}s mapped to {mapped}, which is not inside any keep"


def test_empty_map_is_safe():
    """Stage 2 can legitimately produce nothing; the map must not raise on it."""
    empty = TimelineMap([])
    assert empty.duration == 0.0
    assert empty.to_timeline(5.0) is None
    assert empty.nearest(5.0) == (0.0, True)


def test_single_uncut_keep_is_identity():
    whole = TimelineMap([{"start": 0.0, "end": 30.0}])
    for s in range(0, 300):
        assert whole.to_timeline(s / 10) == pytest.approx(s / 10)


def test_map_from_a_real_stage2_edl(edl, words):
    """
    The same invariants against Stage 2's actual output rather than a hand-built map —
    keeps that came out of the breath floor, retake and filler passes.
    """
    tmap = TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])
    assert tmap.duration > 0
    assert tmap.duration <= max(w["end"] for w in words) + 0.5

    kept = [tmap.to_timeline(w["start"]) for w in words]
    kept = [v for v in kept if v is not None]
    assert kept, "every word was cut — the fixture or the EDL is wrong"
    assert all(a <= b for a, b in zip(kept, kept[1:])), "word order inverted across a cut"
    assert all(0.0 <= v <= tmap.duration for v in kept)


def test_snapped_cues_stay_on_the_frame_grid(edl):
    """
    Stage 5 snaps every remapped cue with C.snap_seconds before writing it. A snap that
    lands off the grid is [S-007] all over again.
    """
    tmap = TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])
    for s in range(0, int(tmap.duration * 10) + 40):
        mapped, _ = tmap.nearest(s / 10)
        snapped = C.snap_seconds(mapped)
        assert C.frames(snapped) * C.FPS_DEN / C.FPS_NUM == pytest.approx(snapped, abs=1e-9)
