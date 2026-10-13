"""GUI engine contracts are additive, project-scoped and read-only during preflight."""
import json
import os
import subprocess
import sys
from pathlib import Path

import run_pipeline as R
import config as C
import stage1_transcribe as S1
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
