"""
Stop-motion timing invariants (taste_principles §2.3, §5.1, §5.2).

Non-negotiable 6 is the one this file exists for: a new position every 2nd frame and never
on an odd one. Everything else here guards the imperfection budget, which looks like a bug
and is the product.
"""

from __future__ import annotations

import pytest

import config as C
import stepclock as SC


ELEMENTS = ["c001:yeast_cell", "c002:thermometer", "c003:loaf", "c004:jar"]


@pytest.fixture
def clock() -> SC.StepClock:
    return SC.StepClock()


# --------------------------------------------------------------------------------------
# Determinism  (CLAUDE.md § Conventions)
# --------------------------------------------------------------------------------------

def test_jitter_is_reproducible(clock):
    """The same element at the same frame must always yield the same offset."""
    for frame in range(0, 60):
        a = SC.idle_jitter("c001:yeast_cell", frame, clock)
        b = SC.idle_jitter("c001:yeast_cell", frame, clock)
        assert a == b


def test_jitter_differs_per_element(clock):
    """§5.2 — synchronised jitter looks like an earthquake, not a hand touching the set."""
    for frame in (0, 8, 24, 50):
        poses = [SC.idle_jitter(e, frame, clock) for e in ELEMENTS]
        xs = {round(p.x, 6) for p in poses}
        ys = {round(p.y, 6) for p in poses}
        assert len(xs) == len(ELEMENTS), f"frame {frame}: elements share an x offset"
        assert len(ys) == len(ELEMENTS), f"frame {frame}: elements share a y offset"


def test_resting_pose_is_reproducible():
    for e in ELEMENTS:
        assert SC.resting_pose(e, 0) == SC.resting_pose(e, 0)


# --------------------------------------------------------------------------------------
# The imperfection budget  (§2.3, §5.2)
# --------------------------------------------------------------------------------------

def test_idle_jitter_within_budget(clock):
    for e in ELEMENTS:
        for frame in range(0, 240):
            p = SC.idle_jitter(e, frame, clock)
            assert abs(p.x) <= C.IDLE_JITTER_XY_PX
            assert abs(p.y) <= C.IDLE_JITTER_XY_PX
            assert abs(p.rotation) <= C.IDLE_JITTER_ROT_DEG
            assert abs(p.scale - 1.0) <= C.IDLE_JITTER_SCALE


def test_resting_pose_within_budget():
    for e in ELEMENTS:
        for n in range(6):
            p = SC.resting_pose(e, n)
            assert C.ROTATION_MIN_DEG <= abs(p.rotation) <= C.ROTATION_MAX_DEG
            assert abs(p.rotation) < C.ROTATION_HARD_MAX_DEG
            assert abs(p.x) <= C.POSITION_JITTER_MAX_PX
            assert abs(p.y) <= C.POSITION_JITTER_MAX_PX
            assert C.SCALE_VARIANCE[0] <= p.scale <= C.SCALE_VARIANCE[1]


def test_resting_rotation_is_never_exactly_zero():
    """§10 — an element at exactly 0° is a listed anti-AI checklist failure."""
    for e in ELEMENTS + [f"synthetic:{i}" for i in range(400)]:
        for n in range(4):
            assert SC.resting_pose(e, n).rotation != 0.0


def test_resting_rotation_alternates_sign_between_neighbours():
    """
    §2.3 — if one element leans left its neighbour leans right. Uniform tilt reads as a
    filter, which is worse than no tilt at all.
    """
    for e in ELEMENTS:
        signs = [SC.resting_pose(e, n).rotation > 0 for n in range(8)]
        assert all(a != b for a, b in zip(signs, signs[1:])), f"{e} does not alternate"


# --------------------------------------------------------------------------------------
# Stepping on 2s  (§5.1 — non-negotiable 6)
# --------------------------------------------------------------------------------------

