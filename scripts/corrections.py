"""
corrections.py — read style_guide.md, and refuse to run on an entry that teaches nothing.

Stages 3–5 treat every `ACTIVE` entry as a binding constraint ranked above their own defaults.
Stage 6 appends entries automatically, and the rule line it writes is a placeholder:
*"write this as a testable rule before the next run."*

So an unfilled entry is a constraint that constrains nothing while looking exactly like one
that does. It is the same defect as `reviewed_by: "unreviewed"` — a placeholder satisfies the
check while carrying none of the meaning the check exists to enforce — and it arrives by the
same route: something auto-generated that nobody circled back to. style_guide [S-016].

The README has said "an entry without a testable rule teaches the pipeline nothing" since the
first commit. Nothing enforced it. This does, by refusing rather than warning: a warning at the
top of a run that produces output anyway is a warning nobody reads twice.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import config as C


# [S-016]'s denylist. Matched against the *whole* field, not searched inside it — a field is a
# placeholder when it *is* one, not when it mentions one. [S-016]'s own Auto-check line reads
# "a loader-level scan for placeholder text…", which a substring search flags as unfilled. A
# gate that blocks a correctly written rule is worse than no gate: it trains people to bypass it.
PLACEHOLDER_PATTERNS = (
    r"unreviewed", r"to\s*do", r"tbd", r"change\s*me", r"x{3,}",
    r"placeholder", r"n/?a", r"fixme", r"none", r"[—–-]+",
)

_WHOLE_PLACEHOLDER = re.compile(
    r"^[\s_*`.:—-]*(" + "|".join(PLACEHOLDER_PATTERNS) + r")[\s_*`.!:—-]*$", re.I
)

# The exact sentence Stage 6 writes into every entry it generates. Searched anywhere in the
# field, because it is unambiguous: nothing else says this, and its presence means a human has
# not been back to the entry since it was written.
_STAGE6_MARKER = re.compile(r"write this as a testable rule", re.I)

ENTRY = re.compile(r"^### \[(?P<id>[^\]]+)\]\s*—\s*(?P<title>.*?)$", re.M)
FIELD = re.compile(r"^-\s+\*\*(?P<key>[^:*]+):\*\*\s*(?P<value>.*)$", re.M)

# The fields that carry the meaning. A placeholder anywhere else is untidy; a placeholder here
# is a rule the pipeline cannot follow.
LOAD_BEARING = ("the rule going forward", "auto-check")


@dataclass(frozen=True)
class Correction:
    id: str
    title: str
    status: str
    category: str
    rule: str
    auto_check: str

    @property
    def is_active(self) -> bool:
        return self.status.upper() == "ACTIVE"

    def placeholders(self) -> list[str]:
        """Which load-bearing fields are still unfilled, if any."""
        out = []
        for label, value in (("the rule going forward", self.rule),
                             ("auto-check", self.auto_check)):
            stripped = value.strip()
            if not stripped or _WHOLE_PLACEHOLDER.match(stripped) or _STAGE6_MARKER.search(stripped):
                out.append(label)
        return out


def parse(text: str) -> list[Correction]:
    """Every entry in the file, in document order."""
    out: list[Correction] = []
    matches = list(ENTRY.finditer(text))
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[m.end():end]
        fields = {f.group("key").strip().lower(): f.group("value").strip()
                  for f in FIELD.finditer(body)}
        out.append(Correction(
            id=m.group("id"),
            title=m.group("title").strip(),
            status=fields.get("status", ""),
            category=fields.get("category", ""),
            rule=fields.get("the rule going forward", ""),
            auto_check=fields.get("auto-check", ""),
        ))
    return out


def load(path: Path | None = None) -> list[Correction]:
    """
    The ACTIVE entries stages 3–5 must obey.

    Raises if any of them is unfilled. Not a warning: an entry that constrains nothing is
    indistinguishable from one that does until someone reads it, and the whole point of the
    file is that the pipeline reads it instead.
    """
    if path is None:
        log = C.correction_log_path()
        if log != C.STYLE_GUIDE:
            # Both original rules and this run's correction overlay remain binding.
            return load(C.STYLE_GUIDE) + load(log)
    path = path or C.STYLE_GUIDE
    if not path.exists():
        return []

    entries = parse(path.read_text())
    active = [e for e in entries if e.is_active]

    unfilled = [(e, e.placeholders()) for e in active]
    unfilled = [(e, missing) for e, missing in unfilled if missing]
    if unfilled:
        lines = [
            f"! {len(unfilled)} ACTIVE entry/entries in {path.name} still carry placeholder text.",
            "",
            "  Stages 3–5 read every ACTIVE entry as a binding constraint, so an unfilled one is",
            "  a rule that constrains nothing while looking exactly like one that does. Stage 6",
            "  writes these automatically and leaves the rule line for a human ([S-016]).",
            "",
        ]
        for entry, missing in unfilled:
            lines.append(f"    [{entry.id}] {entry.title}")
            for field in missing:
                lines.append(f"        {field}: empty or placeholder")
        lines += [
            "",
            "  Write each as an imperative, testable rule — 'backgrounds behind marker type use",
            "  --oat, never --kraft' — or set Status: SUPERSEDED with a dated note if it no",
            "  longer applies. An entry without a testable rule teaches the pipeline nothing.",
        ]
        raise PlaceholderRule("\n".join(lines), ids=[e.id for e, _ in unfilled])

    return active


class PlaceholderRule(Exception):
    """An ACTIVE correction that has not been written as a rule yet."""

    def __init__(self, message: str, ids: list[str]):
        super().__init__(message)
        self.ids = ids


def gate(path: Path | None = None) -> list[Correction]:
    """
    Loader for a stage entry point: returns the active corrections, or exits non-zero with the
    reason. Stages call this before doing any work, so a placeholder stops the run at the top
    rather than after a render.
    """
    try:
        return load(path)
    except PlaceholderRule as exc:
        raise SystemExit(str(exc))
