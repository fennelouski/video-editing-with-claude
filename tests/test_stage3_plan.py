"""
Graphic-plan invariants (taste_principles §5.4, §9; style_guide [S-009]).

Two classes of thing here: the parser must not let markdown scaffolding leak into the anchor
text a cue is matched on, and discovery must refuse to plan off a file it hasn't proved is a
script.
"""

from __future__ import annotations

import json

import pytest

import config as C
import fixtures as FX
import stage3_plan as S3


@pytest.fixture(scope="module")
def cues(script_md):
    return S3.parse_markdown(script_md)


@pytest.fixture(scope="module")
def resolved(script_md, words):
    return S3.resolve(S3.parse_markdown(script_md), words)


# --------------------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------------------

def test_every_cue_kind_round_trips(cues):
    """The fixture exercises all seven kinds; a parser that drops one fails silently."""
    assert {c.kind for c in cues} == S3.VALID_KINDS


def test_cue_ids_are_unique_and_ordered(cues):
    ids = [c.id for c in cues]
    assert len(set(ids)) == len(ids)
    assert ids == sorted(ids)


# --------------------------------------------------------------------------------------
# Markdown must not pollute the anchor
# --------------------------------------------------------------------------------------

def test_headings_do_not_pollute_anchor_text(cues):
    """
    A heading is never spoken, so if its words reach the anchor the cue matches against text
    that does not exist in the transcript and lands somewhere arbitrary.
    """
    heading_words = {"what", "actually", "works", "yeast", "the", "chemistry",
                     "home", "bakers", "miss"}
    gauge = next(c for c in cues if c.template == "gauge")
    anchor = S3.norm(gauge.anchor).split()

    assert "blood" in anchor and "warm" in anchor, f"anchor lost the spoken line: {gauge.anchor!r}"
    assert "actually" not in anchor, f"heading text leaked into the anchor: {gauge.anchor!r}"
    assert not (set(anchor) & {"actually", "works"}), f"heading leaked: {gauge.anchor!r}"
    assert heading_words  # documents what is being guarded against


def test_fenced_blocks_do_not_pollute_anchor_text(cues):
    """A shot note in a fenced block is a production instruction, not narration."""
    vo = next(c for c in cues if c.kind == "VO")
    anchor = S3.norm(vo.anchor).split()
    assert "ninety" in anchor and "minutes" in anchor
    for leaked in ("shot", "note", "locked", "macro", "100mm"):
        assert leaked not in anchor, f"fenced block leaked {leaked!r} into {vo.anchor!r}"


def test_marker_syntax_does_not_leak_into_a_later_anchor(cues):
    """Earlier markers are stripped before the anchor is taken, or they stack up."""
    for c in cues:
        assert "[[" not in c.anchor and "]]" not in c.anchor
        for kind in S3.VALID_KINDS:
            assert kind not in c.anchor, f"{c.id}: marker kind {kind} leaked into the anchor"


def test_strip_markdown_removes_scaffolding_only():
    text = "## A heading\n\nThe **spoken** line here.\n\n```\ncode\n```\n\n- a bullet"
    out = S3.strip_markdown(text)
    assert "heading" not in out.lower()
    assert "code" not in out
    assert "spoken" in out and "line" in out
    assert "a bullet" in out          # the words survive, only the marker is stripped
    assert "*" not in out and "#" not in out


# --------------------------------------------------------------------------------------
# Free text vs template names
# --------------------------------------------------------------------------------------

@pytest.mark.parametrize("kind", ["BROLL", "MACRO", "VO", "CAM", "NOTE"])
def test_non_template_kinds_parse_their_body_as_free_text(kind):
    """
    Only GFX and CHAPTER take a template name. Treating a bare first token as a template for
    the rest is what produced "unknown template 'bubbles rising in the starter'".
    """
    parsed = S3.parse_body("bubbles rising in the starter", kind)
    assert "template" not in parsed
    assert parsed["free"] == ["bubbles rising in the starter"]


@pytest.mark.parametrize("kind", ["GFX", "CHAPTER"])
def test_template_kinds_take_a_template_name(kind):
    parsed = S3.parse_body('key_term | text="Gluten"', kind)
    assert parsed["template"] == "key_term"
    assert parsed["kv"]["text"] == "Gluten"