def test_step_frame_quantises_to_even_frames(clock):
    for frame in range(0, 200):
        assert clock.step_frame(frame) % C.GRAPHIC_STEP == 0
        assert clock.step_frame(frame) <= frame
        assert frame - clock.step_frame(frame) < C.GRAPHIC_STEP


def test_idle_jitter_only_changes_on_even_frames(clock):
    """An odd frame must reuse the previous even frame's sample, exactly."""
    for e in ELEMENTS:
        for even in range(0, 240, 2):
            assert SC.idle_jitter(e, even, clock) == SC.idle_jitter(e, even + 1, clock), (
                f"{e}: jitter moved on odd frame {even + 1}"
            )


# Both parities, deliberately. `hold_frames` comes from clock.frames_for(hold_seconds) and is
# odd about half the time; an even-only sweep hides a whole class of parity bug ([S-010]).
@pytest.mark.parametrize("hold", [1, 12, 37, 38, 47, 48, 63, 64])
def test_pose_only_changes_on_even_frames(clock, hold):
    """
    The composed pose — resting + entrance/exit + jitter — must hold across every odd frame,
    through the place, hold and remove phases alike, for any hold length.

    Non-negotiable 6: if anything in the graphic layer moves on an odd frame, the stop-motion
    illusion breaks and the composition reads as After Effects.
    """
    for i, e in enumerate(ELEMENTS):
        start = SC.stagger_offset(i)
        total = C.PLACE_FRAMES[1] + hold + C.REMOVE_FRAMES[1] + start
        for even in range(0, total + 2, 2):
            a = SC.pose_at(e, even, start_frame=start, hold_frames=hold, clock=clock,
                           neighbor_index=i)
            b = SC.pose_at(e, even + 1, start_frame=start, hold_frames=hold, clock=clock,
                           neighbor_index=i)
            assert a == b, (
                f"{e}: pose moved on odd frame {even + 1} "
                f"(start_frame={start}, hold_frames={hold})"
            )


def test_stagger_offsets_stay_on_the_step_grid():
    """
    A stagger that lands a sibling on an odd frame would break the step for that element
    only — the hardest version of this bug to see, because the composition still mostly
    looks right (§5.3).
    """
    for i in range(12):
        assert SC.stagger_offset(i) % C.GRAPHIC_STEP == 0
        assert SC.stagger_offset(i) <= (C.STAGGER_MAX_ITEMS - 1) * C.STAGGER_FRAMES


def test_variant_cycle_is_deterministic_and_in_range(clock):
    """§1.2 — the jitter cycle walks her 4–6 real captures, so it must stay in bounds."""
    for e in ELEMENTS:
        for frame in range(0, 120):
            v = SC.variant_for(e, frame, 5, clock)
            assert 0 <= v < 5
            assert v == SC.variant_for(e, frame, 5, clock)


def test_variant_only_changes_on_even_frames(clock):
    for e in ELEMENTS:
        for even in range(0, 120, 2):
            assert SC.variant_for(e, even, 5, clock) == SC.variant_for(e, even + 1, 5, clock)


# --------------------------------------------------------------------------------------
# Entrance / exit  (§5.3)
# --------------------------------------------------------------------------------------

def test_pose_is_absent_outside_its_window(clock):
    """
    The window closes on the step grid, not on the exact frame.

    An odd frame after the last step reuses that step's composite — which is what stepping
    on 2s *means* — so it comes back as a pose at opacity 0 rather than as None. Both read
    as absent on screen; the distinction only matters to the renderer's frame cache.
    """
    hold = 24
    total = C.PLACE_FRAMES[1] + clock.on_step(hold) + C.REMOVE_FRAMES[1]

    assert SC.pose_at("c001", -1, start_frame=0, hold_frames=hold, clock=clock) is None
    assert SC.pose_at("c001", total, start_frame=0, hold_frames=hold, clock=clock) is not None

    held = SC.pose_at("c001", total + 1, start_frame=0, hold_frames=hold, clock=clock)
    assert held is not None and held.opacity == 0.0, "the held odd frame must be invisible"
    assert SC.pose_at("c001", total + 2, start_frame=0, hold_frames=hold, clock=clock) is None


