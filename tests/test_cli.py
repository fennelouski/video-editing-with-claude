"""
Entry-point robustness (CLAUDE.md § Conventions).

Every one of these came from a real failure. Final Cut 11 exports a `.fcpxmld` *bundle* — a
directory containing `Info.fcpxml` — so that is what a human hands any tool here, and
`roundtrip.py` answered it with `IsADirectoryError` and a traceback. Meanwhile `python3` on
macOS is Xcode's 3.9 rather than the project venv, and nothing said so.

A traceback tells the reader to debug our code when the actual answer is "point at the other
file" or "use ./run". So the contract these tests enforce is: **one sentence, naming the fix,
and a non-zero exit** — on every entry point, not just the one that broke.
"""

from __future__ import annotations

import importlib
import subprocess
import sys
from pathlib import Path

import pytest

import cli
import config as C


ROOT = Path(__file__).resolve().parent.parent


# --------------------------------------------------------------------------------------
# Path resolution
# --------------------------------------------------------------------------------------

def make_bundle(tmp_path, name="smoke 9:16.fcpxmld", inner="Info.fcpxml"):
    """A Final Cut 11 export, colon and space included — that is a real export name."""
    bundle = tmp_path / name
    bundle.mkdir()
    (bundle / inner).write_text("<fcpxml version='1.13'/>")
    return bundle


def test_fcpxmld_bundle_resolves_to_its_inner_document(tmp_path):
    """The failure that started this. FCP 11 exports a bundle by default."""
    bundle = make_bundle(tmp_path)
    resolved = cli.resolve_input(bundle, expect=(".fcpxml",), label="export")
    assert resolved.name == "Info.fcpxml"
    assert resolved.exists()


def test_bundle_with_a_differently_named_document_still_resolves(tmp_path):
    bundle = make_bundle(tmp_path, inner="smoke 9-16.fcpxml")
    assert cli.resolve_input(bundle).name == "smoke 9-16.fcpxml"


def test_empty_bundle_says_what_it_contains(tmp_path):
    bundle = tmp_path / "empty.fcpxmld"
    bundle.mkdir()
    (bundle / "README.txt").write_text("nothing useful")
    with pytest.raises(cli.InputError) as exc:
        cli.resolve_input(bundle)
    assert "no .fcpxml" in str(exc.value)
    assert "README.txt" in str(exc.value)


def test_a_plain_directory_is_refused_in_one_sentence(tmp_path):
    with pytest.raises(cli.InputError) as exc:
        cli.resolve_input(tmp_path, label="export")
    message = str(exc.value)
    assert "is a directory" in message
    assert "\n" not in message, "a refusal is one sentence, not a paragraph"


def test_a_directory_containing_the_file_suggests_it(tmp_path):
    """The commonest near-miss: she dragged the folder rather than the file inside it."""
    (tmp_path / "video001.fcpxml").write_text("<fcpxml/>")
    with pytest.raises(cli.InputError) as exc:
        cli.resolve_input(tmp_path, label="export")
    assert "did you mean video001.fcpxml" in str(exc.value)


def test_missing_path_names_itself(tmp_path):
    with pytest.raises(cli.InputError) as exc:
        cli.resolve_input(tmp_path / "nope.fcpxml")
    assert "nope.fcpxml" in str(exc.value) and "does not exist" in str(exc.value)


def test_wrong_kind_of_file_says_what_it_is_and_what_was_wanted(tmp_path):
    wrong = tmp_path / "notes.txt"
    wrong.write_text("hello")
    with pytest.raises(cli.InputError) as exc:
        cli.resolve_input(wrong, expect=(".fcpxml",), label="export")
    message = str(exc.value)
    assert "is a .txt file" in message and ".fcpxml" in message


def test_trailing_slash_from_tab_completion(tmp_path):
    bundle = make_bundle(tmp_path)
    assert cli.resolve_input(str(bundle) + "/").name == "Info.fcpxml"


def test_tilde_expands(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "x.fcpxml").write_text("<fcpxml/>")
    assert cli.resolve_input("~/x.fcpxml") == tmp_path / "x.fcpxml"


def test_spaces_and_colons_survive(tmp_path):
    """`smoke 9:16.fcpxmld` is a real export name from this project."""
    odd = tmp_path / "smoke 9:16 final.fcpxml"
    odd.write_text("<fcpxml/>")
    assert cli.resolve_input(odd, expect=(".fcpxml",)) == odd


def test_symlink_resolves(tmp_path):
    target = tmp_path / "real.fcpxml"
    target.write_text("<fcpxml/>")
    link = tmp_path / "link.fcpxml"
    link.symlink_to(target)
    assert cli.resolve_input(link, expect=(".fcpxml",)) == target


def test_empty_argument_is_refused():
    for value in ("", "   "):
        with pytest.raises(cli.InputError):
            cli.resolve_input(value, label="export")


def test_resolve_or_exit_gives_a_one_line_systemexit(tmp_path):
    with pytest.raises(SystemExit) as exc:
        cli.resolve_or_exit(tmp_path / "gone.json", label="plan")
    assert str(exc.value).startswith("! ")
    assert "gone.json" in str(exc.value)


# --------------------------------------------------------------------------------------
# Interpreter
# --------------------------------------------------------------------------------------

def test_preflight_passes_under_the_venv():
    cli.preflight(("numpy", "PIL"))


def test_preflight_names_the_fix_for_an_old_interpreter(monkeypatch):
    monkeypatch.setattr(sys, "version_info", (3, 9, 6, "final", 0))
    with pytest.raises(SystemExit) as exc:
        cli.preflight()
    message = str(exc.value)
    assert "3.9.6" in message and "3.10" in message
    assert "./run" in message, "the message must name the fix, not just the problem"


