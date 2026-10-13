"""
tools/assemble.py — the editorial pass across clips.

Two things here carry a rule rather than arithmetic: an insert may cover only the head of a
pick, and a static punch-in is refused unless the eye has ≥ 10 s of settled picture either side.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

import pytest

import config as C

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "tools"))
import assemble  # noqa: E402


def picks_file(tmp_path, video, picks) -> Path:
    p = tmp_path / "picks.json"
    p.write_text(json.dumps({"project": "t", "picks": [
        {"source": str(video), **x} for x in picks]}))
    return p


def test_an_insert_may_cover_only_the_head_of_a_pick(tmp_path, video):
    path = picks_file(tmp_path, video, [
        {"start": 0.0, "end": 4.0, "note": "a",
         "video": {"source": str(video), "start": 1.0, "duration": 1.5}}])
    project, picks, _ = assemble.load_picks(path)
    assert picks[0]["video"]["duration"] == pytest.approx(C.snap_seconds(1.5), abs=1e-6)

    out, problems = assemble.to_fcpxml(project, picks, tmp_path / "t.fcpxml")
    assert problems == []
    insert = ET.parse(out).getroot().find(".//asset-clip/video")
    num, den = insert.get("duration").rstrip("s").split("/")
    assert int(num) / int(den) == pytest.approx(C.snap_seconds(1.5), abs=1e-6)


def test_static_punch_in_needs_ten_seconds_either_side(tmp_path, video, monkeypatch):
    monkeypatch.setattr(C, "ROUGHCUT", tmp_path / "roughcut")
    # Frame-snapped picks; the middle one is punched in and the last one is too short.
    short = [{"start": 0.0, "end": 3.0, "note": "a", "scale": 1.08},
             {"start": 3.0, "end": 5.0, "note": "b"}]
    path = picks_file(tmp_path, video, short)
    with pytest.raises(SystemExit, match="punched in"):
        assemble.main([str(path), "--no-verify"])

    # A push (animated) is allowed anywhere — it isn't hiding a cut.
    short[0]["scale"] = None
    short[0]["push_to"] = 1.05
    path = picks_file(tmp_path, video, short)
    assert assemble.main([str(path), "--no-verify"]) == 0