@pytest.mark.parametrize("hold", [1, 12, 37, 38, 47, 48, 63, 64])
def test_exit_completes_invisible(clock, hold):
    """
    Whatever the hold length, the element must reach opacity 0 before its window closes —
    otherwise it vanishes at full opacity partway through the pull-off, which is the hard
    pop §5.3 exists to prevent.
    """
    total = C.PLACE_FRAMES[1] + clock.on_step(hold) + C.REMOVE_FRAMES[1]
    last = SC.pose_at("c001", total, start_frame=0, hold_frames=hold, clock=clock)
    assert last is not None and last.opacity == 0.0, f"hold={hold} ends still visible"


def test_on_step_rounds_up_onto_the_grid(clock):
    """
    Up, never to-nearest: §5.4 hold is a floor, so rounding down would breach the minimum
    hold the formula just calculated.
    """
    for n in range(0, 200):
        stepped = clock.on_step(n)
        assert stepped % C.GRAPHIC_STEP == 0
        assert stepped >= n
        assert stepped - n < C.GRAPHIC_STEP


def test_hold_frames_never_below_the_formula(clock):
    """A hold rounded onto the grid must still satisfy the §5.4 minimum it came from."""
    for words in range(0, 60):
        seconds = C.hold_seconds(words)
        assert clock.hold_frames(seconds) / C.FPS >= seconds - 1e-9


def test_place_in_resolves_to_rest(clock):
    """The settle must actually land — a place that never resolves leaves the piece askew."""
    p = SC.place_in("c001", C.PLACE_FRAMES[1], C.PLACE_FRAMES[1], clock)
    assert p == SC.Transform()


def test_the_settle_actually_overshoots(clock):
    """
    §5.3 — "a 2-frame settle overshoot", so a piece looks set down rather than slid in.

    The original curve claimed a 1.06 peak in its docstring and delivered 1.0009: an overshoot
    of 0.036 px, which is no overshoot at all. Every graphic the pipeline placed glided to rest,
    which is the eased motion §5.5 bans. Asserted on the rendered position rather than on the
    easing function, because that is what a viewer sees. See [S-018].
    """
    past_rest = [SC.place_in("probe", f, C.PLACE_FRAMES[1], clock).y
                 for f in range(0, C.PLACE_FRAMES[1] + 1, C.GRAPHIC_STEP)]
    overshoot = max(past_rest)
    assert overshoot > 1.0, (
        f"the piece never passes rest (max {overshoot:+.3f} px) — it is gliding to a stop, "
        f"not being set down"
    )
    assert overshoot < C.RISE_PX * 0.15, "the settle is a bounce, not a second arrival"


def test_the_settle_resolves_to_exactly_rest(clock):
    """A piece that ends a fraction of a pixel off rest never stops moving during its hold."""
    for place_frames in (6, 8, 10):
        assert SC.place_in("probe", place_frames, place_frames, clock) == SC.Transform()
        assert SC._step_ease(1.0) == pytest.approx(1.0, abs=1e-12)


def test_the_piece_reaches_the_surface_before_the_animation_ends(clock):
    """
    Contact is what the foley hit keys off (§8), so it has to happen at a real moment rather
    than at the end of the animation by default.
    """
    contact = next((f for f in range(0, C.PLACE_FRAMES[1] + 1, C.GRAPHIC_STEP)
                    if SC.place_in("probe", f, C.PLACE_FRAMES[1], clock).y >= 0.0), None)
    assert contact is not None and contact < C.PLACE_FRAMES[1]


def test_place_in_arrives_from_above(clock):
    """§5.3 — objects are placed, arriving from ~40 px above, never faded in."""
    p = SC.place_in("c001", 0, C.PLACE_FRAMES[1], clock)
    assert p.y == pytest.approx(-C.RISE_PX, abs=1.0)
    assert abs(p.rotation) >= C.SETTLE_ROTATION_DEG[0] * 0.9
