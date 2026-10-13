"""
The correction-log gate (style_guide [S-016]).

Stages 3–5 treat every `ACTIVE` entry in `style_guide.md` as a binding constraint. Stage 6
appends entries automatically with the rule line left for a human. So an unfilled entry is a
rule that constrains nothing while looking exactly like one that does — and the README has
said "an entry without a testable rule teaches the pipeline nothing" since the first commit
with nothing enforcing it.

The subtle half of this is the false positive. [S-016]'s *own* rule text contains the word
"placeholder", and an early version of this gate blocked the pipeline on it. A gate that
blocks correctly written rules is worse than no gate, because it teaches people to bypass it.
"""

from __future__ import annotations

import pytest

import config as C
import corrections as CR


def entry(rule: str = "Do the specific testable thing.", auto: str = "Stage 6 check 7",
          status: str = "ACTIVE", eid: str = "A-001") -> str:
    return (
        f"### [{eid}] — Something went wrong\n"
        f"- **Date:** 2026-08-11\n"
        f"- **Video / shot:** video001 · frame 12\n"
        f"- **Source:** stage6-auto\n"
        f"- **Status:** {status}\n"
        f"- **Category:** color\n"
        f"- **What was wrong:** a thing\n"
        f"- **Why it was wrong:** a reason\n"
        f"- **The rule going forward:** {rule}\n"
        f"- **Auto-check:** {auto}\n"
    )


def write(tmp_path, text: str):
    path = tmp_path / "style_guide.md"
    path.write_text(text)
    return path


# --------------------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------------------

def test_parses_the_real_style_guide():
    entries = CR.parse(C.STYLE_GUIDE.read_text())
    assert len(entries) >= 16
    assert {e.id for e in entries} >= {"S-001", "S-009", "S-012", "S-016"}
    assert all(e.status for e in entries), "every entry must declare a status"


def test_the_real_style_guide_passes_the_gate():
    """The shipped log must satisfy its own rule, or the pipeline cannot run at all."""
    active = CR.load()
    assert active
    assert all(not e.placeholders() for e in active)


# --------------------------------------------------------------------------------------
# What counts as a placeholder
# --------------------------------------------------------------------------------------

def test_stage6_auto_entry_is_caught(tmp_path):
    """
    The exact text Stage 6 writes. This is the entry the gate exists for: auto-generated,
    plausible-looking, and binding on stages 3–5 the moment it lands.
    """
    path = write(tmp_path, entry(rule="_write this as a testable rule before the next run._"))
    with pytest.raises(CR.PlaceholderRule) as exc:
        CR.load(path)
    assert "A-001" in exc.value.ids


@pytest.mark.parametrize("rule", [
    "", "   ", "TODO", "to do", "TBD", "changeme", "change me", "xxx", "XXXX",
    "placeholder", "n/a", "N/A", "unreviewed", "FIXME", "none", "—", "-",
    "_TBD_", "**TODO**", "`n/a`",
])
def test_placeholder_values_are_caught(tmp_path, rule):
    path = write(tmp_path, entry(rule=rule))
    with pytest.raises(CR.PlaceholderRule):
        CR.load(path)


@pytest.mark.parametrize("rule", [
    "Backgrounds behind marker type use --oat, never --kraft.",
    "Reject placeholder values by name: unreviewed, TODO, TBD, changeme.",
    "Never trim a gap below 120 ms.",
    "Any field recording that a human acted must reject placeholder text.",
    "Set CAPTION_MODE to burn if the highlight ever matters more.",
])
def test_real_rules_are_not_caught(tmp_path, rule):
    """
    A rule that *mentions* placeholders is not a placeholder. [S-016]'s own auto-check line
    reads "a loader-level scan for placeholder text…", and a substring search flags it —
    which would block the pipeline on a correctly written rule.
    """
    path = write(tmp_path, entry(rule=rule))
    assert len(CR.load(path)) == 1


def test_s016_itself_is_not_flagged():
    """The regression that motivated matching whole fields rather than searching inside them."""
    s016 = next(e for e in CR.parse(C.STYLE_GUIDE.read_text()) if e.id == "S-016")
    assert "placeholder" in s016.auto_check.lower(), "fixture assumption changed"
    assert s016.placeholders() == []


def test_auto_check_placeholder_is_caught_too(tmp_path):
    """An entry with no way to detect it is as unfinished as one with no rule."""
    path = write(tmp_path, entry(auto="TBD"))
    with pytest.raises(CR.PlaceholderRule):
        CR.load(path)


def test_auto_check_may_say_it_needs_a_human(tmp_path):
    """
    "NONE — needs a human eye" is a real answer, and several shipped entries use it. It says
    the check was considered and rejected, which is the opposite of an unfilled field.
    """
    path = write(tmp_path, auto := entry(auto="NONE — verify by eye on the first video"))
    assert auto
    assert len(CR.load(path)) == 1


# --------------------------------------------------------------------------------------
# Scope
# --------------------------------------------------------------------------------------

def test_only_active_entries_are_gated(tmp_path):
    """
    A SUPERSEDED entry is history. §13 keeps entries forever so old renders stay explainable,
    so holding them to the current rule would make the log unmaintainable.
    """
    path = write(tmp_path, entry(rule="TODO", status="SUPERSEDED"))
    assert CR.load(path) == []


def test_promoted_entries_are_not_gated(tmp_path):
    path = write(tmp_path, entry(rule="TODO", status="PROMOTED"))
    assert CR.load(path) == []


def test_every_offending_id_is_named(tmp_path):
    """One run should surface all of them, not make her rerun to find the next."""
    path = write(tmp_path, entry(rule="TODO", eid="A-001") + "\n"
                 + entry(rule="Fine and testable.", eid="A-002") + "\n"
                 + entry(auto="TBD", eid="A-003"))
    with pytest.raises(CR.PlaceholderRule) as exc:
        CR.load(path)
    assert set(exc.value.ids) == {"A-001", "A-003"}
    assert "A-002" not in str(exc.value)


def test_missing_file_is_not_an_error(tmp_path):
    assert CR.load(tmp_path / "absent.md") == []


# --------------------------------------------------------------------------------------
# The stages actually refuse
# --------------------------------------------------------------------------------------

def test_gate_raises_systemexit_for_a_stage(tmp_path):
    path = write(tmp_path, entry(rule="TODO"))
    with pytest.raises(SystemExit) as exc:
        CR.gate(path)
    assert "A-001" in str(exc.value)
    assert "constrains nothing" in str(exc.value)


@pytest.mark.parametrize("stage", ["stage3_plan", "stage4_assets", "stage5_composite"])
def test_stages_call_the_gate_before_working(stage, monkeypatch, tmp_path):
    """
    Refuse, not warn. A warning at the top of a run that produces output anyway is a warning
    nobody reads twice — and the output would be built against a rule that says nothing.
    """
    import importlib

    module = importlib.import_module(stage)
    monkeypatch.setattr(C, "STYLE_GUIDE", write(tmp_path, entry(rule="TODO")))

    with pytest.raises(SystemExit) as exc:
        module.main(["--dry-run"])
    assert "A-001" in str(exc.value), f"{stage} ran with an unfilled correction in force"
