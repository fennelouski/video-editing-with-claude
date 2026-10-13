"""
stepclock.py — the stop-motion timing core.

taste_principles §5: the master runs at 23.976 fps (24000/1001), but the graphic layer
**steps on 2s** — a new position every 2nd frame, ~11.99 unique positions per second. If any
graphic element moves on an odd frame, the illusion breaks and the whole composition reads as
After Effects. The timebase is never 24.000; see style_guide [S-007].

§5.2: even a "static" element carries micro-jitter, because a real hand touched the set
between exposures. A perfectly static graphic is a bug.

All randomness is a seeded, deterministic hash — the same element at the same frame always
yields the same offset, so renders are reproducible and resumable.
"""

from __future__ import annotations

import hashlib
import math
import struct
from dataclasses import dataclass

import config as C


# --------------------------------------------------------------------------------------
# Deterministic noise
# --------------------------------------------------------------------------------------

def _hash_unit(*parts: object) -> float:
    """Stable float in [0, 1) from any set of keys. Not random — reproducible."""
    key = "|".join(str(p) for p in parts).encode("utf-8")
    digest = hashlib.blake2b(key, digest_size=8, key=struct.pack("<q", C.SEED)).digest()
    return struct.unpack("<Q", digest)[0] / 2**64


def signed(*parts: object) -> float:
    """Stable float in [-1, 1)."""
    return _hash_unit(*parts) * 2.0 - 1.0


# --------------------------------------------------------------------------------------
# The clock
# --------------------------------------------------------------------------------------

