"""
Round-trip reader invariants (HANDOFF item 3; style_guide [S-016]).

The learning loop. Stage 6 scores frames against rules the pipeline already holds, so it can
only ever report whether the pipeline followed itself. This reads what she *changed*, which is
the richer signal — every difference is a human disagreeing with a decision the pipeline made.

Restored cuts are the case that matters most and the one nothing else can see: Stage 2 deleting
something it should have kept leaves no trace anywhere unless this reader looks for it.
"""

from __future__ import annotations

from xml.etree import ElementTree as ET

import pytest

import config as C
import fcpxml as FX
import roundtrip as RT


# --------------------------------------------------------------------------------------
# Fixtures — a handoff, and an "edited" version of it
# --------------------------------------------------------------------------------------

CUTS = [(0.0, 0.0, 3.0), (3.0, 6.0, 3.0), (6.0, 12.0, 3.0)]     # offset, source in, duration
GRAPHICS = [(1.0, 2.0, "c001 thermal death point"),
            (4.0, 2.0, "c002 proofing window"),
            (7.0, 2.0, "c003 fermentation")]


def build(path, video, cuts=CUTS, graphics=GRAPHICS, project="video001", aspect="16:9"):
    clips = [FX.Clip(asset_path=video, offset=o, start=s, duration=d, name=f"seg {i + 1:02d}")
             for i, (o, s, d) in enumerate(cuts)]
    connected = [FX.Connected(asset_path=video, offset=o, duration=d, name=n)
                 for o, d, n in graphics]
    clips[0].markers.append((0.5, "BROLL: bubbles", True))
    builder = FX.FCPXMLBuilder(project=project, aspect=aspect)
    return builder.write(builder.build(clips, connected, [(0.0, "Chapter one")]), path)


@pytest.fixture(scope="module")
def handoff(tmp_path_factory, video):
    return build(tmp_path_factory.mktemp("rt") / "handoff.fcpxml", video)


# --------------------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------------------

def test_reads_our_own_output(handoff):
    tl = RT.parse(handoff)
    assert tl.project == "video001"
    assert (tl.fps_num, tl.fps_den) == (24000, 1001)
    assert (tl.width, tl.height) == (1920, 1080)
    assert len(tl.clips) == 3
    assert len(tl.graphics) == 3


def test_connected_clips_resolve_to_absolute_positions(handoff):
    """
    The whole reader rests on this. A connected clip's offset is parent-local, so reading it as
    timeline time stacks every graphic near zero — a plausible-looking timeline that is entirely
    wrong, and the exact bug CLAUDE.md flags as the cause of any "graphic in the wrong place".
    """
    tl = RT.parse(handoff)
    got = sorted(round(g.offset, 3) for g in tl.graphics)
    assert got == [pytest.approx(C.snap_seconds(o), abs=1e-3) for o, _, _ in GRAPHICS]


def test_markers_and_chapters_resolve_too(handoff):
    tl = RT.parse(handoff)
    assert tl.markers and tl.markers[0][1] == "BROLL: bubbles"
    assert tl.markers[0][0] == pytest.approx(C.snap_seconds(0.5), abs=1e-3)
    assert tl.chapters and tl.chapters[0][1] == "Chapter one"


def test_source_spans_describe_what_survived(handoff):
    tl = RT.parse(handoff)
    spans = tl.source_spans()
    assert len(spans) == 3
    assert spans[0][0] == pytest.approx(0.0, abs=0.05)
    assert spans[2][0] == pytest.approx(12.0, abs=0.05)


def test_parses_a_gap_without_losing_alignment(tmp_path, video):
    """
    Final Cut writes gaps where we write nothing. A gap occupies time, so a reader that skips
    it silently mis-times everything after it.
    """
    path = build(tmp_path / "g.fcpxml", video)
    root = ET.parse(path).getroot()
    spine = root.find(".//spine")
    gap = ET.Element("gap", offset=C.fcp_time(9.0), duration=C.fcp_duration(1.0), name="gap")
    spine.append(gap)
    ET.ElementTree(root).write(path)

    tl = RT.parse(path)
    assert len(tl.clips) == 3, "the gap was counted as a clip"
    assert len(tl.graphics) == 3


def test_reads_fcps_nesting_shapes(tmp_path, video):
    """
    FCP exports nest differently from what we generate — a `ref-clip` wrapping a nested spine
    is routine. Rejecting that would make the reader useless on its only real input.
    """
    path = build(tmp_path / "n.fcpxml", video)
    root = ET.parse(path).getroot()
    spine = root.find(".//spine")
    first = spine.find("asset-clip")
    first.tag = "ref-clip"
    ET.ElementTree(root).write(path)

    tl = RT.parse(path)
    assert len(tl.clips) == 3
    assert any(c.kind == "ref-clip" for c in tl.clips)