def test_broll_and_macro_text_survives_to_the_cue(cues):
    macro = next(c for c in cues if c.kind == "MACRO")
    broll = next(c for c in cues if c.kind == "BROLL")
    assert macro.text == "bubbles rising through a warm starter"
    assert broll.text == "the dense under proofed loaf cut open on the board"
    assert macro.template is None and broll.template is None


def test_no_cue_carries_an_unknown_template(cues):
    assert S3.check_templates(cues) == []


def test_assets_parse_into_a_list():
    parsed = S3.parse_body('key_term | text="X" | asset=cutout:yeast_cell,cutout:jar', "GFX")
    assert parsed["assets"] == ["cutout:yeast_cell", "cutout:jar"]


# --------------------------------------------------------------------------------------
# Anchoring and timing
# --------------------------------------------------------------------------------------

def test_every_cue_anchors_into_the_transcript(resolved):
    unresolved = [c for c in resolved if c.unresolved]
    assert not unresolved, [(c.id, c.anchor, c.unresolved) for c in unresolved]


def test_cues_land_in_script_order(resolved):
    timed = [c for c in resolved if c.start is not None]
    starts = [c.start for c in timed]
    assert starts == sorted(starts), "cues resolved out of order — anchoring is mismatching"


def test_cues_land_near_the_line_they_annotate(resolved, words):
    """
    A cue is placed at the end of the phrase it sits next to (§6.3 — the graphic appears the
    moment she says the term, not before).
    """
    expected = {
        "gauge": "blood_warm",
        "key_term": "take_good",
        "chapter_card": "hook",
    }
    for template, tag in expected.items():
        cue = next(c for c in resolved if c.template == template)
        _, beat_end = FX.span_of(words, tag)
        assert cue.start == pytest.approx(beat_end, abs=0.35), (
            f"{template} anchored to {cue.start:.2f}s, expected near {beat_end:.2f}s"
        )


def test_hold_comes_from_the_formula_never_guessed(resolved):
    for c in resolved:
        if c.hold is None:
            continue
        assert c.hold == pytest.approx(round(C.hold_seconds(len(c.text.split())), 2))
        assert c.hold >= C.HOLD_MIN_SECONDS


def test_notes_are_carried_but_never_timed(resolved):
    note = next(c for c in resolved if c.kind == "NOTE")
    assert note.start is None and note.hold is None
    assert note.text, "the note text was dropped — she still needs to read it"


def test_end_is_start_plus_hold(resolved):
    for c in resolved:
        if c.start is None:
            continue
        assert c.end == pytest.approx(c.start + c.hold, abs=0.011)


# --------------------------------------------------------------------------------------
# Discovery  [S-009]
# --------------------------------------------------------------------------------------

def test_repo_root_documents_are_not_scripts():
    """
    CLAUDE.md is the file the old denylist actually selected. It must not qualify as a
    script, whatever else lands in the project root.
    """
    assert S3.has_cue_marker(C.ROOT / "CLAUDE.md") is False
    assert S3.has_cue_marker(C.ROOT / "taste_principles.md") is False


def test_a_root_document_with_a_live_marker_is_detected():
    """
    README.md documents the inline marker syntax with a real `[[GFX: …]]` example, so the
    repo contains a live instance of the trigger condition rather than a synthesised one.
    """
    readme = C.ROOT / "README.md"
    assert readme.exists()
    assert S3.has_cue_marker(readme) is True


def test_stray_root_script_stops_the_stage_and_names_it(tmp_path, monkeypatch, capsys):
    """
    [S-009] — a root document carrying a cue marker must make Stage 3 exit non-zero naming
    that file, and must never produce a plan from it.
    """
    root = tmp_path
    (root / "script").mkdir()
    stray = root / "yeast-draft.md"
    stray.write_text(
        "She says the line here.\n"
        '[[GFX: key_term | text="Gluten" | asset=cutout:gluten_strand]]\n',
        encoding="utf-8",
    )
    plan_dir = root / "build" / "plan"

    monkeypatch.setattr(C, "ROOT", root)
    monkeypatch.setattr(C, "SCRIPT_DIR", root / "script")
    monkeypatch.setattr(C, "PLAN_DIR", plan_dir)
    monkeypatch.setattr(C, "TRANSCRIPTS", root / "build" / "transcripts")

    code = S3.main([])
    out = capsys.readouterr().out

    assert code != 0, "Stage 3 planned off a root file instead of stopping"
    assert "yeast-draft.md" in out, "the stray file was not named"
    assert "script/" in out, "the message does not say where to put it"
    assert not list(plan_dir.glob("*.plan.json")) if plan_dir.exists() else True