class StepClock:
    """
    Quantizes a frame index onto the stop-motion grid.

        clock = StepClock()
        clock.step(37)      -> 36     (positions only update on even frames)
        clock.is_hold(37)   -> True   (frame 37 reuses frame 36's composite)

    Stage 5 renders one image per *step* and duplicates it across the held frames, which is
    both correct and roughly 2x cheaper than rendering every frame.
    """

    # fps is a float and must stay one: C.FPS is 24000/1001, and an int coercion here would
    # silently make every frames_for() call compute against 24.000 — [S-007] reintroduced at
    # the one place the whole graphic layer is timed from.
    def __init__(self, fps: float = C.FPS, step: int = C.GRAPHIC_STEP):
        self.fps = fps
        self.step = step

    def step_frame(self, frame: int) -> int:
        return (frame // self.step) * self.step

    def is_hold(self, frame: int) -> bool:
        return frame % self.step != 0

    def step_index(self, frame: int) -> int:
        return frame // self.step

    def seconds(self, frame: int) -> float:
        return frame / self.fps

    def frames_for(self, seconds: float) -> int:
        return max(1, round(seconds * self.fps))

    def steps_for(self, seconds: float) -> int:
        return max(1, math.ceil(self.frames_for(seconds) / self.step))

    def on_step(self, frames: int) -> int:
        """
        Round a frame count UP onto the step grid.

        §5.1 — it isn't enough to *sample* on the step; every phase boundary has to land on
        one too. A 47-frame hold is 23.5 steps, so the exit starts half a step out of phase:
        the entire pull-off then lands on odd frames and truncates before it reaches opacity
        0. Up rather than to-nearest, because §5.4 hold is a floor and rounding down would
        breach it. See style_guide [S-010].
        """
        return frames + (-frames % self.step)

    def hold_frames(self, seconds: float) -> int:
        """
        Hold length in frames, on the step grid. The one way to derive a graphic's hold.

        Ceil, not frames_for()'s round: §5.4 states a *minimum* hold and §12 check 4 fails a
        graphic that holds for less. Rounding 1.6 s to nearest gives 38 frames = 1.585 s,
        which is under the floor the formula just set.
        """
        return self.on_step(max(1, math.ceil(seconds * self.fps - 1e-9)))


# --------------------------------------------------------------------------------------
# Transforms
# --------------------------------------------------------------------------------------

@dataclass
class Transform:
    x: float = 0.0
    y: float = 0.0
    rotation: float = 0.0
    scale: float = 1.0
    opacity: float = 1.0

    def merged(self, other: "Transform") -> "Transform":
        return Transform(
            x=self.x + other.x,
            y=self.y + other.y,
            rotation=self.rotation + other.rotation,
            scale=self.scale * other.scale,
            opacity=self.opacity * other.opacity,
        )


def idle_jitter(element_id: str, frame: int, clock: StepClock) -> Transform:
    """
    §5.2 — continuous micro-jitter, resampled on the step clock.
    Each element gets its own seed offset; synchronised jitter looks like an earthquake.
    """
    s = clock.step_index(frame)
    scale_bucket = frame // (C.IDLE_JITTER_SCALE_EVERY)
    return Transform(
        x=signed(element_id, "jx", s) * C.IDLE_JITTER_XY_PX,
        y=signed(element_id, "jy", s) * C.IDLE_JITTER_XY_PX,
        rotation=signed(element_id, "jr", s) * C.IDLE_JITTER_ROT_DEG,
        scale=1.0 + signed(element_id, "js", scale_bucket) * C.IDLE_JITTER_SCALE,
    )


def resting_pose(element_id: str, neighbor_index: int = 0) -> Transform:
    """
    §2.3 — the imperfection budget. Every element sits slightly off-square and off-grid.

    Adjacent elements must not share a rotation sign: if one leans left the next leans
    right. Uniform tilt reads as a filter, which is worse than no tilt at all.
    """
    span = C.ROTATION_MAX_DEG - C.ROTATION_MIN_DEG
    magnitude = C.ROTATION_MIN_DEG + _hash_unit(element_id, "rot") * span
    sign = 1.0 if neighbor_index % 2 == 0 else -1.0

    lo, hi = C.SCALE_VARIANCE
    return Transform(
        x=signed(element_id, "px") * C.POSITION_JITTER_MAX_PX,
        y=signed(element_id, "py") * C.POSITION_JITTER_MAX_PX,
        rotation=magnitude * sign,
        scale=lo + _hash_unit(element_id, "sc") * (hi - lo),
    )


# --------------------------------------------------------------------------------------
# Entrance / exit
# --------------------------------------------------------------------------------------

# §5.3 — "arrive from ~40 px above with a 2-frame settle overshoot".
#
# The spec fixes the settle's *duration* and not its amplitude, and at a 40 px rise the two
# pull against each other: tuned to overshoot for exactly one step (2 frames) the piece passes
# rest by 0.45 px, which is invisible at 1080p and so fails the purpose §5.3 states for it —
# "so it looks set down, not slid in". This value overshoots ~2 px across two steps: visible,
# and the closest thing to the stated intent that can actually be seen. See [S-018].
SETTLE_OVERSHOOT = 1.2


def _step_ease(p: float) -> float:
    """
    Settle *past* rest, then come back — quantized by the caller onto the step grid.

    The overshoot is the whole point. §5.3 asks for a 2-frame settle so a placed piece looks
    set down by a hand; without it a graphic glides to a stop, which is the eased After Effects
    motion §5.5 bans outright.

    The previous formula, `1 - (1-p)³ + 0.06·sin(πp)·(1-p)`, claimed to peak at 1.06 and in
    fact peaked at **1.0009** — an overshoot of 0.036 px. Its two terms could never combine
    above 1: the sine term peaks near p=0.3 while the base curve is still at 0.66, and by the
    time the base approaches 1 the (1-p) factor has crushed the sine to nothing. Every graphic
    the pipeline has placed arrived without a settle. See [S-018].

    This is the standard back-out curve, which resolves to exactly 1.0 at p=1 so a piece always
    ends at rest rather than a fraction of a pixel off it.
    """
    p = max(0.0, min(1.0, p))
    c1 = SETTLE_OVERSHOOT
    c3 = c1 + 1.0
    return 1.0 + c3 * (p - 1.0) ** 3 + c1 * (p - 1.0) ** 2


def place_in(element_id: str, frames_elapsed: int, duration_frames: int, clock: StepClock) -> Transform:
    """
    §5.3 — objects are *placed*, not faded. They arrive from ~40px above with a settle
    overshoot and a small rotation change, so they look set down rather than slid in.
    """
    if frames_elapsed >= duration_frames:
        return Transform()
    stepped = clock.step_frame(frames_elapsed)
    p = _step_ease(stepped / max(1, duration_frames))

    lo, hi = C.SETTLE_ROTATION_DEG
    settle_rot = lo + _hash_unit(element_id, "settle") * (hi - lo)
    settle_rot *= 1.0 if _hash_unit(element_id, "settledir") > 0.5 else -1.0

    return Transform(
        y=(1 - p) * -C.RISE_PX,
        rotation=(1 - p) * settle_rot,
        # Opacity snaps on within 2 steps — paper doesn't dissolve, but a 1-frame hard pop
        # aliases badly against the grain pass.
        opacity=min(1.0, (stepped / max(1, clock.step * 2)) if duration_frames > 2 else 1.0),
    )


def pop_in(frames_elapsed: int, duration_frames: int = 2) -> Transform:
    """Alternate entrance for small labels and marks — appears, no movement."""
    return Transform(opacity=1.0 if frames_elapsed >= duration_frames else 0.0)


def remove_out(
    element_id: str, frames_elapsed: int, duration_frames: int, clock: StepClock,
    direction: tuple[float, float] = (-1.0, 0.0),
) -> Transform:
    """Pulled off frame in a consistent direction over 4–6 frames (§5.3). Never a cross-fade."""
    if frames_elapsed <= 0:
        return Transform()
    stepped = clock.step_frame(frames_elapsed)
    p = min(1.0, stepped / max(1, duration_frames))
    travel = p * p * 260.0
    return Transform(
        x=direction[0] * travel,
        y=direction[1] * travel,
        rotation=p * signed(element_id, "exitrot") * 6.0,
        opacity=1.0 if p < 0.85 else 0.0,
    )


def stagger_offset(index: int) -> int:
    """§5.3 — 4 frames between siblings, capped at 5 items."""
    return min(index, C.STAGGER_MAX_ITEMS - 1) * C.STAGGER_FRAMES


# --------------------------------------------------------------------------------------
# Composed pose for a cutout at a given frame
# --------------------------------------------------------------------------------------

def pose_at(
    element_id: str,
    frame: int,
    *,
    start_frame: int,
    hold_frames: int,
    clock: StepClock,
    neighbor_index: int = 0,
    entrance: str = "place",
    exit_direction: tuple[float, float] = (-1.0, 0.0),
) -> Transform | None:
    """
    Full transform for one cutout at one frame, or None if it isn't on screen.

    Layers: resting pose (§2.3) + entrance/exit (§5.3) + idle jitter (§5.2).
    """
    place_frames = C.PLACE_FRAMES[1]
    remove_frames = C.REMOVE_FRAMES[1]

    # §5.1 — sample at t_step, never at frame. Quantising here rather than inside each phase
    # helper is what makes that true: the helpers count from the start of their *own* phase,
    # so an unaligned hold flips the parity of everything after it. Entrance never showed the
    # bug because PLACE_FRAMES and every stagger_offset happen to be even. See [S-010].
    hold_frames = clock.on_step(hold_frames)
    local = clock.step_frame(frame) - start_frame
    total = place_frames + hold_frames + remove_frames

    if local < 0 or local > total:
        return None

    pose = resting_pose(element_id, neighbor_index)

    if local < place_frames:
        if entrance == "pop":
            pose = pose.merged(pop_in(local, C.POP_FRAMES[0]))
        else:
            pose = pose.merged(place_in(element_id, local, place_frames, clock))
    elif local > place_frames + hold_frames:
        out_elapsed = local - (place_frames + hold_frames)
        pose = pose.merged(remove_out(element_id, out_elapsed, remove_frames, clock, exit_direction))

    return pose.merged(idle_jitter(element_id, frame, clock))


def variant_for(element_id: str, frame: int, variant_count: int, clock: StepClock) -> int:
    """
    Cycle through her 4–6 captured variants on the step clock (§1.2). This is what makes the
    jitter genuinely real rather than a digital wobble — it's the actual piece, re-photographed.
    """
    if variant_count <= 1:
        return 0
    return int(_hash_unit(element_id, "var", clock.step_index(frame)) * variant_count) % variant_count
