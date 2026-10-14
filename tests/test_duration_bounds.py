"""Synthetic duration gates: no transcription, source-media reads, or rendering."""
from __future__ import annotations

import hashlib
import json
from fractions import Fraction
from types import SimpleNamespace
from xml.etree import ElementTree as ET

import pytest

import config as C
import run_pipeline as R
from duration_bounds import (DurationBounds, DurationReviewRequired, check_final_output,
                             check_roughcut, final_sequence_duration, retained_duration)


def write_edl(path, spans=((0, 10),), **summary):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"keeps": [{"start": a, "end": b} for a, b in spans], **summary}))
    return path


def write_final(path, duration="10s"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'
                    f'<fcpxml version="1.13"><library><event><project>'
                    f'<sequence duration="{duration}"><spine/></sequence>'
                    f'</project></event></library></fcpxml>')
    return path


@pytest.fixture
def pipeline(tmp_path, monkeypatch):
    roughcut = tmp_path / "roughcut"
    transcripts = tmp_path / "transcripts"
    transcripts.mkdir()
    monkeypatch.setattr(C, "ROUGHCUT", roughcut)
    monkeypatch.setattr(C, "TRANSCRIPTS", transcripts)
    monkeypatch.setattr(C, "EXPORTS", tmp_path / "exports")
    monkeypatch.setattr(C, "ALL_BUILD_DIRS", [])
    monkeypatch.setattr(R.cli, "preflight", lambda: None)
    monkeypatch.setattr(R, "preflight", lambda **kwargs: [])
    return roughcut


@pytest.mark.parametrize("field", ["minimum", "maximum"])
@pytest.mark.parametrize("value", [0, -1, float("nan"), float("inf"), float("-inf"), True, "12"])
def test_bounds_require_finite_positive_seconds(field, value):
    with pytest.raises(ValueError, match="finite, positive"):
        DurationBounds(**{field: value})


def test_bounds_order_and_equal_endpoints():
    with pytest.raises(ValueError, match="must not exceed"):
        DurationBounds(20, 10)
    DurationBounds(10, 10).check(10)


@pytest.mark.parametrize("argv", [
    ["--min-duration", "0"], ["--max-duration", "nan"],
    ["--max-duration", "inf"], ["--min-duration", "20", "--max-duration", "10"],
])
def test_cli_rejects_invalid_bounds_before_outputs_or_stages(argv, pipeline, monkeypatch, capsys):
    output = pipeline.parent / "must not exist"
    monkeypatch.setattr(C, "ALL_BUILD_DIRS", [output])
    monkeypatch.setattr(R, "run_stage", lambda *a: pytest.fail("a stage ran"))
    with pytest.raises(SystemExit) as failure:
        R.main(argv + ["--skip-preflight", "--only", "2"])
    assert failure.value.code == 2
    assert not output.exists()
    assert "duration" in capsys.readouterr().err


def test_duration_uses_retained_storyline_not_summary_or_source_gaps(tmp_path):
    path = write_edl(tmp_path / "clip.edl.json", ((0, 1), (20, 22)), cut_duration=900, source_duration=1000)
    assert check_roughcut(tmp_path, DurationBounds(maximum=4)) == pytest.approx(C.snap_seconds(3))
    original = hashlib.sha256(path.read_bytes()).hexdigest()
    with pytest.raises(DurationReviewRequired, match="below the minimum"):
        check_roughcut(tmp_path, DurationBounds(minimum=4))
    with pytest.raises(DurationReviewRequired, match="above the maximum"):
        check_roughcut(tmp_path, DurationBounds(maximum=2))
    assert hashlib.sha256(path.read_bytes()).hexdigest() == original


def test_duration_matches_stage5_independent_frame_rounding():
    # The end of the last primary clip, not a rounded summary or sum of rounded spans.
    spans = [(0, 0.075), (1, 1.075), (2, 2.075)]
    edl = {"keeps": [{"start": a, "end": b} for a, b in spans]}
    endpoint = max(C.snap_seconds(i * 0.075) + C.snap_seconds(0.075) for i in range(3))
    assert retained_duration(edl) == pytest.approx(endpoint)
    assert retained_duration(edl) != pytest.approx(C.snap_seconds(0.225))