def test_root_documents_without_markers_are_not_reported(tmp_path, monkeypatch, capsys):
    """A root full of ordinary documentation is not an error, it is just an empty script/."""
    root = tmp_path
    (root / "script").mkdir()
    (root / "NOTES.md").write_text("Just some notes about GFX and BROLL cues.\n")

    monkeypatch.setattr(C, "ROOT", root)
    monkeypatch.setattr(C, "SCRIPT_DIR", root / "script")

    code = S3.main([])
    out = capsys.readouterr().out
    assert code != 0
    assert "NOTES.md" not in out
    assert "no annotated script found" in out


def test_explicit_path_is_trusted_without_evidence(tmp_path, monkeypatch, capsys):
    """
    Discovery requires evidence; an explicit instruction does not. A path she passes on the
    command line is used even though it sits in the root and even though script/ is empty.
    """
    root = tmp_path
    (root / "script").mkdir()
    explicit = root / "handwritten.md"
    explicit.write_text(
        "Most home bakers kill their yeast before it ever gets started.\n"
        '[[CHAPTER: chapter_card | text="The temperature mistake"]]\n',
        encoding="utf-8",
    )

    monkeypatch.setattr(C, "ROOT", root)
    monkeypatch.setattr(C, "SCRIPT_DIR", root / "script")
    monkeypatch.setattr(C, "PLAN_DIR", root / "build" / "plan")
    monkeypatch.setattr(C, "TRANSCRIPTS", root / "build" / "transcripts")

    code = S3.main([str(explicit), "--dry-run"])
    out = capsys.readouterr().out
    assert code == 0, out
    assert "handwritten.md" in out


def test_discovery_prefers_the_script_directory(tmp_path, monkeypatch):
    root = tmp_path
    (root / "script").mkdir()
    (root / "stray.md").write_text('[[GFX: key_term | text="X"]]\n')
    wanted = root / "script" / "the-real-one.md"
    wanted.write_text('[[GFX: key_term | text="Y"]]\n')

    monkeypatch.setattr(C, "ROOT", root)
    monkeypatch.setattr(C, "SCRIPT_DIR", root / "script")

    assert S3.find_script() == wanted


def test_word_lock_files_are_ignored(tmp_path, monkeypatch):
    """`~$draft.docx` is Word's lock file for an open document, never the script."""
    root = tmp_path
    (root / "script").mkdir()
    (root / "script" / "~$draft.docx").write_bytes(b"not a real docx")

    monkeypatch.setattr(C, "SCRIPT_DIR", root / "script")
    assert S3.find_script() is None


def test_has_cue_marker_survives_unreadable_files(tmp_path):
    """A corrupt .docx must report 'no evidence', not crash the stage."""
    bad = tmp_path / "broken.docx"
    bad.write_bytes(b"this is not a zip archive")
    assert S3.has_cue_marker(bad) is False
    assert S3.has_cue_marker(tmp_path / "does-not-exist.md") is False


# --------------------------------------------------------------------------------------
# Plan output
# --------------------------------------------------------------------------------------

def test_plan_writes_valid_json(tmp_path, monkeypatch, script_md, transcript_path):
    monkeypatch.setattr(C, "ROOT", tmp_path)      # main() prints the path relative to ROOT
    monkeypatch.setattr(C, "PLAN_DIR", tmp_path / "plan")
    monkeypatch.setattr(C, "TRANSCRIPTS", transcript_path.parent)

    code = S3.main([str(script_md), "--project", "video001"])
    assert code == 0

    plan = json.loads((tmp_path / "plan" / "video001.plan.json").read_text())
    assert plan["project"] == "video001"
    assert plan["cues"]
    assert plan["fps"] == C.FPS
    assert {c["kind"] for c in plan["cues"]} == S3.VALID_KINDS
