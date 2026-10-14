"""Read-only runtime gates for retained narration, never an instruction to trim speech."""
from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from xml.parsers import expat

import config as C


class DurationReviewRequired(ValueError):
    """A cut needs an editorial decision before assets or rendering can continue."""


@dataclass(frozen=True)
class DurationBounds:
    minimum: float | None = None
    maximum: float | None = None

    def __post_init__(self) -> None:
        for name, value in (("--min-duration", self.minimum), ("--max-duration", self.maximum)):
            if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float))
                                      or not math.isfinite(value) or value <= 0):
                raise ValueError(f"{name} must be a finite, positive number of seconds")
        if self.minimum is not None and self.maximum is not None and self.minimum > self.maximum:
            raise ValueError("--min-duration must not exceed --max-duration")

    @property
    def enabled(self) -> bool:
        return self.minimum is not None or self.maximum is not None

    def check(self, duration: float, *, label: str = "retained narration") -> None:
        if not math.isfinite(duration) or duration <= 0:
            raise DurationReviewRequired("Duration review required: the retained cut has no valid duration. Re-run stage 2.")
        # Absorb floating-point arithmetic only; the bound does not gain a frame of slack.
        if self.minimum is not None and duration < self.minimum - 1e-9:
            raise DurationReviewRequired(
                f"Duration review required: {label} is {duration:.3f}s, below the minimum "
                f"{self.minimum:.3f}s by {self.minimum - duration:.3f}s. Add or select complete narration, "
                "or revise the minimum. The pipeline will not pad or retime the cut.")
        if self.maximum is not None and duration > self.maximum + 1e-9:
            raise DurationReviewRequired(
                f"Duration review required: {label} is {duration:.3f}s, above the maximum "
                f"{self.maximum:.3f}s by {duration - self.maximum:.3f}s. Review whole takes or sentences, "
                "or revise the maximum. The pipeline will not retime or clip sentences.")


def retained_duration(edl: dict) -> float:
    """Match stage 5's primary storyline endpoints on the configured frame grid.

    A cached cut_duration is a rounded summary, not evidence of what FCP will receive.
    Offsets round cumulative retained time; each clip duration rounds independently.
    """
    keeps = edl.get("keeps") if isinstance(edl, dict) else None
    if not isinstance(keeps, list) or not keeps:
        raise ValueError("the edit list has no retained spans")
    cursor, prior, total_frames = 0.0, 0.0, 0
    for span in keeps:
        if not isinstance(span, dict):
            raise ValueError("the edit list contains an invalid retained span")
        start, end = span.get("start"), span.get("end")
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)
               for v in (start, end)) or start < prior or end <= start:
            raise ValueError("the edit list contains invalid or overlapping retained times")
        frames = C.frames(end - start)
        if frames <= 0 or not math.isfinite(cursor + (end - start)):
            raise ValueError("the edit list contains a span shorter than one frame or an invalid total")
        total_frames = max(total_frames, C.frames(cursor) + frames)
        cursor += end - start
        prior = end
    return total_frames * C.FPS_DEN / C.FPS_NUM


def check_roughcut(roughcut: Path, bounds: DurationBounds, *, assembly: bool = False) -> float | None:
    """Select the same EDL as stage 5, refusing ambiguous or missing selections."""
    if not bounds.enabled:
        return None
    path = roughcut
    try:
        if assembly:
            from multisource import EDL
            path = roughcut / EDL
            if not path.is_file():
                raise DurationReviewRequired(
                    "Duration review required: the approved narration assembly has no selected edit list. "
                    "Re-run stage 2 for that source order; per-source edits cannot substitute for the assembly.")
        else:
            paths = sorted(roughcut.glob("*.edl.json"))
            if len(paths) != 1:
                raise DurationReviewRequired(
                    f"Duration review required: found {len(paths)} unassembled edit lists. "
                    "Select one narration source or an explicit ordered assembly, then re-run stage 2.")
            path = paths[0]
        if not path.resolve().is_relative_to(roughcut.resolve()):
            raise ValueError("the selected edit list escapes the rough-cut folder")
        duration = retained_duration(json.loads(path.read_text()))
    except DurationReviewRequired:
        raise
    except (OSError, ValueError, OverflowError, RuntimeError) as exc:
        raise DurationReviewRequired(
            f"Duration review required: cannot verify {path.name}: {exc}. Re-run stage 2 before rendering.") from exc
    bounds.check(duration)
    return duration


def expected_final_output(exports: Path, project: str) -> Path:
    """Stage 5 writes this exact leaf; a neighboring export cannot stand in for it."""
    try:
        if not project or Path(project).name != project or project in (".", ".."):
            raise ValueError("the project name must be a single filename")
        path = exports / f"{project}.fcpxml"
        if path.is_symlink() or path.resolve().parent != exports.resolve():
            raise ValueError("the expected final timeline escapes or aliases another output")
        return path
    except (OSError, ValueError, RuntimeError) as exc:
        raise DurationReviewRequired(f"Duration review required: cannot select the final timeline: {exc}.") from exc


def final_sequence_duration(data: bytes) -> float:
    """Read one final project sequence without resolving a DTD or any XML entities.

    Expat callbacks apply equally to UTF-8 and UTF-16, avoiding a byte-scan bypass.
    The engine's bare <!DOCTYPE fcpxml> is allowed; subsets and external declarations are not.
    """
    parser = expat.ParserCreate()
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    stack, durations = [], []

    def refuse_entities(*args):
        raise ValueError("XML entity declarations and external references are not allowed")

    def doctype(name, system, public, subset):
        if name != "fcpxml" or system is not None or public is not None or subset:
            raise ValueError("only the engine's bare fcpxml DOCTYPE is allowed")

    def start(name, attrs):
        if not stack and name != "fcpxml":
            raise ValueError("the final timeline must be an fcpxml document")
        stack.append(name)
        if stack == ["fcpxml", "library", "event", "project", "sequence"]:
            durations.append(attrs.get("duration"))

    parser.StartDoctypeDeclHandler = doctype
    parser.EntityDeclHandler = refuse_entities
    parser.ExternalEntityRefHandler = refuse_entities
    parser.StartElementHandler = start
    parser.EndElementHandler = lambda name: stack.pop()
    parser.Parse(data, True)
    if len(durations) != 1:
        raise ValueError("the final timeline must contain exactly one project sequence")
    value = durations[0]
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:/[0-9]+)?s", value):
        raise ValueError("the final sequence has no finite rational duration in seconds")
    duration = float(Fraction(value[:-1]))
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("the final sequence duration must be finite and positive")
    return duration


def check_final_output(exports: Path, project: str, bounds: DurationBounds) -> float | None:
    """Check emitted bytes before the orchestrator reports composite success."""
    if not bounds.enabled:
        return None
    path = expected_final_output(exports, project)
    try:
        duration = final_sequence_duration(path.read_bytes())
    except (OSError, ValueError, ArithmeticError, expat.ExpatError) as exc:
        raise DurationReviewRequired(
            f"Duration review required: cannot verify emitted {path.name}: {exc}. "
            "Re-run stage 5 before accepting this cut.") from exc
    bounds.check(duration, label="emitted final timeline")
    return duration