# --------------------------------------------------------------------------------------
# Cuts restored — the highest-priority signal
# --------------------------------------------------------------------------------------

def test_restored_cut_is_detected(tmp_path, video, handoff):
    """
    Stage 2 dropped source 3.0–6.0s; she put it back. Nothing else in the pipeline can see
    this, because the evidence is footage that is present rather than absent.
    """
    edited = build(tmp_path / "edited.fcpxml", video,
                   cuts=[(0.0, 0.0, 6.0), (6.0, 12.0, 3.0)])
    changes = RT.diff(RT.parse(handoff), RT.parse(edited))
    restored = [c for c in changes if c.kind == "restored-cut"]
    assert restored, [c.kind for c in changes]
    assert "3.0" in restored[0].detail or "3.00" in restored[0].detail


def test_restored_cut_outranks_everything_else(tmp_path, video, handoff):
    """Priority is not cosmetic: it decides which entry she reads first."""
    edited = build(tmp_path / "e.fcpxml", video,
                   cuts=[(0.0, 0.0, 6.0), (6.0, 12.0, 3.0)],
                   graphics=[(1.0, 2.0, "c001 thermal death point")])
    changes = RT.diff(RT.parse(handoff), RT.parse(edited))
    assert changes[0].kind == "restored-cut"


def test_no_restored_cut_when_the_cut_is_unchanged(handoff):
    tl = RT.parse(handoff)
    assert [c for c in RT.diff(tl, tl) if c.kind == "restored-cut"] == []


def test_trimming_further_is_not_a_restored_cut(tmp_path, video, handoff):
    """
    She tightened it rather than putting anything back. That is agreement with Stage 2, not
    disagreement, and reporting it would train the pipeline the wrong way.
    """
    edited = build(tmp_path / "t.fcpxml", video,
                   cuts=[(0.0, 0.0, 2.0), (2.0, 6.0, 2.0), (4.0, 12.0, 2.0)])
    changes = RT.diff(RT.parse(handoff), RT.parse(edited))
    assert [c for c in changes if c.kind == "restored-cut"] == []


# --------------------------------------------------------------------------------------
# Graphics
# --------------------------------------------------------------------------------------

def test_deleted_graphic_is_detected(tmp_path, video, handoff):
    edited = build(tmp_path / "d.fcpxml", video, graphics=GRAPHICS[:2])
    changes = RT.diff(RT.parse(handoff), RT.parse(edited))
    deleted = [c for c in changes if c.kind == "graphic-deleted"]
    assert len(deleted) == 1 and deleted[0].subject == "c003"


def test_retimed_graphic_reports_the_delta(tmp_path, video, handoff):
    """
    "Report the delta, so the §5.4 hold constant can be tuned rather than guessed." A bare
    "this was retimed" would leave the next person guessing in exactly the same way.
    """
    edited = build(tmp_path / "r.fcpxml", video,
                   graphics=[(1.0, 3.5, "c001 thermal death point"),
                             (4.0, 2.0, "c002 proofing window"),
                             (7.0, 2.0, "c003 fermentation")])
    changes = RT.diff(RT.parse(handoff), RT.parse(edited))
    retimed = [c for c in changes if c.kind == "graphic-retimed"]
    assert len(retimed) == 1
    assert "1.5" in retimed[0].detail and "longer" in retimed[0].detail
    assert "§5.4" in retimed[0].detail


def test_moved_graphic_reports_the_direction(tmp_path, video, handoff):
    edited = build(tmp_path / "m.fcpxml", video,
                   graphics=[(1.0, 2.0, "c001 thermal death point"),
                             (5.2, 2.0, "c002 proofing window"),
                             (7.0, 2.0, "c003 fermentation")])
    changes = RT.diff(RT.parse(handoff), RT.parse(edited))
    moved = [c for c in changes if c.kind == "graphic-moved"]
    assert len(moved) == 1 and moved[0].subject == "c002"
    assert "later" in moved[0].detail and "early" in moved[0].detail


def test_graphics_are_matched_by_cue_id_not_by_full_name(tmp_path, video, handoff):
    """She renames things in the edit. Matching on the whole name would read that as a delete."""
    edited = build(tmp_path / "rn.fcpxml", video,
                   graphics=[(1.0, 2.0, "c001 THERMAL DEATH POINT (final)"),
                             (4.0, 2.0, "c002 proofing window"),
                             (7.0, 2.0, "c003 fermentation")])
    changes = RT.diff(RT.parse(handoff), RT.parse(edited))
    assert [c for c in changes if c.kind == "graphic-deleted"] == []


