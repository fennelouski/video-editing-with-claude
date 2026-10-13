"""
Timebase invariants (style_guide [S-007], non-negotiable 3).

`fcpxml.validate()` rejects any time value that isn't a multiple of 1001/24000, so these
tests exist to catch an off-grid value at the source rather than at the far end of a render.
"""

from __future__ import annotations

import pytest

import config as C


# A spread of awkward values: exact frame boundaries, values that land mid-frame, values
# whose float representation is not exact, and the long durations where drift accumulates.
SECONDS = [
    0.0, 0.001, 0.0417, 0.5, 1.0, 1.001, 1.6, 2.5, 3.14159,
    23.976, 24.0, 59.94, 60.0, 100.7, 599.5, 1200.0, 3600.0,
]


def parse_rational(value: str) -> tuple[int, int]:
    assert value.endswith("s"), f"{value!r} is not an FCPXML time"
    if "/" not in value:
        assert value == "0s", f"{value!r} is a bare non-zero time"
        return 0, C.FCPXML_TIMESCALE
    num, den = value[:-1].split("/")
    return int(num), int(den)


@pytest.mark.parametrize("seconds", SECONDS)
def test_fcp_time_lands_on_the_frame_grid(seconds):
    num, den = parse_rational(C.fcp_time(seconds))
    assert den == C.FCPXML_TIMESCALE
    assert num % C.FCPXML_FRAME_TICKS == 0, (
        f"{seconds}s -> {num}/{den}s is off the grid; FCP shifts or rejects this"
    )


@pytest.mark.parametrize("seconds", SECONDS)
def test_fcp_duration_lands_on_the_frame_grid(seconds):
    num, den = parse_rational(C.fcp_duration(seconds))
    assert den == C.FCPXML_TIMESCALE
    assert num % C.FCPXML_FRAME_TICKS == 0


@pytest.mark.parametrize("seconds", SECONDS)
def test_fcp_duration_is_never_zero(seconds):
    """FCP silently drops a zero-duration element, taking the graphic with it."""
    num, _ = parse_rational(C.fcp_duration(seconds))
    assert num >= C.FCPXML_FRAME_TICKS


def test_frame_grid_holds_across_a_long_sweep():
    """
    Every frame of a 20-minute video. Drift only shows up at length, which is exactly where
    a manual spot-check stops looking.
    """
    for frame in range(0, int(20 * 60 * C.FPS), 7):
        seconds = frame * C.FPS_DEN / C.FPS_NUM
        num, den = parse_rational(C.fcp_time(seconds))
        assert den == C.FCPXML_TIMESCALE
        assert num % C.FCPXML_FRAME_TICKS == 0
        assert num // C.FCPXML_FRAME_TICKS == frame, f"frame {frame} round-tripped to {num}"


def test_snap_seconds_is_idempotent():
    for seconds in SECONDS:
        once = C.snap_seconds(seconds)
        assert C.snap_seconds(once) == pytest.approx(once, abs=1e-12)


def test_timebase_is_not_integer_24():
    """
    [S-007] — the T3i, R100 and RP all record "24p" as 23.976. A true-24 timeline against
    23.976 media drifts audio progressively across a long take.
    """
    assert (C.FPS_NUM, C.FPS_DEN) == (24000, 1001)
    assert C.FPS != 24.0
    assert C.FRAME_DURATION == "1001/24000s"


def test_fps_str_is_rational_not_float():
    """
    Never write a float frame rate into an ffmpeg argument (non-negotiable 3). `-r 23.976`
    writes a 23976/1000 timebase and every downstream time lands off the grid.
    """
    assert C.FPS_STR == "24000/1001"
    assert "." not in C.FPS_STR


def test_hold_seconds_matches_the_documented_formula():
    """§5.4 — hold = max(1.6, words/2.8 + 0.8). A 10-word callout holds 4.4 s."""
    assert C.hold_seconds(0) == pytest.approx(1.6)
    assert C.hold_seconds(1) == pytest.approx(1.6)
    assert C.hold_seconds(10) == pytest.approx(4.371428, abs=1e-5)
    assert C.hold_seconds(28) == pytest.approx(10.8)
    # monotonic — more words never means less time on screen
    holds = [C.hold_seconds(n) for n in range(0, 80)]
    assert all(a <= b for a, b in zip(holds, holds[1:]))
