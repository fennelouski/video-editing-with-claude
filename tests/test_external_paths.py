"""External media folders must work without copying private media into Git."""
import json
from pathlib import Path

import config as C
import run_pipeline as R
import stage1_transcribe as S1
import stage4_assets as S4
import pytest


def test_path_label_handles_external_folder(tmp_path):
    path = tmp_path / "NAS folder" / "clip.MOV"
    assert C.path_label(path) == str(path)
    assert C.path_label(C.ROOT / "script/yeast.md") == "script/yeast.md"


def test_preflight_reports_missing_external_assets_without_traceback(tmp_path, monkeypatch):
    monkeypatch.setattr(C, "FOOTAGE", tmp_path / "footage")
    monkeypatch.setattr(C, "TEXTURES", tmp_path / "textures")
    monkeypatch.setattr(C, "FONTS", tmp_path / "fonts")
    problems = R.preflight(verbose=False)
    assert any(str(C.TEXTURES) in p for p in problems)
    assert any(str(C.FOOTAGE) in p for p in problems)


def test_external_assets_and_build_sheet_are_usable(tmp_path, monkeypatch):
    directory = tmp_path / "NAS assets" / "broll"
    directory.mkdir(parents=True)
    clip = directory / "bubbles.MOV"
    clip.write_bytes(b"synthetic")
    monkeypatch.setitem(S4.KIND_DIRS, "broll", (directory, S4.VIDEO_EXTS))
    result = S4.resolve_ref("broll:bubbles")
    assert result.files == [str(clip)]
    assert (C.ROOT / result.files[0]) == clip
    missing = S4.resolve_ref("broll:missing")
    sheet = S4.write_build_sheet("synthetic", [missing], tmp_path / "sheet.md")
    assert str(directory) in sheet.read_text()


def test_transcript_external_output_and_source_collision(tmp_path, monkeypatch):
    monkeypatch.setattr(C, "TRANSCRIPTS", tmp_path / "NAS build" / "transcripts")
    monkeypatch.setattr(S1, "extract_audio", lambda *a: None)
    monkeypatch.setattr(S1, "transcribe", lambda *a, **k: {
        "segments": [{"words": [{"word": "synthetic", "start": 0, "end": 1}]}]})
    clip = tmp_path / "card one" / "MVI_0001.MOV"
    output = S1.process_clip(clip, "tiny", "en", "cpu", False, False)
    assert json.loads(output.read_text())["source"] == str(clip)
    assert S1.process_clip(clip, "tiny", "en", "cpu", False, False) == output
    with pytest.raises(RuntimeError, match="same filename"):
        S1.process_clip(tmp_path / "card two" / clip.name, "tiny", "en", "cpu", False, True)


def test_failed_dry_run_has_nonzero_status(monkeypatch):
    monkeypatch.setattr(C, "ALL_BUILD_DIRS", [])
    monkeypatch.setattr(R.cli, "preflight", lambda: None)
    monkeypatch.setattr(R, "preflight", lambda: ["missing synthetic fixture"])
    monkeypatch.setattr(R, "run_stage", lambda *a: 1)
    assert R.main(["--dry-run", "--only", "1"]) == 1