def test_duration_matches_actual_stage5_serialized_sequence(tmp_path, monkeypatch):
    import fcpxml as FX
    import stage5_composite as S5
    source = tmp_path / "synthetic source.dat"
    source.write_bytes(b"synthetic identity only; not playable media")
    original = source.read_bytes()
    monkeypatch.setattr(C, "PLAN_DIR", tmp_path)
    (tmp_path / "synthetic.plan.json").write_text(json.dumps({"cues": []}))
    edl = write_edl(tmp_path / "synthetic.edl.json", ((0, .075), (1, 1.075), (2, 2.075)), source=str(source))
    # Only serialization geometry is under test; the fixture is not a render acceptance.
    monkeypatch.setattr(FX, "probe", lambda *a: {"duration": 10, "has_video": True, "has_audio": False,
                                              "width": 1920, "height": 1080, "frame_duration": C.FRAME_DURATION})
    monkeypatch.setattr(FX, "validate", lambda *a: [])
    out = S5.assemble("synthetic", "16:9", edl, [], tmp_path / "synthetic.fcpxml")
    sequence = ET.parse(out).find(".//sequence")
    actual = float(Fraction(sequence.attrib["duration"][:-1]))
    assert check_roughcut(tmp_path, DurationBounds(actual, actual)) == actual
    assert check_final_output(tmp_path, "synthetic", DurationBounds(actual, actual)) == actual
    assert source.read_bytes() == original


def test_requested_bound_does_not_gain_a_frame_of_tolerance(tmp_path):
    write_edl(tmp_path / "clip.edl.json", ((0, 1),))
    actual = C.snap_seconds(1)
    check_roughcut(tmp_path, DurationBounds(actual, actual))
    with pytest.raises(DurationReviewRequired, match="above the maximum"):
        check_roughcut(tmp_path, DurationBounds(maximum=actual - 0.001))


@pytest.mark.parametrize("data", [
    {}, {"keeps": []}, [], {"keeps": [None]},
    {"keeps": [{"start": -1, "end": 1}]},
    {"keeps": [{"start": 0, "end": 0}]},
    {"keeps": [{"start": 0, "end": float("nan")}]},
    {"keeps": [{"start": False, "end": 1}]},
    {"keeps": [{"start": "0", "end": 1}]},
    {"keeps": [{"start": 0, "end": 1}, {"start": 0.5, "end": 2}]},
    {"keeps": [{"start": 0, "end": 0.001}]},
])
def test_unverifiable_spans_fail_closed(tmp_path, data):
    (tmp_path / "clip.edl.json").write_text(json.dumps(data))
    with pytest.raises(DurationReviewRequired, match="cannot verify"):
        check_roughcut(tmp_path, DurationBounds(maximum=20))


def test_malformed_json_and_escaped_edl_fail_closed(tmp_path):
    edl = tmp_path / "roughcut" / "clip.edl.json"
    edl.parent.mkdir()
    edl.write_text("not JSON")
    with pytest.raises(DurationReviewRequired, match="cannot verify"):
        check_roughcut(edl.parent, DurationBounds(maximum=20))
    edl.unlink()
    outside = write_edl(tmp_path / "outside.json")
    edl.symlink_to(outside)
    with pytest.raises(DurationReviewRequired, match="escapes"):
        check_roughcut(edl.parent, DurationBounds(maximum=20))


def test_unreadable_assembly_file_reports_review_instead_of_traceback(tmp_path, monkeypatch):
    from pathlib import Path
    monkeypatch.setattr(Path, "is_file", lambda *a: (_ for _ in ()).throw(PermissionError("synthetic inaccessible file")))
    with pytest.raises(DurationReviewRequired, match="cannot verify.*inaccessible"):
        check_roughcut(tmp_path, DurationBounds(maximum=20), assembly=True)


@pytest.mark.parametrize("count", [0, 2])
def test_unassembled_edl_selection_must_be_unambiguous(tmp_path, count):
    for i in range(count):
        write_edl(tmp_path / f"clip{i}.edl.json")
    with pytest.raises(DurationReviewRequired, match=f"found {count} unassembled"):
        check_roughcut(tmp_path, DurationBounds(maximum=20))


def test_explicit_assembly_uses_whole_selected_cut_and_never_falls_back(tmp_path):
    write_edl(tmp_path / "a.edl.json", ((0, 1),))
    write_edl(tmp_path / "b.edl.json", ((0, 1),))
    with pytest.raises(DurationReviewRequired, match="no selected edit list"):
        check_roughcut(tmp_path, DurationBounds(maximum=20), assembly=True)
    selected = write_edl(tmp_path / "assembly/selected.edl.json", ((0, 1), (20, 30)))
    with pytest.raises(DurationReviewRequired, match="above the maximum"):
        check_roughcut(tmp_path, DurationBounds(maximum=5), assembly=True)
    assert check_roughcut(tmp_path, DurationBounds(maximum=20), assembly=True) == pytest.approx(C.snap_seconds(11))
    assert selected.is_file()