def test_preflight_names_the_fix_for_a_missing_dependency():
    with pytest.raises(SystemExit) as exc:
        cli.preflight(("definitely_not_installed_xyz",))
    message = str(exc.value)
    assert "definitely_not_installed_xyz" in message
    assert "./run" in message and "requirements.txt" in message


# --------------------------------------------------------------------------------------
# The ./run wrapper
# --------------------------------------------------------------------------------------

def test_run_wrapper_is_executable():
    wrapper = ROOT / "run"
    assert wrapper.exists()
    assert wrapper.stat().st_mode & 0o111, "./run must be executable or it is not a fix"


def test_run_wrapper_finds_scripts_by_bare_name():
    """Remembering which directory a tool lives in is not the user's job."""
    out = subprocess.run([str(ROOT / "run"), "roundtrip.py", "--help"],
                         capture_output=True, text=True, cwd=ROOT, timeout=120)
    assert out.returncode == 0, out.stderr
    assert "usage" in out.stdout.lower()


def test_run_wrapper_finds_tools_by_bare_name():
    out = subprocess.run([str(ROOT / "run"), "segment_sheet.py", "--help"],
                         capture_output=True, text=True, cwd=ROOT, timeout=120)
    assert out.returncode == 0, out.stderr


def test_run_wrapper_reports_an_unknown_script():
    out = subprocess.run([str(ROOT / "run"), "nope.py"],
                         capture_output=True, text=True, cwd=ROOT, timeout=120)
    assert out.returncode != 0
    assert "no such script" in out.stderr


# --------------------------------------------------------------------------------------
# Every entry point, not just the one that broke
# --------------------------------------------------------------------------------------

# (module, argv-builder taking a path) for every entry point that accepts a human path.
ENTRY_POINTS = [
    ("stage1_transcribe", lambda p: [str(p)]),
    ("stage2_roughcut", lambda p: [str(p)]),
    ("stage3_plan", lambda p: [str(p), "--dry-run"]),
    ("stage4_assets", lambda p: [str(p)]),
    ("stage5_composite", lambda p: [str(p), "--dry-run"]),
    ("stage6_watch", lambda p: [str(p)]),
    ("roundtrip", lambda p: [str(p)]),
    ("molecule", lambda p: [str(p)]),
    ("segment_sheet", lambda p: [str(p), "--seamless", "0.46,0.46,0.46",
                                 "--shadow", "0.34,0.34,0.34"]),
    ("build_font", lambda p: [str(p), "--glyph", "e", "--min-gap", "60"]),
    ("verify_font_browser", lambda p: [str(p)]),
]


def run_entry(module_name: str, argv: list[str]) -> tuple[int, str]:
    """Invoke an entry point's main() and capture how it refused."""
    module = importlib.import_module(module_name)
    try:
        code = module.main(argv)
    except SystemExit as exc:
        return (1 if exc.code is None else
                (exc.code if isinstance(exc.code, int) else 1)), str(exc)
    return code, ""


@pytest.mark.parametrize("module_name,argv_for", ENTRY_POINTS,
                         ids=[m for m, _ in ENTRY_POINTS])
def test_missing_path_is_clean_on_every_entry_point(module_name, argv_for, tmp_path, capsys):
    code, message = run_entry(module_name, argv_for(tmp_path / "absent.xyz"))
    output = message + capsys.readouterr().out
    assert code != 0, f"{module_name} accepted a nonexistent path"
    assert "absent.xyz" in output, f"{module_name} did not name the path: {output[:200]}"


@pytest.mark.parametrize("module_name,argv_for", ENTRY_POINTS,
                         ids=[m for m, _ in ENTRY_POINTS])
def test_bare_directory_is_clean_on_every_entry_point(module_name, argv_for, tmp_path, capsys):
    """A directory where a file was expected must not traceback."""
    folder = tmp_path / "a folder"
    folder.mkdir()
    code, message = run_entry(module_name, argv_for(folder))
    output = message + capsys.readouterr().out
    assert code != 0, f"{module_name} accepted a directory"
    assert "directory" in output.lower(), f"{module_name}: {output[:200]}"


@pytest.mark.parametrize("module_name,argv_for", ENTRY_POINTS,
                         ids=[m for m, _ in ENTRY_POINTS])
def test_wrong_type_is_clean_on_every_entry_point(module_name, argv_for, tmp_path, capsys):
    """Naming what the file *is* saves the round trip of "well what did you want?"."""
    wrong = tmp_path / "holiday.jpg.zip"
    wrong.write_bytes(b"not what you wanted")
    code, message = run_entry(module_name, argv_for(wrong))
    output = message + capsys.readouterr().out
    assert code != 0, f"{module_name} accepted a .zip"
    assert "holiday.jpg.zip" in output or "zip" in output.lower(), f"{module_name}: {output[:200]}"


def test_roundtrip_accepts_a_real_fcpxmld_bundle(tmp_path, video, capsys):
    """End to end on the shape that actually broke: a bundle, not a file."""
    import fcpxml as FX

    builder = FX.FCPXMLBuilder(project="p", aspect="16:9")
    clips = [FX.Clip(asset_path=video, offset=0.0, start=0.0, duration=2.0, name="one")]
    inner = builder.write(builder.build(clips, []), tmp_path / "tmp.fcpxml")

    bundle = tmp_path / "exported 9:16.fcpxmld"
    bundle.mkdir()
    (bundle / "Info.fcpxml").write_text(inner.read_text())

    import roundtrip as RT
    assert RT.main([str(bundle)]) == 0
    assert "1920x1080" in capsys.readouterr().out
