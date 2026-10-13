"""GUI engine contracts are additive, project-scoped and read-only during preflight."""
import json
import os
import subprocess
import sys
from pathlib import Path

import run_pipeline as R
import config as C
import stage1_transcribe as S1
import stage4_assets as S4
import stage5_composite as S5
import fcpxml as FX
import hashlib
import pytest
from types import SimpleNamespace


def test_project_paths_resolve_relative_to_manifest(tmp_path):
    paths = tmp_path / "paths.json"
    paths.write_text(json.dumps({key: key for key in C._PATH_KEYS} | {"whisper_model": "small"}))
    proc = subprocess.run([sys.executable, "-c", "import config as c; print(c.FOOTAGE); print(c.SCRIPT_DIR); print(c.WHISPER_MODEL)"],
                          env=os.environ | {"CLAUTO_PATHS": str(paths), "PYTHONPATH": str(C.ROOT / "scripts")},
                          capture_output=True, text=True, check=True)
    assert proc.stdout.splitlines() == [str(tmp_path / "footage"), str(tmp_path / "script"), "small"]


def test_explicit_missing_manifest_never_falls_back(tmp_path):
    proc = subprocess.run([sys.executable, "-c", "import config"],
                          env=os.environ | {"CLAUTO_PATHS": str(tmp_path / "missing.json"), "PYTHONPATH": str(C.ROOT / "scripts")},
                          capture_output=True, text=True)
    assert proc.returncode != 0
    assert "reopen the project drive" in proc.stderr


def test_partial_project_manifest_never_writes_repo_fallbacks(tmp_path):
    manifest = tmp_path / "paths.json"
    manifest.write_text(json.dumps({"footage": "footage"}))
    proc = subprocess.run([sys.executable, "-c", "import config"],
                          env=os.environ | {"CLAUTO_PATHS": str(manifest), "PYTHONPATH": str(C.ROOT / "scripts")},
                          capture_output=True, text=True)
    assert proc.returncode != 0
    assert "project paths missing assets, build, cuts" in proc.stderr


