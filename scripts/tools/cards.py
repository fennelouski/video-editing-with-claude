"""
cards.py — title and chapter cards from a picks file, as placeholders until the surface exists.

§6.1 wants a full-frame *scanned* surface under marker type. There is no scan yet and
[S-001] forbids synthesising one, so what this renders is explicitly a stand-in: a flat
`bone` fill, named `_placeholder` in every filename and clip name, so nobody can mistake it
for the finished card. Everything else is done to spec so the timing can be judged now and
only the pixels change later: the type lands on the §5.3 place curve, steps on 2s with §5.2
idle jitter, the rust underline draws on over 4 frames after the text settles, and the hold
comes from the §5.4 formula. The face is Kalam until her marker font exists (§3.2).

    ./run tools/cards.py cuts/yeast001/picks.json
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli
import config as C
import stepclock as SC

W, H = 1920, 1080
FONT = C.FONTS / "Kalam-Bold.ttf"
UNDERLINE_FRAMES = 4        # §6.1 — draws on 4 frames after the text lands


def render(text: str, size_px: int, out: Path, clock: SC.StepClock,
           picture: Path | None = None, hold_seconds: float | None = None,
           mat: bool = False) -> Path:
    """
    A card (text on a full-frame surface) or a picture. Cards take the §5 clock — place
    curve, steps, idle jitter. Pictures are photographs, not cut pieces: they are placed dead
    still, with a hard cut in and out, because a photograph that shivers reads as a mistake
    rather than as stop-motion. With `mat`, the picture sits full-height in the left column
    on an opaque paper ground with a window cut where the reframed footage lands
    (config.REFRAME_*), so nothing covers her.
    """
    words = len(text.split())
    hold = clock.hold_frames(hold_seconds or C.hold_seconds(words))
    place, remove = (0, 0) if picture is not None else (C.PLACE_FRAMES[1], C.REMOVE_FRAMES[1])
    total = place + hold + remove
    fnt = ImageFont.truetype(str(FONT), size_px)
    bg, fg, accent = (C.PALETTE[C.SEMANTIC[k]] for k in ("bg", "fg", "accent"))
    spec = C.ASPECTS[C.DEFAULT_ASPECT]
    x0 = spec["margin_left"] * 2            # column 2
    window = None
    if picture is not None:
        photo = Image.open(picture).convert("RGBA")
        if mat:
            # Footage window (the reframed clip's rectangle), then the column left of it.
            ww, wh = round(W * C.REFRAME_SCALE), round(H * C.REFRAME_SCALE)
            wx = round(W / 2 + C.REFRAME_X - ww / 2)
            wy = round(H / 2 - C.REFRAME_Y - wh / 2)
            window = (wx, wy, wx + ww, wy + wh)
            col_w = wx - spec["margin_left"] - 48
            box_h = H - spec["margin_top"] - spec["margin_bottom"]
            k = min(box_h / photo.height, col_w / photo.width)
        else:
            # In the left third, inside the §2.1 margins: she sits centre-frame in both
            # setups, so anything wider than a third of the frame lands on her face.
            box_h = H - spec["margin_top"] - spec["margin_bottom_captioned"] - 64
            k = min(box_h / photo.height, 560 / photo.width)
            bg = (0, 0, 0, 0)
        photo = photo.resize((round(photo.width * k), round(photo.height * k)), Image.LANCZOS)
        tw, th = photo.size
        x0 = spec["margin_left"]
        if mat:
            x0 = spec["margin_left"] + (col_w - tw) // 2
        box = (0, 0, tw, th)
    else:
        probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
        box = probe.textbbox((0, 0), text, font=fnt)
        tw, th = box[2] - box[0], box[3] - box[1]
    y0 = round(H * 0.46 - th / 2)           # optical centre, §6.1

    out.parent.mkdir(parents=True, exist_ok=True)
    enc = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba",
         "-s", f"{W}x{H}", "-r", C.FPS_STR, "-i", "pipe:0",
         "-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le", str(out)],
        stdin=subprocess.PIPE)
    last: bytes | None = None
    for frame in range(total):
        if clock.is_hold(frame) and last is not None:
            enc.stdin.write(last)
            continue
        img = Image.new("RGBA", (W, H), bg)
        if picture is not None:
            # Dead still, hard in, hard out — no pose, no jitter, no rotation.
            pose = SC.Transform()
        else:
            pose = SC.pose_at(f"card:{text}", frame, start_frame=0, hold_frames=hold, clock=clock)
        if pose is not None and pose.opacity > 0:
            layer = Image.new("RGBA", (tw + 80, th + 80), (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            if picture is not None:
                layer.alpha_composite(photo, (40, 40))
            else:
                d.text((40 - box[0], 40 - box[1]), text, font=fnt, fill=fg)
            # Underline draws on left→right after the text has settled, stepped like the rest.
            settled = clock.step_frame(frame) - place
            if settled >= 0 and picture is None:
                frac = min(1.0, (settled + clock.step) / UNDERLINE_FRAMES)
                d.line([(40, 40 + th + 14), (40 + tw * frac, 40 + th + 14 + 6)],
                       fill=accent, width=8)
            layer = layer.rotate(pose.rotation, resample=Image.BICUBIC, expand=False)
            if pose.scale != 1.0:
                layer = layer.resize((round(layer.width * pose.scale),
                                      round(layer.height * pose.scale)), Image.LANCZOS)
            if pose.opacity < 1.0:
                a = layer.getchannel("A").point(lambda v: round(v * pose.opacity))
                layer.putalpha(a)
            img.alpha_composite(layer, (round(x0 - 40 + pose.x), round(y0 - 40 + pose.y)))
        if window is not None and pose is not None:
            # The footage shows through here — the mat is opaque paper everywhere else.
            ImageDraw.Draw(img).rectangle(window, fill=(0, 0, 0, 0))
        last = img.tobytes()
        enc.stdin.write(last)
    enc.stdin.close()
    enc.wait()
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Render placeholder title/chapter cards")
    ap.add_argument("picks")
    ap.add_argument("--title", default="Yeast")
    args = ap.parse_args(argv)
    path = cli.resolve_or_exit(args.picks, expect=(".json",), label="picks file")
    spec = json.loads(path.read_text())
    if not FONT.exists():
        sys.exit(f"! no display font at {FONT} — drop Kalam-Bold.ttf into assets/fonts/")

    clock = SC.StepClock()
    out_dir = C.GRAPHICS / spec.get("project", path.stem)
    display, h1 = C.TYPE_SCALE["display"][0], C.TYPE_SCALE["h1"][0]
    jobs = [("title", args.title, display)] + [
        (f"chapter-{i + 1:02d}", p["chapter"], h1)
        for i, p in enumerate(x for x in spec["picks"] if x.get("chapter"))]
    for key, text, size in jobs:
        out = render(text, size, out_dir / f"{key}_placeholder.mov", clock)
        print(f"  ✓ {C.path_label(out)}  “{text}”  {size}px")
    # Photographs named by a cue (`"picture": "path.jpg"`) — real images, placed on the clock.
    # Not placeholders: nothing about them is waiting on a scan. Their hold is the cue's own
    # `seconds`, since a picture's hold is set by the line it illustrates, not by a word count.
    for p in spec["picks"]:
        for cue in p.get("cues", []):
            if not cue.get("picture"):
                continue
            src = cli.resolve_or_exit(cue["picture"], expect=(".jpg", ".jpeg", ".png"),
                                      label="picture")
            out = render(src.stem, h1, out_dir / f"picture-{src.stem}.mov", clock,
                         picture=src, hold_seconds=float(cue.get("seconds", 6.0)),
                         mat=bool(cue.get("reframe")))
            print(f"  ✓ {C.path_label(out)}  ({src.name}"
                  f"{', mat' if cue.get('reframe') else ''})")
    print("  every one of these is a flat fill under the type — a stand-in for the scanned "
          "surface §6.1 asks for, not the card. Replace when paper-grain.png exists.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
