"""
lut.py — bake an ffmpeg colour chain into a .cube LUT Final Cut can apply.

The pipeline never flattens a grade into the media [S-006]; but a grade that lives only in a
preview's filter string is a grade nobody can apply in the timeline. A .cube is the one form
that both ffmpeg (`lut3d`) and Final Cut's Custom LUT effect read, so the same numbers grade
the preview and the edit. Built by pushing an identity Hald CLUT through the chain and
reading back where every colour landed — no colour maths of our own.

    ./run tools/lut.py "curves=all='0/0 0.5/0.55 1/0.96',eq=saturation=1.3" assets/luts/x.cube
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

LEVEL = 8                       # Hald level 8 → 64³ entries, Final Cut's preferred size


def bake(chain: str, out: Path, title: str = "") -> Path:
    size = LEVEL * LEVEL
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"haldclutsrc={LEVEL}",
         "-vf", f"format=rgb24,{chain},format=rgb24", "-frames:v", "1",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True, check=True).stdout
    px = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.float64) / 255.0
    # haldclutsrc lays the cube out red-fastest, then green, then blue — the order .cube wants.
    assert len(px) == size ** 3, f"expected {size ** 3} samples, got {len(px)}"
    lines = [f'TITLE "{title or out.stem}"', f"LUT_3D_SIZE {size}",
             "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
    lines += [f"{r:.6f} {g:.6f} {b:.6f}" for r, g, b in px]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Bake an ffmpeg filter chain into a .cube LUT")
    ap.add_argument("chain", help="ffmpeg video filter chain, e.g. curves=…,eq=saturation=1.3")
    ap.add_argument("out", help=".cube path")
    args = ap.parse_args(argv)
    out = bake(args.chain, Path(args.out).expanduser().resolve())
    print(f"  ✓ {out}  ({out.stat().st_size / 1e6:.1f} MB, {LEVEL * LEVEL}³)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