def test_json_preflight_does_not_import_stages_or_create_output(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(C, "ALL_BUILD_DIRS", [tmp_path / "never-created"])
    monkeypatch.setattr(R, "preflight", lambda verbose=False: ["Drop the required scan."])
    monkeypatch.setattr(R, "run_stage", lambda *a: (_ for _ in ()).throw(AssertionError("stage ran")))
    assert R.main(["--dry-run", "--json"]) == 1
    result = json.loads(capsys.readouterr().out)
    assert result["ready"] is False
    assert result["problems"] == ["Drop the required scan."]
    assert not (tmp_path / "never-created").exists()


def test_progress_stops_at_asset_gate_and_keeps_stdout_json(monkeypatch, capsys):
    monkeypatch.setattr(C, "ALL_BUILD_DIRS", [])
    monkeypatch.setattr(R, "preflight", lambda: [])
    def stage(s, *args):
        print("synthetic detail")
        return 3 if s.number == 4 else 0
    monkeypatch.setattr(R, "run_stage", stage)
    assert R.main(["--from", "3", "--to", "5", "--progress", "json"]) == 3
    captured = capsys.readouterr()
    events = [json.loads(line) for line in captured.out.splitlines()]
    assert [(e["stage"], e["state"]) for e in events] == [(3, "start"), (3, "done"), (4, "start"), (4, "fail")]
    assert "synthetic detail" in captured.err


def test_setup_noninteractive_handles_spaces_and_preserves_original(tmp_path):
    manifest = tmp_path / "My Project" / "paths.json"
    args = [sys.executable, str(C.ROOT / "scripts/setup.py"), "--paths", str(manifest), "--whisper-model", "small"]
    for key in C._PATH_KEYS:
        args += [f"--{key}", str(tmp_path / "My Project" / key)]
    subprocess.run(args, capture_output=True, check=True)
    data = json.loads(manifest.read_text())
    assert data["whisper_model"] == "small"
    assert data["script"] == str(manifest.parent / "script")
    subprocess.run(args, capture_output=True, check=True)
    assert json.loads(manifest.read_text()) == data


def test_model_prefetch_loads_speech_and_alignment_without_footage(monkeypatch):
    calls = []
    fake = SimpleNamespace(load_model=lambda *a, **k: calls.append(("speech", a, k)),
                           load_align_model=lambda **k: calls.append(("alignment", (), k)))
    monkeypatch.setitem(sys.modules, "whisperx", fake)
    monkeypatch.setattr(S1, "find_clips", lambda *a: (_ for _ in ()).throw(AssertionError("footage scanned")))
    assert S1.main(["--download-model", "small"]) == 0
    assert calls == [("speech", ("small", "cpu"), {"compute_type": "int8", "language": "en"}),
                     ("alignment", (), {"language_code": "en", "device": "cpu"})]


def test_gui_offline_runner_blocks_network_before_script_execution(tmp_path):
    script = tmp_path / "network probe.py"
    script.write_text("import socket; socket.socket().connect(('127.0.0.1', 9))")
    proc = subprocess.run([str(C.ROOT / "run"), str(script)], env=os.environ | {"CLAUTO_OFFLINE": "1"}, capture_output=True, text=True)
    assert proc.returncode != 0
    assert "Clauto is offline" in proc.stderr


def test_offline_transcription_cannot_fall_back_to_unrestricted_cli(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUTO_OFFLINE", "1")
    with pytest.raises(RuntimeError, match="local WhisperX API"):
        S1._transcribe_cli(tmp_path / "synthetic.wav", "small", "en", "cpu")


def test_camera_extensions_and_audio_formats_are_consistent(tmp_path, monkeypatch):
    for ext in (".MTS", ".m2ts", ".MXF"):
        (tmp_path / ("narration" + ext)).write_bytes(b"synthetic")
    monkeypatch.setattr(C, "FOOTAGE", tmp_path)
    assert len(S1.find_clips(None)) == 3
    assert {".aif", ".aiff"} <= S4.KIND_DIRS["music"][1]
    monkeypatch.setattr(C, "TEXTURES", tmp_path)
    (tmp_path / "paper-grain_v01.jpg").write_bytes(b"synthetic")
    assert S5.find_variants("texture:paper-grain") == [tmp_path / "paper-grain_v01.jpg"]


def test_strict_asset_warnings_stop_before_render(tmp_path, monkeypatch):
    plan = tmp_path / "video.plan.json"
    plan.write_text(json.dumps({"project": "video", "cues": []}))
    monkeypatch.setattr(C, "PLAN_DIR", tmp_path)
    monkeypatch.setattr(S4, "resolve_ref", lambda ref: S4.Resolution(ref, "texture", ref.split(":")[1], "warn", notes=["Synthetic low resolution"]))
    assert S4.main([str(plan), "--strict-assets"]) == 3
    assert json.loads((tmp_path / "video.assets.json").read_text())["warn"] == 2


def test_assembled_timeline_has_hash_bound_validation_report(tmp_path, monkeypatch, video):
    monkeypatch.setattr(C, "PLAN_DIR", tmp_path)
    (tmp_path / "video.plan.json").write_text(json.dumps({"cues": []}))
    edl = tmp_path / "video.edl.json"
    edl.write_text(json.dumps({"source": str(video), "keeps": [{"start": 0, "end": 1}]}))
    out = tmp_path / "video.fcpxml"
    assert S5.assemble("video", "16:9", edl, [], out) == out
    report = json.loads(out.with_suffix(".validation.json").read_text())
    assert report["sha256"] == hashlib.sha256(out.read_bytes()).hexdigest()
    assert report["timeline"] == out.name
    assert report["problems"] == []
    assert FX.validate(out) == []
    monkeypatch.setattr(FX, "validate", lambda path: ["synthetic invalid timeline"])
    with pytest.raises(RuntimeError, match="FCPXML validation failed"):
        S5.assemble("video", "16:9", edl, [], tmp_path / "invalid.fcpxml")
    assert not (tmp_path / "invalid.validation.json").exists()


def test_explicit_approved_script_is_forwarded_to_planning(tmp_path):
    script = tmp_path / "Approved script.md"
    args = SimpleNamespace(project="video", script=str(script))
    stage = next(s for s in R.STAGES if s.key == "plan")
    assert R.stage_args(stage, args) == ["--project", "video", str(script)]
