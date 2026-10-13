"""
cli.py — take what a human will actually hand us, and check we can run at all.

Two failures that are not the user's fault and must never reach a traceback:

**The path.** Final Cut 11 exports a `.fcpxmld` *bundle* — a directory containing `Info.fcpxml`
— so that is what anyone will hand any tool here. Finder also produces paths with spaces and
colons, trailing slashes from tab-completion, `~`, symlinks and aliases. An entry point that
accepts only the canonical form and raises `IsADirectoryError` otherwise is unfinished.

**The interpreter.** macOS ships a system Python that is not this project's venv, and `python`
is frequently not on `PATH` at all. Discovering that as an `ImportError` forty frames into
numpy is a bad way to learn it. Every entry point checks first and says the fix in one line.

The shell wrapper `./run` at the repo root exists so there is exactly one correct invocation
and it cannot be got wrong. These checks are the backstop for when someone bypasses it.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

MIN_PYTHON = (3, 10)

# Final Cut 11's default export. The bundle is a directory; the document is inside it.
FCPXML_BUNDLE_SUFFIX = ".fcpxmld"
FCPXML_BUNDLE_INNER = "Info.fcpxml"

ROOT = Path(__file__).resolve().parent.parent
VENV_PYTHON = ROOT / ".venv" / "bin" / "python"


class InputError(Exception):
    """A path we cannot use, explained in one sentence."""


# --------------------------------------------------------------------------------------
# Interpreter
# --------------------------------------------------------------------------------------

def _how_to_run() -> str:
    return (f"Run it through the project venv:\n"
            f"    ./run {Path(sys.argv[0]).name if sys.argv and sys.argv[0] else 'script.py'} …\n"
            f"  or {VENV_PYTHON} …")


def preflight(needs: tuple[str, ...] = ()) -> None:
    """
    Refuse to start under an interpreter that cannot finish, naming the fix.

    Called at the top of every entry point rather than relying on imports to fail naturally:
    a missing dependency surfaces as an ImportError deep inside a third-party module, which
    says nothing about the venv and everything about somebody else's code.
    """
    if sys.version_info < MIN_PYTHON:
        need = ".".join(str(v) for v in MIN_PYTHON)
        have = ".".join(str(v) for v in sys.version_info[:3])
        raise SystemExit(
            f"! this pipeline needs Python {need}+, and this is {have} "
            f"({sys.executable}).\n"
            f"  macOS ships an older Python that is not the project venv.\n"
            f"  {_how_to_run()}"
        )

    missing = []
    for module in needs:
        try:
            __import__(module)
        except ImportError:
            missing.append(module)
    if missing:
        raise SystemExit(
            f"! missing dependenc{'y' if len(missing) == 1 else 'ies'}: "
            f"{', '.join(missing)} — running under {sys.executable}.\n"
            f"  {_how_to_run()}\n"
            f"  If the venv does not exist yet: "
            f"python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
        )


# --------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------

def _is_finder_alias(path: Path) -> bool:
    """
    A Finder alias is not a symlink — it is a regular file carrying bookmark data, so every
    normal path operation on it silently reads the alias rather than its target.
    """
    try:
        out = subprocess.run(["mdls", "-name", "kMDItemContentType", "-raw", str(path)],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return out == "com.apple.alias-file"


def _resolve_finder_alias(path: Path) -> Path | None:
    script = (f'tell application "Finder" to return POSIX path of '
              f'(original item of (POSIX file {str(path)!r} as alias) as alias)')
    try:
        out = subprocess.run(["osascript", "-e", script],
                             capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    target = out.stdout.strip()
    return Path(target) if out.returncode == 0 and target else None


def describe(path: Path) -> str:
    """What a path actually is, for an error message that tells the reader something."""
    if not path.exists():
        return "does not exist"
    if path.is_dir():
        return "is a directory"
    suffix = path.suffix.lower()
    return f"is a {suffix} file" if suffix else "is a file with no extension"


def resolve_input(raw: str | Path, *, expect: tuple[str, ...] = (),
                  label: str = "input") -> Path:
    """
    Turn whatever a human typed or dragged in into a file we can open.

    Handles, in order: `~`, trailing slashes from tab-completion, symlinks, Finder aliases,
    and `.fcpxmld` bundles. Everything it cannot resolve becomes one sentence naming what the
    path is and what was wanted — never a traceback, because a traceback tells the reader to
    debug our code when the actual answer is "point at the other file".

    `expect` is a tuple of acceptable suffixes. Empty means anything is acceptable.
    """
    if raw is None or str(raw).strip() == "":
        raise InputError(f"no {label} given")

    # Trailing slashes arrive from shell tab-completion on directories; `~` from typing a path
    # by hand rather than dragging one in.
    text = str(raw).strip().rstrip("/")
    path = Path(text).expanduser()

    if _is_finder_alias(path):
        target = _resolve_finder_alias(path)
        if target is None:
            raise InputError(
                f"{path.name} is a Finder alias and its original could not be resolved — "
                f"pass the original file instead"
            )
        path = target

    if path.is_symlink():
        path = path.resolve()

    # A .fcpxmld is Final Cut 11's default export: a bundle directory holding Info.fcpxml.
    if path.suffix.lower() == FCPXML_BUNDLE_SUFFIX and path.is_dir():
        inner = path / FCPXML_BUNDLE_INNER
        if not inner.exists():
            # Some exports name the inner document after the project.
            candidates = sorted(path.glob("*.fcpxml"))
            if not candidates:
                raise InputError(
                    f"{path.name} is a Final Cut export bundle but contains no .fcpxml — "
                    f"it holds {', '.join(p.name for p in sorted(path.iterdir())) or 'nothing'}"
                )
            inner = candidates[0]
        return inner

    if not path.exists():
        raise InputError(f"{path} does not exist")

    if path.is_dir():
        hint = ""
        inner = sorted(path.glob("*.fcpxml")) or sorted(path.glob("*" + FCPXML_BUNDLE_SUFFIX))
        if inner:
            hint = f" — did you mean {inner[0].name} inside it?"
        raise InputError(f"{path.name} is a directory, not a {label}{hint}")

    if expect and path.suffix.lower() not in expect:
        wanted = " or ".join(expect)
        raise InputError(
            f"{path.name} {describe(path)}, but {label} should be {wanted}"
        )

    return path


def resolve_or_exit(raw: str | Path, *, expect: tuple[str, ...] = (),
                    label: str = "input") -> Path:
    """`resolve_input`, but exits with the one-line reason instead of raising."""
    try:
        return resolve_input(raw, expect=expect, label=label)
    except InputError as exc:
        raise SystemExit(f"! {exc}")