def test_absent_bounds_preserve_legacy_discovery(tmp_path):
    assert check_roughcut(tmp_path / "missing", DurationBounds()) is None


@pytest.mark.parametrize("progress", [False, True])
@pytest.mark.parametrize("bound", [("--min-duration", "20"), ("--max-duration", "5")])
def test_post_stage2_gate_stops_before_plan_or_render(progress, bound, pipeline, monkeypatch, capsys):
    calls = []
    def stage(s, *args):
        calls.append(s.number)
        write_edl(pipeline / "clip.edl.json")
        return 0
    monkeypatch.setattr(R, "run_stage", stage)
    argv = ["--from", "2", "--to", "5", "--skip-preflight", *bound]
    if progress:
        argv += ["--progress", "json"]
    assert R.main(argv) == 1
    assert calls == [2]
    captured = capsys.readouterr()
    assert "Duration review required" in captured.err
    if progress:
        events = [json.loads(line) for line in captured.out.splitlines()]
        assert [(e["stage"], e["state"]) for e in events] == [(2, "start"), (2, "fail")]
        assert "Duration review required" in events[-1]["detail"]
    else:
        assert "STOPPED at stage 2" in captured.out
        assert "OVER TO FINAL CUT" not in captured.out


@pytest.mark.parametrize("progress", [False, True])
@pytest.mark.parametrize("number", [4, 5])
def test_resumed_assets_and_composite_gate_before_work(progress, number, pipeline, monkeypatch, capsys):
    write_edl(pipeline / "clip.edl.json")
    monkeypatch.setattr(R, "run_stage", lambda *a: pytest.fail("assets/render ran despite duration"))
    argv = ["--only", str(number), "--max-duration", "5", "--skip-preflight"]
    if progress:
        argv += ["--progress", "json"]
    assert R.main(argv) == 1
    captured = capsys.readouterr()
    if progress:
        events = [json.loads(line) for line in captured.out.splitlines()]
        assert [(e["stage"], e["state"]) for e in events] == [(number, "start"), (number, "fail")]
        assert "above the maximum" in events[-1]["detail"]


@pytest.mark.parametrize("assembly", [False, True])
@pytest.mark.parametrize("progress", [False, True])
def test_resume_refuses_missing_or_ambiguous_cut_selection(assembly, progress, pipeline, monkeypatch, capsys):
    if assembly:
        write_edl(pipeline / "clip.edl.json", ((0, 1),))
    else:
        write_edl(pipeline / "a.edl.json", ((0, 1),))
        write_edl(pipeline / "b.edl.json", ((0, 1),))
    monkeypatch.setattr(R, "run_stage", lambda *a: pytest.fail("render ran without a selected cut"))
    argv = ["--only", "5", "--max-duration", "5", "--skip-preflight"]
    if assembly:
        argv += ["--assembly", "synthetic order.json"]
    if progress:
        argv += ["--progress", "json"]
    assert R.main(argv) == 1
    captured = capsys.readouterr()
    assert "Duration review required" in captured.err
    if progress:
        assert "Duration review required" in json.loads(captured.out.splitlines()[-1])["detail"]


def test_assembly_passes_actual_whole_cut_duration_to_resume_gate(pipeline, monkeypatch):
    write_edl(pipeline / "a.edl.json", ((0, 100),))
    write_edl(pipeline / "b.edl.json", ((0, 100),))
    write_edl(pipeline / "assembly/selected.edl.json", ((0, 1), (20, 22)))
    calls = []
    def stage(s, *args):
        calls.append(s.number)
        if s.number == 5:
            write_final(C.EXPORTS / "video001.fcpxml", "3s")
        return 0
    monkeypatch.setattr(R, "run_stage", stage)
    assert R.main(["--from", "4", "--to", "5", "--min-duration", "2", "--max-duration", "4",
                   "--assembly", "synthetic order.json", "--skip-preflight"]) == 0
    assert calls == [4, 5]


def test_gate_checks_again_between_assets_and_composite(pipeline, monkeypatch):
    write_edl(pipeline / "clip.edl.json", ((0, 1),))
    calls = []
    def stage(s, *args):
        calls.append(s.number)
        write_edl(pipeline / "clip.edl.json")
        return 0
    monkeypatch.setattr(R, "run_stage", stage)
    assert R.main(["--from", "4", "--to", "5", "--max-duration", "5", "--skip-preflight"]) == 1
    assert calls == [4]


