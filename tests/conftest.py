"""
Shared pytest wiring.

The stages import `config` as a top-level module (`import config as C`), so `scripts/` has
to be on the path before any of them can be imported.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import fixtures as FX          # noqa: E402


# --------------------------------------------------------------------------------------
# Session-scoped fixtures — the expensive ones are built once
# --------------------------------------------------------------------------------------

@pytest.fixture(scope="session")
def words() -> list[dict]:
    return FX.build_words()


@pytest.fixture(scope="session")
def transcript_path(tmp_path_factory) -> Path:
    return FX.write_transcript(tmp_path_factory.mktemp("transcripts") / "a-cam_001.words.json")


@pytest.fixture(scope="session")
def script_md(tmp_path_factory) -> Path:
    return FX.write_script_md(tmp_path_factory.mktemp("script") / "yeast.md")


@pytest.fixture(scope="session")
def cutouts(tmp_path_factory) -> dict[str, list[Path]]:
    return FX.write_cutout_set(tmp_path_factory.mktemp("cutouts"))


@pytest.fixture(scope="session")
def grain(tmp_path_factory) -> Path:
    # Small: the grain is resized to the canvas anyway, and a full 1920x1080 of seeded
    # per-pixel noise costs more wall-clock than the rest of the suite combined.
    return FX.write_grain(tmp_path_factory.mktemp("textures") / "paper-grain_flat.png",
                          size=(480, 270))


@pytest.fixture(scope="session")
def video(tmp_path_factory) -> Path:
    return FX.write_video(tmp_path_factory.mktemp("footage") / "a-cam_001.mp4")


@pytest.fixture(scope="session")
def edl(words):
    """Stage 2's EDL for the fixture transcript, with filler removal on."""
    import stage2_roughcut as S2
    meta = {"clip": "a-cam_001", "source": "footage/a-cam/a-cam_001.mp4"}
    return S2.build_edl(meta, words, aggressive=True)
