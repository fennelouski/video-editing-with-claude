"""
Stage 5 — Composite and stitch.

Renders the graphic layer by animating her scanned cutouts on the stop-motion step clock,
then burns captions and stitches the master.

Everything on screen came out of a scanner or a camera. Nothing here draws a shape, generates
a texture, or invents an image — see style_guide.md [S-001].

Per taste_principles:
  §5.1  graphics step on 2s; footage and captions stay at full 24 fps
  §4.3  a real scanned grain layer multiplies over every graphic composition at 8–14%
  §4.4  every cutout gets a warm contact shadow, constant direction, never pure black
  §6.7  captions cut, never slide, and never step

Output: build/graphics/<cue>.mov (alpha)  ·  build/exports/<project>.master.mp4
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import cli
import config as C
import corrections as CR
import stepclock as SC

try:
    import numpy as np
    from PIL import Image, ImageFilter
except ImportError:  # pragma: no cover
    Image = None  # type: ignore


# --------------------------------------------------------------------------------------
# Alpha-correct resampling
# --------------------------------------------------------------------------------------
#
# Every resample here goes through premultiplied alpha, in float.
#
# A matted cutout carries RGB 0 under its transparent region — that is what a PNG round-trip
# leaves behind. Resampling straight RGBA lets the negative lobes of LANCZOS and BICUBIC pull
# those zeros into the feathered edge, so the matte edge picks up a black fringe and the layer
# ends up carrying #000000 pixels. That is §12 check 9 and non-negotiable 5, and it lands on
# exactly the torn edges §1.3 says to preserve. See style_guide [S-011].
#
# Float matters. Pillow's built-in premultiplied mode ("RGBa") stores the premultiplied value
# as uint8, and un-premultiplying that divides a rounded number by a very small alpha: an edge
# pixel at alpha 1/255 comes back as #FFFFFF instead of kraft. Measured, the RGBa round-trip
# is bit-identical to no fix at all. Keeping the premultiplied value in float until the alpha
# has been quantised is what makes the division well-conditioned.


def _premultiplied_bands(sprite: "Image.Image") -> list["Image.Image"]:
    """RGBA -> four 32-bit float bands, with RGB premultiplied by alpha."""
    arr = np.asarray(sprite.convert("RGBA"), dtype=np.float32) / 255.0
    arr[..., :3] *= arr[..., 3:4]
    return [Image.fromarray(arr[..., i], "F") for i in range(4)]


def _unpremultiplied(bands: list["Image.Image"]) -> "Image.Image":
    """Four premultiplied float bands -> straight-alpha RGBA, the form ProRes 4444 wants."""
    out = np.stack([np.asarray(b) for b in bands], axis=-1).astype(np.float32)
    colour, alpha = out[..., :3], np.clip(out[..., 3], 0.0, 1.0)

    # Quantise alpha first, then divide by the quantised value. Dividing by the raw float
    # alpha lets a pixel with alpha ~1e-6 — which quantises to fully transparent anyway —
    # amplify its way past 1.0 and clamp to pure white.
    alpha8 = np.rint(alpha * 255.0).astype(np.uint8)

    # LANCZOS and BICUBIC have negative lobes, so a premultiplied channel can ring below zero
    # at a hard matte edge. Clamping that to 0 while the pixel still has coverage is what
    # produces a #000000 pixel. A pixel whose entire colour rang to zero or below carries no
    # colour contribution, so it carries no coverage either — drop it to fully transparent
    # rather than inventing a black one.
    colour = np.maximum(colour, 0.0)
    alpha8[(colour <= 0.0).all(axis=-1)] = 0
    visible = alpha8 >= 1

    quantised = alpha8[..., None].astype(np.float32) / 255.0
    rgb = np.zeros_like(colour)
    np.divide(colour, quantised, out=rgb, where=visible[..., None])

    rgb8 = np.rint(np.clip(rgb, 0.0, 1.0) * 255.0).astype(np.uint8)

    # Both ends of the range need the same treatment, and for the same reason: the resampler
    # can land a value outside what an 8-bit channel can honestly say, and rounding it to a
    # pure value would put #000000 or #FFFFFF into the graphic layer.
    #
    # A positive colour below half a code value is not black, it is below the channel's
    # precision, so the nearest honest code is 1. A recovered colour above 1.0 is not white,
    # it is ringing — a premultiplied channel is colour x alpha and physically cannot exceed
    # its own alpha — so the nearest honest code is 254.
    #
    # Only those two cases move. A channel that is genuinely 0.0 or genuinely 1.0 is left
    # alone, so artwork that really does contain a pure value still surfaces as a §4.1
    # violation rather than being quietly papered over here.
    on = visible[..., None]
    rgb8[on & (rgb > 0.0) & (rgb8 == 0)] = 1
    rgb8[on & (rgb > 1.0)] = 254

    # RGB under a fully transparent pixel is undefined and never composited; leave it at 0.
    rgb8[~visible] = 0
    return Image.fromarray(np.concatenate([rgb8, alpha8[..., None]], axis=-1), "RGBA")


def resize_rgba(sprite: "Image.Image", size: tuple[int, int],
                filt: int = None) -> "Image.Image":  # type: ignore[assignment]
    filt = Image.LANCZOS if filt is None else filt
    return _unpremultiplied([b.resize(size, filt) for b in _premultiplied_bands(sprite)])


def rotate_rgba(sprite: "Image.Image", angle: float,
                filt: int = None) -> "Image.Image":  # type: ignore[assignment]
    # expand=True so the corners of a rotated cutout never get clipped.
    filt = Image.BICUBIC if filt is None else filt
    return _unpremultiplied(
        [b.rotate(angle, resample=filt, expand=True) for b in _premultiplied_bands(sprite)]
    )


# --------------------------------------------------------------------------------------
# Colour helpers
# --------------------------------------------------------------------------------------

def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def hex_to_ass(h: str, alpha: int = 0) -> str:
    """ASS colours are &HAABBGGRR — reversed, with alpha where 0 is opaque."""
    r, g, b = hex_to_rgb(h)
    return f"&H{alpha:02X}{b:02X}{g:02X}{r:02X}"


# --------------------------------------------------------------------------------------
# Asset loading
# --------------------------------------------------------------------------------------

@dataclass
class Cutout:
    key: str
    variants: list[Path]

    def load(self, index: int) -> "Image.Image":
        img = Image.open(self.variants[index % len(self.variants)]).convert("RGBA")
        return img


def find_variants(ref: str) -> list[Path]:
    kind, key = (ref.split(":", 1) + ["", ""])[:2] if ":" in ref else ("cutout", ref)
    base = {"cutout": C.CUTOUTS, "texture": C.TEXTURES}.get(kind, C.CUTOUTS)
    return sorted(p for p in base.rglob("*") if p.is_file()
                  and p.suffix.lower() in {".png", ".tif", ".tiff", ".webp"}
                  and p.stem.startswith(key))


def load_texture(name: str, size: tuple[int, int]) -> "Image.Image":
    hits = find_variants(f"texture:{name}")
    if not hits:
        raise FileNotFoundError(
            f"texture '{name}' not found in {C.path_label(C.TEXTURES)}/ — "
            f"taste_principles §4.3 forbids substituting a flat fill or generated noise"
        )
    return Image.open(hits[0]).convert("RGB").resize(size, Image.LANCZOS)


# --------------------------------------------------------------------------------------
# Compositing primitives
# --------------------------------------------------------------------------------------

def contact_shadow(sprite: "Image.Image") -> "Image.Image":
    """
    §4.4 — a warm, soft, down-right contact shadow. Never pure black, never a different
    direction from the rest of the channel.
    """
    ox = sum(C.SHADOW["offset_x"]) // 2
    oy = sum(C.SHADOW["offset_y"]) // 2
    blur = sum(C.SHADOW["blur"]) // 2
    opacity = sum(C.SHADOW["opacity"]) / 2
    r, g, b = C.SHADOW["rgb"]

    pad = blur * 3
    canvas = Image.new("RGBA", (sprite.width + pad * 2, sprite.height + pad * 2), (0, 0, 0, 0))

    alpha = sprite.getchannel("A")
    shadow = Image.new("RGBA", sprite.size, (r, g, b, 0))
    shadow.putalpha(alpha.point(lambda v: int(v * opacity)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))

    canvas.alpha_composite(shadow, (pad + ox, pad + oy))
    canvas.alpha_composite(sprite, (pad, pad))
    return canvas


def content_box(spec: dict) -> tuple[int, int, int, int]:
    """The usable rectangle inside the safe margins (§2.1): (x, y, w, h)."""
    w, h = spec["author"]
    x = spec["margin_left"]
    y = spec["margin_top"]
    return x, y, w - x - spec["margin_right"], h - y - spec["margin_bottom"]


def fit_to_slot(sprite: "Image.Image", slot_w: int, slot_h: int, fill: float = 0.86) -> "Image.Image":
    """
    Scale a scan down into its layout slot.

    Source cutouts are ≥2400px on the long edge (§1.2) so the edit can push in on them — which
    means they are almost always larger than the canvas and must be fitted, never composited at
    native size. Only ever scales down; upscaling a scan past 1:1 destroys the fibre detail that
    is the entire reason for shooting it big.
    """
    if sprite.width <= 0 or sprite.height <= 0:
        return sprite
    factor = min(slot_w * fill / sprite.width, slot_h * fill / sprite.height, 1.0)
    if factor >= 0.999:
        return sprite
    return resize_rgba(sprite, (max(1, int(sprite.width * factor)),
                                max(1, int(sprite.height * factor))))


def layout_slots(n: int, spec: dict) -> list[tuple[int, int, int, int]]:
    """
    Distribute n cutouts across the content box on the 8px grid.

    One piece centres. Two or more lay out horizontally with a 64px gap — the spacing ramp's
    'unrelated groups' rung (§2.2), because separate cutouts in a diagram are separate ideas.
    """
    bx, by, bw, bh = content_box(spec)
    if n <= 1:
        return [(bx, by, bw, bh)]
    gap = 64
    slot_w = (bw - gap * (n - 1)) // n
    return [(bx + i * (slot_w + gap), by, slot_w, bh) for i in range(n)]


def apply_transform(sprite: "Image.Image", t: SC.Transform) -> "Image.Image":
    if abs(t.scale - 1.0) > 1e-4:
        w = max(1, int(sprite.width * t.scale))
        h = max(1, int(sprite.height * t.scale))
        sprite = resize_rgba(sprite, (w, h))
    if abs(t.rotation) > 1e-4:
        sprite = rotate_rgba(sprite, t.rotation)
    # Opacity scales alpha only. With straight alpha that is already correct — RGB describes
    # the colour at full strength — so it needs no premultiplied round-trip.
    if t.opacity < 0.999:
        a = sprite.getchannel("A").point(lambda v: int(v * max(0.0, t.opacity)))
        sprite.putalpha(a)
    return sprite


def grain_pass(frame: "Image.Image", grain: "Image.Image", opacity: float) -> "Image.Image":
    """
    §4.3 — the real scanned grain that glues digitally-placed elements into one world.
    Multiply blend at 8–14%. Procedural noise is banned; its frequency signature is regular
    and the eye catches it.

    Done in float. `ImageChops.multiply` and `Image.blend` both truncate rather than round,
    and they truncate twice: a channel at 1 multiplied by the ~0.98 the grain actually applies
    came back as 0, which put #000000 into the graphic layer at the far end of a pipeline that
    had carefully avoided it. Multiply can only ever darken, so a visible pixel must never
    reach zero here. See style_guide [S-011].
    """
    base = np.asarray(frame.convert("RGB"), dtype=np.float32) / 255.0
    g = np.asarray(grain.convert("RGB"), dtype=np.float32) / 255.0

    # blend(base, base*g, opacity) collapses to a single per-pixel factor.
    out = base * (1.0 - opacity + opacity * g)

    out8 = np.rint(np.clip(out, 0.0, 1.0) * 255.0).astype(np.uint8)
    out8[(out > 0.0) & (out8 == 0)] = 1        # underflow, not black — see _unpremultiplied()

    img = Image.fromarray(out8, "RGB")
    if frame.mode == "RGBA":
        img = img.convert("RGBA")
        img.putalpha(frame.getchannel("A"))
    return img


# --------------------------------------------------------------------------------------
# Cue rendering
# --------------------------------------------------------------------------------------

def render_cue(cue: dict, aspect: str, out_dir: Path, clock: SC.StepClock,
               grain: "Image.Image | None") -> Path | None:
    """Render one cue to a PNG sequence, stepping on 2s and holding odd frames."""
    spec = C.ASPECTS[aspect]
    size = spec["author"]

    refs = cue.get("assets") or []
    cutouts: list[Cutout] = []
    for ref in refs:
        variants = find_variants(ref)
        if not variants:
            print(f"    ! {cue['id']}: asset '{ref}' missing — cue skipped (Stage 4 has the build sheet)")
            return None
        key = ref.split(":", 1)[-1]
        cutouts.append(Cutout(key, variants))

    if not cutouts:
        print(f"    - {cue['id']}: no assets, nothing to composite")
        return None

    # Must come from the same helper pose_at() uses, or the sequence length and the animation
    # disagree by a frame whenever the hold is off the step grid ([S-010]).
    hold_frames = clock.hold_frames(cue.get("hold") or C.HOLD_MIN_SECONDS)
    total = C.PLACE_FRAMES[1] + hold_frames + C.REMOVE_FRAMES[1] + SC.stagger_offset(len(cutouts) - 1)

    slots = layout_slots(len(cutouts), spec)

    seq_dir = out_dir / cue["id"]
    seq_dir.mkdir(parents=True, exist_ok=True)

    cached: dict[int, Image.Image] = {}
    for frame in range(total + 1):
        step = clock.step_frame(frame)
        if step in cached:
            composite = cached[step]
        else:
            composite = Image.new("RGBA", size, (0, 0, 0, 0))
            for i, cut in enumerate(cutouts):
                eid = f"{cue['id']}:{cut.key}"
                pose = SC.pose_at(
                    eid, frame,
                    start_frame=SC.stagger_offset(i),
                    hold_frames=hold_frames,
                    clock=clock,
                    neighbor_index=i,
                )
                if pose is None or pose.opacity <= 0.001:
                    continue
                vi = SC.variant_for(eid, frame, len(cut.variants), clock)
                sx, sy, sw, sh = slots[i]
                sprite = fit_to_slot(cut.load(vi), sw, sh)
                sprite = contact_shadow(sprite)
                sprite = apply_transform(sprite, pose)

                # Centre in the slot, then apply the pose offset.
                px = int(sx + sw / 2 - sprite.width / 2 + pose.x)
                py = int(sy + sh / 2 - sprite.height / 2 + pose.y)
                composite.alpha_composite(sprite, (px, py))

            if grain is not None:
                lo, hi = C.GRAIN_OPACITY
                composite = grain_pass(composite, grain, (lo + hi) / 2)
            cached[step] = composite

        composite.save(seq_dir / f"{frame:05d}.png")

    print(f"    ✓ {cue['id']}: {total + 1} frames ({len(cached)} unique steps) → {C.path_label(seq_dir)}")
    return seq_dir


def encode_sequence(seq_dir: Path, out: Path) -> Path:
    """PNG sequence → ProRes 4444 with alpha. Never a lossy intermediate (§11)."""
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-y",
        "-framerate", C.FPS_STR,
        "-i", str(seq_dir / "%05d.png"),
        "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le",
        str(out),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"encode failed for {seq_dir.name}:\n{proc.stderr[-800:]}")
    return out


# --------------------------------------------------------------------------------------
# Captions  (§6.7)
# --------------------------------------------------------------------------------------

def build_ass(words: list[dict], aspect: str, out: Path) -> Path:
    """
    Burned captions as ASS. Cut, never slide, never step. Word-level highlight uses a rust
    *background fill*, not coloured text — coloured text on video fails contrast.
    """
    spec = C.ASPECTS[aspect]
    w, h = spec["author"]
    size = C.TYPE_SCALE["caption"][0 if aspect == "16:9" else 1]
    margin_v = h - spec["caption_baseline"]

    header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {w}
PlayResY: {h}
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Base,{C.FONT_TEXT},{size},{hex_to_ass(C.PALETTE['bone'])},{hex_to_ass(C.PALETTE['bone'])},{hex_to_ass(C.PALETTE['ink'])},{hex_to_ass(C.PALETTE['ink'], int(255*(1-C.CAPTION_PLATE_ALPHA)))},1,0,0,0,100,100,0.5,0,3,0,0,2,{spec['margin_left']},{spec['margin_right']},{margin_v},1
Style: Hilite,{C.FONT_TEXT},{size},{hex_to_ass(C.PALETTE['bone'])},{hex_to_ass(C.PALETTE['bone'])},{hex_to_ass(C.PALETTE['rust'])},{hex_to_ass(C.PALETTE['rust'])},1,0,0,0,100,100,0.5,0,3,0,0,2,{spec['margin_left']},{spec['margin_right']},{margin_v},1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

    def ts(t: float) -> str:
        cs = int(round(t * 100))
        h_, cs = divmod(cs, 360000)
        m_, cs = divmod(cs, 6000)
        s_, cs = divmod(cs, 100)
        return f"{h_:d}:{m_:02d}:{s_:02d}.{cs:02d}"

    # Group into caption cards of <= 2 lines * 36 chars, breaking on gaps.
    lines: list[list[dict]] = []
    cur: list[dict] = []
    budget = C.CAPTION_MAX_CHARS_PER_LINE * C.CAPTION_MAX_LINES
    for i, wd in enumerate(words):
        cur.append(wd)
        length = sum(len(x["word"]) + 1 for x in cur)
        gap = (words[i + 1]["start"] - wd["end"]) if i + 1 < len(words) else 99
        if length >= budget or gap > 0.45:
            lines.append(cur)
            cur = []
    if cur:
        lines.append(cur)

    events = []
    for group in lines:
        start, end = group[0]["start"], group[-1]["end"]
        # Karaoke-style highlight: \k durations in centiseconds, rendered as a fill sweep.
        text = "".join(
            "{\\k%d}%s " % (max(1, int((x["end"] - x["start"]) * 100)), x["word"])
            for x in group
        ).strip()
        events.append(f"Dialogue: 0,{ts(start)},{ts(end + 0.08)},Base,,0,0,0,,{text}")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(header + "\n".join(events) + "\n", encoding="utf-8")
    return out


# --------------------------------------------------------------------------------------
# Stitch
# --------------------------------------------------------------------------------------

def assemble(project: str, aspect: str, edl_path: Path, overlays: list[tuple[Path, float, dict]],
             out: Path) -> Path:
    """
    Build the Final Cut package: the cut timeline, her graphic layers attached as connected
    clips at the right timecodes, a marker on every cue, and chapter markers.

    Nothing is flattened and nothing is burned in. She opens this and keeps editing —
    every graphic can be nudged, retimed, restyled, or deleted.
    """
    import fcpxml as FX

    edl = json.loads(edl_path.read_text())
    src = C.ROOT / edl["source"]
    if not src.exists():
        raise FileNotFoundError(f"source media missing: {edl['source']}")

    # Cue times are in SOURCE time; the timeline is the cut. Everything must be remapped.
    tmap = FX.TimelineMap(edl["keeps"])

    clips: list[FX.Clip] = []
    timeline = 0.0
    for i, k in enumerate(edl["keeps"]):
        d = k["end"] - k["start"]
        clips.append(FX.Clip(
            asset_path=src,
            offset=C.snap_seconds(timeline),
            start=C.snap_seconds(k["start"]),
            duration=C.snap_seconds(d),
            name=f"{src.stem} {i+1:02d}",
        ))
        timeline += d

    connected: list[FX.Connected] = []
    chapters: list[tuple[float, str]] = []
    snapped: list[str] = []

    plan = json.loads((C.PLAN_DIR / f"{project}.plan.json").read_text())

    # Chapters come from the plan, not from the rendered layers — a chapter marker is worth
    # having even when the chapter card graphic hasn't been built yet.
    for cue in plan["cues"]:
        if cue["kind"] != "CHAPTER" or cue.get("start") is None:
            continue
        at, was_snapped = tmap.nearest(cue["start"])
        chapters.append((C.snap_seconds(at), cue.get("text") or "Chapter"))
        if was_snapped:
            snapped.append(f"{cue['id']} (chapter)")

    cramped: list[str] = []
    for mov, src_at, cue in overlays:
        at, was_snapped = tmap.nearest(src_at)
        if was_snapped:
            snapped.append(cue["id"])

        wanted = cue.get("hold") or C.HOLD_MIN_SECONDS
        room = tmap.duration - at
        hold = min(wanted, room)
        if hold < wanted - 1 / C.FPS:
            cramped.append(f"{cue['id']} ({hold:.1f}s of {wanted:.1f}s)")
        if hold < 4 / C.FPS:
            print(f"    ! {cue['id']} lands {at:.1f}s into a {tmap.duration:.1f}s timeline "
                  f"with no room to hold — skipped")
            continue

        connected.append(FX.Connected(
            asset_path=mov,
            offset=C.snap_seconds(at),
            duration=C.snap_seconds(hold),
            name=f"{cue['id']} {cue.get('text','')}".strip()[:48],
            lane=C.LANE_GRAPHICS,
            role=C.ROLE_GRAPHICS_SUB,
        ))

    # Markers for cues with no rendered layer — b-roll, macro inserts, camera changes.
    # These are the shots she still has to place by hand, so they need to be visible.
    marker_count = 0
    for cue in plan["cues"]:
        if cue.get("start") is None or cue["kind"] not in {"BROLL", "MACRO", "CAM", "VO"}:
            continue
        at, was_snapped = tmap.nearest(cue["start"])
        at = C.snap_seconds(at)
        label = f"{cue['kind']}: {cue.get('text') or cue.get('anchor', '')[:40]}"
        for c in clips:
            if c.offset <= at < c.offset + c.duration:
                c.markers.append((at, label, True))
                marker_count += 1
                break

    print(f"  {len(connected)} connected clip(s), {marker_count} marker(s), "
          f"{len(chapters)} chapter(s) — remapped onto the {tmap.duration:.1f}s cut timeline")
    if snapped:
        print(f"  ! {len(snapped)} cue(s) anchored to removed footage, snapped to the nearest "
              f"surviving frame: {', '.join(snapped)}")
    if cramped:
        print(f"  ! {len(cramped)} cue(s) truncated by the end of the timeline: "
              f"{', '.join(cramped)}")
        print("    They land too close to the outro to hold for the §5.4 minimum. "
              "Either give the outro more room or move the cue earlier.")

    builder = FX.FCPXMLBuilder(project=project, aspect=aspect)
    tree = builder.build(clips, connected, chapters)
    builder.write(tree, out)

    problems = FX.validate(out)
    if problems:
        print(f"  ! FCPXML validation: {len(problems)} issue(s)")
        for p in problems[:6]:
            print(f"      {p}")
    else:
        print("  ✓ FCPXML validates")
    return out


def main(argv: list[str] | None = None) -> int:
    cli.preflight(('numpy', 'PIL'))
    ap = argparse.ArgumentParser(description="Stage 5 — composite graphics, burn captions, stitch")
    ap.add_argument("plan", nargs="?")
    ap.add_argument("--aspect", default=C.DEFAULT_ASPECT, choices=list(C.ASPECTS))
    ap.add_argument("--graphics-only", action="store_true",
                    help="render the layers but don't build the FCPXML")
    ap.add_argument("--no-captions", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    # An ACTIVE correction still carrying placeholder text is a rule that
    # constrains nothing while looking like it does — style_guide [S-016]. Checked
    # before any work, so it stops the run at the top rather than after a render.
    CR.gate()

    if Image is None:
        print("! Pillow is required for Stage 5:  pip install pillow", file=sys.stderr)
        return 2

    plan_path = cli.resolve_or_exit(args.plan, expect=(".json",), label="plan") \
        if args.plan else next(iter(sorted(C.PLAN_DIR.glob("*.plan.json"))), None)
    if not plan_path or not plan_path.exists():
        print("! no plan found — run stage 3 first")
        return 1
    plan = json.loads(plan_path.read_text())
    project = plan.get("project", "video001")

    # Refuse to render around missing assets (§S-001).
    assets_path = C.PLAN_DIR / f"{project}.assets.json"
    if assets_path.exists():
        adata = json.loads(assets_path.read_text())
        if adata.get("missing"):
            print(f"! {adata['missing']} asset(s) still missing.")
            print(f"  The pipeline does not generate them — see {project}.build-sheet.md")
            return 3

    clock = SC.StepClock()
    spec = C.ASPECTS[args.aspect]
    print(f"Stage 5 — {args.aspect} @ {C.FPS:.3f}p ({C.FPS_STR}), "
          f"graphics stepping on {C.GRAPHIC_STEP}s")

    if args.dry_run:
        for cue in plan["cues"]:
            if cue.get("start") is not None:
                print(f"  would render {cue['id']} at {cue['start']:.2f}s, hold {cue.get('hold')}s")
        return 0

    try:
        grain = load_texture("paper-grain", spec["author"])
    except FileNotFoundError as exc:
        print(f"! {exc}")
        print("  scan a sheet of blank paper flat and save it to assets/textures/paper-grain.png")
        return 3

    overlays: list[tuple[Path, float, dict]] = []
    for cue in plan["cues"]:
        if cue.get("start") is None or cue["kind"] in {"NOTE", "VO", "CAM", "BROLL", "MACRO"}:
            continue
        seq = render_cue(cue, args.aspect, C.FRAMES, clock, grain)
        if seq:
            mov = encode_sequence(seq, C.GRAPHICS / f"{project}_{cue['id']}.mov")
            overlays.append((mov, cue["start"], cue))

    print(f"  {len(overlays)} graphic layer(s) rendered (ProRes 4444, alpha)")
    if args.graphics_only:
        return 0

    edls = sorted(C.ROUGHCUT.glob("*.edl.json"))
    if not edls:
        print("! no rough cut EDL found — run stage 2 first")
        return 1

    if not args.no_captions and C.CAPTION_MODE in ("itt", "both"):
        import fcpxml as FX
        tpath = next(iter(sorted(C.TRANSCRIPTS.glob("*.words.json"))), None)
        if tpath:
            # Captions live in the same cut timeline as everything else — remap, and drop the
            # words that were edited out.
            edl_data = json.loads(edls[0].read_text())
            itt, dropped = FX.build_itt(
                json.loads(tpath.read_text())["words"],
                C.EXPORTS / f"{project}.captions.itt",
                tmap=FX.TimelineMap(edl_data["keeps"]),
            )
            print(f"  captions → {C.path_label(itt)}  "
                  f"({dropped} word(s) dropped with the cut footage)")

    out = C.EXPORTS / f"{project}.fcpxml"
    try:
        assemble(project, args.aspect, edls[0], overlays, out)
    except Exception as exc:  # noqa: BLE001
        print(f"! {exc}", file=sys.stderr)
        return 1

    print(f"\nStage 5 complete → {C.path_label(out)}")
    print("  In Final Cut: File ▸ Import ▸ XML…")
    print("  Then import the .itt as captions, and grade with assets/luts/.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