@pytest.mark.parametrize("progress", [False, True])
def test_composite_cannot_accept_changed_out_of_bounds_edl(progress, pipeline, monkeypatch, capsys):
    write_edl(pipeline / "clip.edl.json", ((0, 1),))
    monkeypatch.setattr(R, "run_stage", lambda *a: (write_edl(pipeline / "clip.edl.json") and 0))
    argv = ["--only", "5", "--max-duration", "5", "--skip-preflight"]
    if progress:
        argv += ["--progress", "json"]
    assert R.main(argv) == 1
    captured = capsys.readouterr()
    assert "OVER TO FINAL CUT" not in captured.out
    if progress:
        assert json.loads(captured.out.splitlines()[-1])["state"] == "fail"


@pytest.mark.parametrize("progress", [False, True])
def test_in_bounds_pipeline_and_unbounded_legacy_pipeline_succeed(progress, pipeline, monkeypatch, capsys):
    calls = []
    def stage(s, *args):
        calls.append(s.number)
        if s.number == 2:
            write_edl(pipeline / "clip.edl.json")
        if s.number == 5:
            write_final(C.EXPORTS / "video001.fcpxml")
        return 0
    monkeypatch.setattr(R, "run_stage", stage)
    argv = ["--from", "2", "--to", "5", "--skip-preflight", "--min-duration", "5", "--max-duration", "20"]
    if progress:
        argv += ["--progress", "json"]
    assert R.main(argv) == 0
    assert calls == [2, 3, 4, 5]
    captured = capsys.readouterr()
    if progress:
        assert all(json.loads(line)["state"] in ("start", "done") for line in captured.out.splitlines())
    write_edl(pipeline / "other.edl.json")
    assert R.main(["--only", "5", "--skip-preflight"]) == 0


def test_soft_target_is_only_forwarded_for_one_unassembled_source(pipeline):
    stage = next(s for s in R.STAGES if s.number == 2)
    args = SimpleNamespace(project="video", assembly=None, max_duration=15.0, aggressive=False, preview=False)
    assert "--target" not in R.stage_args(stage, args)
    (C.TRANSCRIPTS / "a.words.json").write_text("{}")
    assert R.stage_args(stage, args)[-2:] == ["--target", "15.0"]
    (C.TRANSCRIPTS / "b.words.json").write_text("{}")
    assert "--target" not in R.stage_args(stage, args)
    args.assembly = "synthetic order.json"
    assert "--target" not in R.stage_args(stage, args)


def test_dry_run_is_explicitly_unverified_and_never_requires_or_writes_edl(pipeline, monkeypatch, capsys):
    monkeypatch.setattr(R, "run_stage", lambda *a: 0)
    assert R.main(["--from", "2", "--to", "5", "--max-duration", "5", "--dry-run", "--skip-preflight", "--progress", "json"]) == 0
    captured = capsys.readouterr()
    assert "does not verify or accept" in captured.err
    assert not pipeline.exists()
    assert all(json.loads(line)["state"] in ("start", "done") for line in captured.out.splitlines())


def test_bounded_json_setup_preflight_stays_read_only(pipeline, monkeypatch, capsys):
    monkeypatch.setattr(R, "run_stage", lambda *a: pytest.fail("a stage ran during setup preflight"))
    assert R.main(["--dry-run", "--json", "--min-duration", "1", "--max-duration", "20"]) == 0
    assert json.loads(capsys.readouterr().out)["ready"] is True
    assert not pipeline.exists()


@pytest.mark.parametrize("progress", [False, True])
@pytest.mark.parametrize("duration,bound", [("20s", ["--max-duration", "5"]), ("1s", ["--min-duration", "2"])])
def test_emitted_timeline_gate_overrules_in_bounds_edl(progress, duration, bound, pipeline, monkeypatch, capsys):
    edl = write_edl(pipeline / "clip.edl.json", ((0, 3),))
    edl_original = edl.read_bytes()
    final = C.EXPORTS / "video001.fcpxml"
    def stage(s, *args):
        write_final(final, duration)
        return 0
    monkeypatch.setattr(R, "run_stage", stage)
    argv = ["--only", "5", "--skip-preflight", *bound]
    if progress:
        argv += ["--progress", "json"]
    assert R.main(argv) == 1
    captured = capsys.readouterr()
    assert "emitted final timeline" in captured.err
    assert edl.read_bytes() == edl_original
    assert final.is_file()  # Failed outputs remain available for review, never accepted.
    if progress:
        events = [json.loads(line) for line in captured.out.splitlines()]
        assert [(e["stage"], e["state"]) for e in events] == [(5, "start"), (5, "fail")]
        assert "emitted final timeline" in events[-1]["detail"]
    else:
        assert "STOPPED at stage 5" in captured.out
        assert "OVER TO FINAL CUT" not in captured.out


