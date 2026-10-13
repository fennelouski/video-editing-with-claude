"""Create clearly labeled local test inputs; never read production footage or assets.

./run tools/synthetic_acceptance.py /path/to/new/Synthetic-Acceptance-folder
Then opt into the native workflow test using CLAUTO_SYNTHETIC_ACCEPTANCE_ROOT.
Procedural images and the system font are test fixtures, never production assets.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import cli
from PIL import Image, ImageDraw

NARRATION = ("This is a synthetic editing test. We place a blue bowl on the table. "
             "Then we add flour and water. The final clip stays local.")
SCRIPT = NARRATION.replace("editing test.", 'editing test. [[GFX: key_term | text="Synthetic fixture" | asset=cutout:fixture]]')


def main(argv=None):
    cli.preflight(("PIL",))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("destination", type=Path)
    args = ap.parse_args(argv)
    root = args.destination.resolve()
    if root.exists():
        raise SystemExit("Use a new folder; synthetic acceptance never replaces existing files.")
    if str(root).startswith("/Volumes/"):
        volume = Path("/Volumes") / root.parts[2]
        if not volume.is_mount():
            raise SystemExit("The requested volume is not mounted; no folders created.")
    root.mkdir(parents=True)
    (root / "SYNTHETIC_ACCEPTANCE.txt").write_text("Synthetic test inputs only. No production footage or artwork.\n")
    media = root / "media"; media.mkdir()
    audio = media / "narration.aiff"
    subprocess.run(["/usr/bin/say", "-v", "Samantha", "-r", "145", "-o", str(audio), NARRATION], check=True)
    video = media / "Synthetic narration.mov"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=1280x720:r=24000/1001",
                    "-i", str(audio), "-c:v", "libx264", "-preset", "veryfast", "-crf", "28", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-shortest", str(video)], check=True)
    assets = root / "fixture-library"
    for key in ("textures", "cutouts", "fonts"):
        (assets / key).mkdir(parents=True)
    for name, color in (("paper-grain", (242, 239, 231)), ("kraft", (190, 160, 125))):
        Image.new("RGB", (4000, 4000), color).save(assets / "textures" / f"{name}.png")
    for i in range(4):
        im = Image.new("RGBA", (2400, 2400), (0, 0, 0, 0))
        ImageDraw.Draw(im).ellipse((400+i*3, 400, 2000+i*3, 2000), fill=(70, 100, 150, 255))
        im.save(assets / "cutouts" / f"fixture_v01_{chr(97+i)}.png")
    shutil.copyfile("/System/Library/Fonts/Supplemental/Arial.ttf", assets / "fonts" / "TestOnly-Arial.ttf")
    (root / "fixture.json").write_text(json.dumps({"synthetic": True, "narration": NARRATION,
        "approved_script": SCRIPT, "source": str(video), "asset_library": str(assets)}, indent=2))
    print(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
