"""
prep_clip.py — make a piece of b-roll fit the hole it has to fill.

Speed it to an exact duration, take the auto-exposure hunting out of it, conform it to the
project timebase. Written because the first insert in Intro 001 needed all three and none of
them are things an FCPXML can carry: a speed ramp and an exposure fix have to exist in media.

The original is never touched. This writes a second file beside it, and the command that made
it is one line, so the prep can be redone from the original at any time — that is what keeps
this from being the flattening [S-006] forbids. What reaches Final Cut is still a clip on a
timeline, not a decision baked into a master.

Three passes, in this order, because the order is the whole trick:

  1. **Deflicker at the source rate**, so the correction is computed from every frame the
     camera shot.
  2. **Speed and conform**, dropping frames.
  3. **Deflicker again**, because dropping two frames in three turns a slow exposure drift into
     a visible step between neighbours — and then even the **chroma**, which `deflicker` does
     not touch at all. A phone or a mirrorless hunting for white balance swings colour as well
     as brightness, and on a 2.7-second opening shot the green flash is the first thing anyone
     sees.

    ./run tools/prep_clip.py in.mov out.mov --duration 2.711
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli
import config as C
import fcpxml as FX

W, H = 1920, 1080


def graph(speed: float) -> str:
    return (f"deflicker=size=10:mode=am,setpts=PTS/{speed:.6f},"
            f"scale={W}:{H}:flags=lanczos,fps={C.FPS_STR},deflicker=size=21:mode=am")


def chroma_offsets(src: Path, speed: float, duration: float) -> tuple[np.ndarray, np.ndarray]:
    """
    Per-frame U and V corrections, taken at thumbnail size because a mean needs no detail.

    A pure offset per frame, toward the clip's median: it moves the cast without touching
    saturation or hue relationships, so a frame that was genuinely warmer stays warmer than its
    neighbours — it just stops jumping there.
    """
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(src), "-an", "-vf",
         f"{graph(speed)},scale=64:36", "-t", f"{duration:.4f}",
         "-pix_fmt", "yuv444p", "-f", "rawvideo", "-"],
        capture_output=True, check=True).stdout
    planes = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3, 36, 64).astype(np.float32)
    u, v = planes[:, 1].mean(axis=(1, 2)), planes[:, 2].mean(axis=(1, 2))
    return np.median(u) - u, np.median(v) - v


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Speed, deflicker and conform a piece of b-roll")
    ap.add_argument("source")
    ap.add_argument("out")
    ap.add_argument("--duration", type=float, required=True,
                    help="seconds it has to fill; the speed follows from it")
    ap.add_argument("--no-chroma", action="store_true", help="skip the white-balance evening")
    args = ap.parse_args(argv)

    src = cli.resolve_or_exit(args.source, expect=(".mov", ".mp4", ".m4v", ".avi"), label="clip")
    out = Path(args.out).expanduser().resolve()
    have = FX.probe(src)["duration"]
    target = C.snap_seconds(args.duration)
    speed = have / target
    print(f"  {src.name}: {have:.3f}s → {target:.3f}s  ({speed:.3f}× faster)")

    du, dv = ((None, None) if args.no_chroma else chroma_offsets(src, speed, target))
    if du is not None:
        print(f"  chroma: correcting up to {max(abs(du).max(), abs(dv).max()):.1f} levels "
              f"of white-balance drift")

    read = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(src), "-an", "-vf", graph(speed),
         "-t", f"{target:.4f}", "-pix_fmt", "yuv444p", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE)
    write = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "yuv444p",
         "-s", f"{W}x{H}", "-r", C.FPS_STR, "-i", "pipe:0",
         "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", str(out)],
        stdin=subprocess.PIPE)

    size, i = W * H, 0
    while chunk := read.stdout.read(size * 3):
        if len(chunk) < size * 3:
            break
        frame = np.frombuffer(chunk, dtype=np.uint8).reshape(3, H, W)
        if du is not None and i < len(du):
            frame = frame.astype(np.int16)
            frame[1] = np.clip(frame[1] + round(float(du[i])), 0, 255)
            frame[2] = np.clip(frame[2] + round(float(dv[i])), 0, 255)
            frame = frame.astype(np.uint8)
        write.stdin.write(frame.tobytes())
        i += 1

    read.stdout.close()
    write.stdin.close()
    read.wait()
    write.wait()
    print(f"  ✓ {out}  ({i} frames, {out.stat().st_size / 1e6:.0f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