def test_frame_grid_rounding_is_not_a_change(tmp_path, video, handoff):
    """A sub-frame difference is arithmetic, not an edit. Reporting it would be noise."""
    edited = build(tmp_path / "eps.fcpxml", video,
                   graphics=[(1.0 + 0.5 / C.FPS, 2.0, "c001 thermal death point"),
                             (4.0, 2.0, "c002 proofing window"),
                             (7.0, 2.0, "c003 fermentation")])
    assert RT.diff(RT.parse(handoff), RT.parse(edited)) == []


def test_identical_timelines_produce_nothing(handoff):
    tl = RT.parse(handoff)
    assert RT.diff(tl, tl) == []


# --------------------------------------------------------------------------------------
# Timebase
# --------------------------------------------------------------------------------------

def test_conformed_timebase_is_reported(tmp_path, video, handoff, capsys):
    """
    [S-007]. If Final Cut conforms the sequence, every downstream time is wrong and nothing
    else in the pipeline would say so — the reader is the only place it can surface.
    """
    edited = build(tmp_path / "c.fcpxml", video)
    text = edited.read_text().replace('frameDuration="1001/24000s"',
                                      'frameDuration="1/24s"')
    edited.write_text(text)

    RT.main([str(handoff), str(edited), "--dry-run"])
    out = capsys.readouterr().out
    assert "TIMEBASE CHANGED" in out
    assert "S-007" in out


# --------------------------------------------------------------------------------------
# Writing corrections  [S-016]
# --------------------------------------------------------------------------------------

def make_guide(tmp_path):
    path = tmp_path / "style_guide.md"
    path.write_text("# style_guide\n\n<!-- NEW ENTRIES GO DIRECTLY BELOW THIS LINE -->\n")
    return path


def test_entries_are_grouped_by_defect_not_per_occurrence(tmp_path):
    """
    A dozen near-identical entries would bury the log and make §13's promotion rule
    meaningless — the same reason Stage 6 groups its own findings.
    """
    guide = make_guide(tmp_path)
    changes = [RT.Change("graphic-moved", f"c{i:03d}", f"moved {i}") for i in range(1, 7)]
    assert RT.write_entries(changes, "video001", guide) == 1
    assert guide.read_text().count("### [R-") == 1
    for i in range(1, 7):
        assert f"c{i:03d}" in guide.read_text()


def test_written_entries_gate_the_pipeline(tmp_path, monkeypatch):
    """
    [S-016], and the point of the whole design. The reader cannot write a testable rule —
    turning an observation into one is a judgement it is not entitled to make — so what it
    writes must stop stages 3–5 until a human does.
    """
    import corrections as CR

    guide = make_guide(tmp_path)
    RT.write_entries([RT.Change("restored-cut", "source 3–6s", "footage came back")],
                     "video001", guide)

    with pytest.raises(CR.PlaceholderRule) as exc:
        CR.load(guide)
    assert exc.value.ids == ["R-001"]


def test_entry_ids_do_not_collide_on_a_second_run(tmp_path):
    guide = make_guide(tmp_path)
    RT.write_entries([RT.Change("restored-cut", "a", "x")], "video001", guide)
    RT.write_entries([RT.Change("graphic-moved", "b", "y")], "video001", guide)
    text = guide.read_text()
    assert "### [R-001]" in text and "### [R-002]" in text


def test_nothing_is_written_when_nothing_changed(tmp_path):
    assert RT.write_entries([], "video001", make_guide(tmp_path)) == 0


def test_missing_marker_refuses_rather_than_guessing(tmp_path):
    guide = tmp_path / "style_guide.md"
    guide.write_text("# no marker here\n")
    with pytest.raises(SystemExit):
        RT.write_entries([RT.Change("restored-cut", "a", "x")], "video001", guide)


def test_dry_run_writes_nothing(tmp_path, video, handoff, capsys):
    edited = build(tmp_path / "dr.fcpxml", video, graphics=GRAPHICS[:2])
    before = C.STYLE_GUIDE.read_text()
    assert RT.main([str(handoff), str(edited), "--dry-run"]) == 0
    assert "dry run" in capsys.readouterr().out
    assert C.STYLE_GUIDE.read_text() == before, "the real style guide was modified"


def test_inspection_mode_reports_the_format(handoff, capsys):
    """
    Running with only the handoff reports the format Final Cut actually built — the only way
    to see what a name like FFVideoFormatRateUndefined resolved to.
    """
    assert RT.main([str(handoff)]) == 0
    out = capsys.readouterr().out
    assert "1920x1080" in out and "24000/1001" in out