@pytest.mark.parametrize("progress", [False, True])
@pytest.mark.parametrize("failure", ["missing", "malformed", "missing-duration", "ambiguous-sequence"])
def test_missing_or_malformed_final_output_cannot_succeed(progress, failure, pipeline, monkeypatch, capsys):
    write_edl(pipeline / "clip.edl.json", ((0, 3),))
    # A neighboring valid cut must never replace the explicitly expected output.
    write_final(C.EXPORTS / "other.fcpxml", "3s")
    final = C.EXPORTS / "video001.fcpxml"
    def stage(s, *args):
        if failure == "malformed":
            final.write_bytes(b"<fcpxml><library>")
        elif failure == "missing-duration":
            write_final(final, "3s")
            final.write_text(final.read_text().replace(' duration="3s"', ""))
        elif failure == "ambiguous-sequence":
            write_final(final, "3s")
            final.write_text(final.read_text().replace("</project>", '<sequence duration="3s"/></project>'))
        return 0
    monkeypatch.setattr(R, "run_stage", stage)
    argv = ["--only", "5", "--skip-preflight", "--max-duration", "5"]
    if progress:
        argv += ["--progress", "json"]
    assert R.main(argv) == 1
    captured = capsys.readouterr()
    assert "cannot verify emitted video001.fcpxml" in captured.err
    if progress:
        assert json.loads(captured.out.splitlines()[-1])["state"] == "fail"
    else:
        assert "OVER TO FINAL CUT" not in captured.out


@pytest.mark.parametrize("value", ["", "nan", "infs", "1/0s", "0s", "-1s", "5", "1e309s", "1/2/3s"])
def test_final_sequence_requires_positive_finite_rational_seconds(tmp_path, value):
    path = write_final(tmp_path / "video.fcpxml", value)
    with pytest.raises(DurationReviewRequired, match="cannot verify emitted"):
        check_final_output(tmp_path, "video", DurationBounds(maximum=20))


def test_final_output_accepts_exact_rational_bounds_and_preserves_bytes(tmp_path):
    path = write_final(tmp_path / "My Cut.fcpxml", "1001/240s")
    original = path.read_bytes()
    actual = float(Fraction(1001, 240))
    assert check_final_output(tmp_path, "My Cut", DurationBounds(actual, actual)) == actual
    assert path.read_bytes() == original
    assert check_final_output(tmp_path / "missing", "video", DurationBounds()) is None


@pytest.mark.parametrize("encoding", ["utf-8", "utf-16"])
@pytest.mark.parametrize("declaration", [
    '<!DOCTYPE fcpxml SYSTEM "file:///must-not-read.dtd">',
    '<!DOCTYPE fcpxml [<!ENTITY duration "3s">]>',
    '<!DOCTYPE fcpxml [<!ENTITY duration SYSTEM "file:///must-not-read.txt">]>',
    '<!DOCTYPE fcpxml [<!ENTITY % external SYSTEM "https://example.invalid/never.dtd"> %external;]>',
])
def test_final_parser_refuses_entities_and_external_dtds_in_every_encoding(encoding, declaration):
    data = (f'<?xml version="1.0" encoding="{encoding}"?>{declaration}'
            '<fcpxml><library><event><project><sequence duration="3s"/>'
            '</project></event></library></fcpxml>').encode(encoding)
    with pytest.raises(ValueError, match="DOCTYPE|entit"):
        final_sequence_duration(data)


@pytest.mark.parametrize("project", ["../outside", "/outside", "nested/video", "..", ".", ""])
def test_unsafe_final_output_names_fail_before_composite_work(pipeline, monkeypatch, project):
    write_edl(pipeline / "clip.edl.json", ((0, 3),))
    monkeypatch.setattr(R, "run_stage", lambda *a: pytest.fail("render ran with unsafe output identity"))
    assert R.main(["--only", "5", "--skip-preflight", "--max-duration", "5", "--project", project]) == 1


def test_final_output_alias_is_rejected_before_composite_and_preserves_target(pipeline, monkeypatch):
    write_edl(pipeline / "clip.edl.json", ((0, 3),))
    target = write_final(C.EXPORTS / "original.fcpxml", "3s")
    original = target.read_bytes()
    (C.EXPORTS / "video001.fcpxml").symlink_to(target)
    monkeypatch.setattr(R, "run_stage", lambda *a: pytest.fail("render ran through another output's alias"))
    assert R.main(["--only", "5", "--skip-preflight", "--max-duration", "5"]) == 1
    assert target.read_bytes() == original
