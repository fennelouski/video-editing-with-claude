"""
build_video.py — the vertical instruction video, rendered on the GPU.

    .venv/bin/python handoff/build_video.py

Real OpenGL, not slides: a standalone GL context renders every frame through fragment shaders
at 1080x1920, and the frames stream straight into ffmpeg. Two programs do the work —

  **Background.** Domain-warped fractal noise through the Sage & Oat palette, with grain and a
  vignette. It drifts continuously and re-seeds per scene, so no two beats look the same and
  nothing is ever a flat fill.

  **Sprites.** Text and glyph strips are rasterised once by PIL, uploaded as textures, and
  composited by the GPU with per-line transforms — so type slides, scales and fades per frame
  instead of cutting between static cards.

Editing is cut to the voice. Each line is spoken, measured, and its scene held for exactly that
long, so the words and the picture cannot drift; lines stagger in on the beat, and every scene
change fires an accent sweep across the frame. Change the script in `content.py` and the whole
thing retimes itself.

One deliberate exception to non-negotiable 1, stated rather than assumed: these graphics are
generated. That rule governs what reaches the channel — an audience watching a video. This is
an internal note to one person that will never be published, the same distinction
`tests/fixtures.py` makes.
"""

from __future__ import annotations

import argparse
import importlib.util
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import moderngl
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scripts"))
sys.path.insert(0, str(HERE))

import config as C
from music import (  # noqa: E402  the level is meaningless without its band
    MUSIC_BAND, MUSIC_HIGHPASS_HZ, MUSIC_UNDER_DB, bed_gain)          # noqa: E402
import content as CONTENT   # noqa: E402

W, H = 1080, 1920
FPS = C.FPS
# Kokoro-82M, Apache-2.0, running locally on the GPU. macOS `say` is intelligible and sounds
# like a screen reader, which is a poor thing to ask someone to sit through for ninety seconds.
# Swap VOICE for any of the packs listed by `--voices`; the video retimes itself around it.
VOICE = "af_heart"
SPEED = 1.06               # Kokoro reads slower than `say` did; this lands the whole thing
                           # inside the 90s ceiling without cutting a line
FALLBACK_VOICE, FALLBACK_RATE = "Samantha", 170

# Music bed. taste_principles §8 wants music ducked well under the voice and cut entirely
# under the most important line; here it just sits under the whole thing, since the whole
# thing is ninety seconds of instruction. Absent is fine — the build says so and carries on.
MUSIC = HERE.parent / "assets" / "music" / "handoff-bed.wav"
# How far under the speaking voice the bed sits — measured in the band a phone or laptop
# speaker actually reproduces, not across the full spectrum.
#
# This track is 85% sub-200 Hz. Matching full-band RMS therefore set the level from bass the
# playback device throws away, leaving the audible part 7 dB quieter than the number claimed
# and, in practice, inaudible. Measuring inside 200 Hz - 4 kHz sets the balance where the
# listening happens.

# Everything below this is felt at best and discarded at worst, but it still eats the headroom
# loudnorm has to give back — so removing it lets the audible part of the bed sit louder for
# the same measured loudness.
MUSIC_FADE_IN = 2.0
MUSIC_FADE_OUT = 5.0
TARGET_LUFS = -16.0         # config.TARGET_LUFS — the same figure the channel masters to
PAD = 0.34                  # beat of held frame after each spoken line
MAX_SECONDS = 90

FONT_PATH = "/System/Library/Fonts/Avenir Next.ttc"
BOLD, DEMI, MEDIUM, REGULAR = 0, 2, 5, 7
# The palette has no glyph coverage for arrows, fractions or Greek; this one does.
SYMBOL_PATH = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"

PALETTE = {k: tuple(int(v.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4))
           for k, v in C.PALETTE.items()}


def rgb(name: str) -> str:
    return C.PALETTE[name]


# --------------------------------------------------------------------------------------
# Shaders
# --------------------------------------------------------------------------------------

QUAD_VS = """
#version 410
in vec2 in_pos;
in vec2 in_uv;
out vec2 uv;
uniform vec4 rect;      // x, y, w, h in clip space
void main() {
    uv = in_uv;
    gl_Position = vec4(rect.xy + in_pos * rect.zw, 0.0, 1.0);
}
"""

BACKGROUND_FS = """
#version 410
in vec2 uv;
out vec4 frag;

uniform float time;
uniform float seed;
uniform float sweep;        // 0..1 accent wipe on a scene change
uniform vec3  c_low;
uniform vec3  c_mid;
uniform vec3  c_high;
uniform vec3  c_accent;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);                 // smoothstep, so the field has no facets
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p) {
    float sum = 0.0, amp = 0.5;
    for (int i = 0; i < 5; i++) {
        sum += amp * noise(p);
        p *= 2.02;                                // non-integer, so octaves never line up
        amp *= 0.5;
    }
    return sum;
}

void main() {
    vec2 p = uv * vec2(1.0, 1.78);

    // Domain warp: noise sampling noise. This is what stops it reading as a gradient and
    // makes it move like something wet on paper rather than a filter.
    vec2 q = vec2(fbm(p * 1.6 + seed), fbm(p * 1.6 + seed + 5.2));
    vec2 r = vec2(fbm(p * 2.1 + 4.0 * q + time * 0.045),
                  fbm(p * 2.1 + 4.0 * q + time * 0.037 + 3.1));
    float f = fbm(p * 1.4 + 3.0 * r);

    // Tight smoothsteps: a wide ramp averages the palette into one flat wash, which is what
    // made the first pass look like nothing at all.
    vec3 col = mix(c_low, c_mid, smoothstep(0.34, 0.54, f));
    col = mix(col, c_high, smoothstep(0.52, 0.74, f));
    col = mix(col, c_accent, smoothstep(0.72, 0.95, f) * 0.55);

    // A soft off-centre light, so the frame has somewhere to look.
    float glow = 1.0 - smoothstep(0.0, 0.85, distance(uv, vec2(0.30, 0.72)));
    col += glow * 0.10;

    // Accent sweep on the cut: a soft diagonal band that crosses once and leaves.
    float band = 1.0 - smoothstep(0.0, 0.34, abs((uv.x * 0.35 + uv.y) - sweep * 1.5));
    col = mix(col, c_accent, band * 0.55 * step(0.001, sweep) * (1.0 - sweep));

    // Warm vignette, off-centre — §4.3 bans a perfectly centred one as a filter tell.
    float v = distance(uv, vec2(0.46, 0.52));
    col *= 1.0 - smoothstep(0.42, 1.05, v) * 0.30;

    // Grain, so no area is ever a flat fill.
    col += (hash(uv * 900.0 + time) - 0.5) * 0.022;

    frag = vec4(clamp(col, 0.0, 1.0), 1.0);
}
"""

SPRITE_FS = """
#version 410
in vec2 uv;
out vec4 frag;
uniform sampler2D tex;
uniform float alpha;
void main() {
    vec4 t = texture(tex, uv);
    frag = vec4(t.rgb, t.a * alpha);
}
"""


# --------------------------------------------------------------------------------------
# Type rasterising
# --------------------------------------------------------------------------------------

def font(size: int, index: int = REGULAR) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_PATH, size, index=index)


def symbol_font(size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(SYMBOL_PATH, size)
    except OSError:
        return font(size, DEMI)


_CMAP: dict[tuple[str, int], set[int]] = {}


def cmap_of(path: str, index: int = 0) -> set[int]:
    key = (path, index)
    if key not in _CMAP:
        from fontTools.ttLib import TTCollection, TTFont
        try:
            face = (TTCollection(path).fonts[index] if path.endswith(".ttc")
                    else TTFont(path, fontNumber=index))
            _CMAP[key] = set(face.getBestCmap() or {})
        except Exception:
            _CMAP[key] = set()
    return _CMAP[key]


def covered(text: str, path: str = FONT_PATH, index: int = BOLD) -> bool:
    """
    Does this face actually have every character?

    Asked of the font's character map, not of a rendered bitmap. The obvious check — render
    the glyph and see whether anything came out — always passes, because a missing glyph
    renders as .notdef, a box, which has a perfectly good non-zero size. That is how a tofu
    box reached the ⇌ scene while the code believed the font covered it.
    """
    codes = cmap_of(path, index)
    return bool(codes) and all(ord(ch) in codes for ch in text if ch != " ")


def glyph_sprite(ch: str, fnt: ImageFont.FreeTypeFont, colour: str) -> Image.Image:
    """
    One character on a shared baseline.

    Sizing each sprite to its own ink box makes a row of letters bounce — the descender of a
    `p` and the x-height of an `e` end up vertically centred against each other. Using the
    face's own ascent and descent gives every glyph the same box and the same baseline.
    """
    ascent, descent = fnt.getmetrics()
    width = max(1, int(fnt.getlength(ch)))
    img = Image.new("RGBA", (width + 20, ascent + descent), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((10, ascent), ch, font=fnt, fill=colour, anchor="ls")
    return img


def text_sprite(text: str, fnt: ImageFont.FreeTypeFont, colour: str,
                pad: int = 24) -> Image.Image:
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    box = probe.textbbox((0, 0), text, font=fnt)
    img = Image.new("RGBA", (box[2] - box[0] + pad * 2, box[3] - box[1] + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((pad - box[0], pad - box[1]), text, font=fnt, fill=colour)
    return img


# --------------------------------------------------------------------------------------
# Scene timing
# --------------------------------------------------------------------------------------

@dataclass
class Timed:
    scene: CONTENT.Scene
    audio: Path
    duration: float
    start: float


def duration_of(path: Path) -> float:
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                            "-of", "csv=p=0", str(path)], capture_output=True, text=True, check=True)
    return float(probe.stdout.strip())


_PIPE = None


def voice_pipeline():
    """Kokoro, loaded once. Returns None if it isn't installed, so the build still runs."""
    global _PIPE
    if _PIPE is None:
        try:
            import warnings
            warnings.filterwarnings("ignore")
            from kokoro import KPipeline
            _PIPE = KPipeline(lang_code=VOICE[0], repo_id="hexgrad/Kokoro-82M")
        except Exception as exc:
            print(f"  ! Kokoro unavailable ({exc.__class__.__name__}), falling back to `say`")
            _PIPE = False
    return _PIPE or None


def narrate(text: str, out: Path) -> float:
    """
    Speak one line and pad it with its own beat of silence.

    The pad belongs *inside* each segment, not once at the end of the concatenation. Padding
    only the tail leaves the audio one beat long while the picture is thirteen beats long, so
    the two drift apart by the whole of that difference and ffmpeg truncates on the shorter.
    """
    pipe = voice_pipeline()
    if pipe is not None:
        import numpy as _np
        import soundfile as sf
        chunks = [a for _, _, a in pipe(text, voice=VOICE, speed=SPEED)]
        audio = _np.concatenate(chunks) if chunks else _np.zeros(1, dtype="f4")
        pad = _np.zeros(int(24000 * PAD), dtype=audio.dtype)
        sf.write(str(out), _np.concatenate([audio, pad]), 24000)
        return duration_of(out)

    raw = out.with_suffix(".raw.aiff")
    subprocess.run(["say", "-v", FALLBACK_VOICE, "-r", str(FALLBACK_RATE),
                    "-o", str(raw), text], check=True)
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(raw),
                    "-af", f"apad=pad_dur={PAD}", "-c:a", "pcm_s16le", "-ar", "48000",
                    str(out)], check=True)
    raw.unlink(missing_ok=True)
    return duration_of(out)


def ease_out(t: float) -> float:
    return 1.0 - (1.0 - min(max(t, 0.0), 1.0)) ** 3


# --------------------------------------------------------------------------------------
# Render
# --------------------------------------------------------------------------------------

class Renderer:
    def __init__(self):
        self.ctx = moderngl.create_standalone_context()
        self.ctx.enable(moderngl.BLEND)
        self.ctx.blend_func = moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA

        self.fbo = self.ctx.simple_framebuffer((W, H))
        self.fbo.use()

        quad = np.array([0, 0, 0, 1,  1, 0, 1, 1,  0, 1, 0, 0,
                         0, 1, 0, 0,  1, 0, 1, 1,  1, 1, 1, 0], dtype="f4")
        self.vbo = self.ctx.buffer(quad.tobytes())

        self.bg = self.ctx.program(vertex_shader=QUAD_VS, fragment_shader=BACKGROUND_FS)
        self.sprite = self.ctx.program(vertex_shader=QUAD_VS, fragment_shader=SPRITE_FS)
        self.bg_vao = self.ctx.vertex_array(self.bg, [(self.vbo, "2f 2f", "in_pos", "in_uv")])
        self.sp_vao = self.ctx.vertex_array(self.sprite, [(self.vbo, "2f 2f", "in_pos", "in_uv")])
        self._textures: dict[int, moderngl.Texture] = {}

    def texture(self, img: Image.Image) -> moderngl.Texture:
        key = id(img)
        if key not in self._textures:
            tex = self.ctx.texture(img.size, 4, img.tobytes())
            tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
            self._textures[key] = tex
        return self._textures[key]

    # Each section gets its own colour world, so a cut between them reads as a change of
    # subject rather than as the same background with different words on it.
    RAMPS = {
        "sage": ("oat", "kraft", "sage"),
        "rust": ("bone", "oat", "kraft"),
        "moss": ("oat", "sage", "moss"),
    }

    def draw_background(self, time: float, seed: float, sweep: float, accent: str) -> None:
        names = self.RAMPS.get(accent, self.RAMPS["rust"])
        low, mid, high = (PALETTE[n] for n in names)
        self.bg["time"].value = time
        self.bg["seed"].value = seed
        self.bg["sweep"].value = sweep
        self.bg["c_low"].value = low
        self.bg["c_mid"].value = mid
        self.bg["c_high"].value = high
        self.bg["c_accent"].value = PALETTE[accent]
        self.bg["rect"].value = (-1.0, -1.0, 2.0, 2.0)
        self.bg_vao.render()

    def draw_sprite(self, img: Image.Image, x: int, y: int, alpha: float,
                    scale: float = 1.0) -> None:
        """x, y are top-left in pixels; GL clip space is built from them."""
        if alpha <= 0.003:
            return
        w, h = img.size[0] * scale, img.size[1] * scale
        cx = (x + (img.size[0] * scale - img.size[0]) * -0.5) / W * 2 - 1
        cy = 1 - (y + h) / H * 2
        self.sprite["alpha"].value = alpha
        self.sprite["rect"].value = (cx, cy, w / W * 2, h / H * 2)
        self.texture(img).use(0)
        self.sprite["tex"].value = 0
        self.sp_vao.render()

    def read(self) -> bytes:
        """
        Flip on the way out. OpenGL's framebuffer origin is bottom-left and every consumer of
        these bytes — ffmpeg, PIL, the eye — assumes top-left, so without this the whole frame
        arrives mirrored and the layout reads bottom-up.
        """
        buf = np.frombuffer(self.fbo.read(components=3), dtype=np.uint8)
        return np.flipud(buf.reshape(H, W, 3)).tobytes()


def scrim(height: int) -> Image.Image:
    """
    A soft wash behind the text column.

    The background is deliberately busy and legibility is not negotiable — §0 puts the
    imperfection in the artwork and never in the legibility. Fading it out at both ends keeps
    it from reading as a box.
    """
    r, g, b = (int(C.PALETTE["bone"].lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    column = np.zeros((height, 1, 4), dtype=np.uint8)
    t = np.linspace(0.0, 1.0, height)
    fade = np.clip(np.minimum(t, 1.0 - t) * 5.0, 0.0, 1.0)
    column[:, 0, 0], column[:, 0, 1], column[:, 0, 2] = r, g, b
    column[:, 0, 3] = (fade * 150).astype(np.uint8)
    return Image.fromarray(np.repeat(column, W, axis=1), "RGBA")


def build_sprites(scene: CONTENT.Scene) -> dict:
    """Rasterise everything this scene needs, once."""
    accent = rgb(scene.accent)
    out: dict = {"kicker": None, "head": [], "lines": [], "glyphs": []}

    if scene.kicker:
        out["kicker"] = text_sprite(scene.kicker.upper(), font(38, DEMI), accent)

    # Fit to the column rather than trusting one size to suit every headline: the longest
    # line here is three times the shortest, and a fixed size runs one of them off the frame.
    column = W - 96 * 2
    for line in scene.headline.split("\n"):
        size = 112
        use_symbol = not covered(line)
        while size > 56:
            fnt = symbol_font(int(size * 1.15)) if use_symbol else font(size, BOLD)
            if text_sprite(line, fnt, rgb("ink")).size[0] - 48 <= column:
                break
            size -= 6
        out["head"].append(text_sprite(line, fnt, rgb("ink")))

    body = font(52, MEDIUM)
    for line in scene.lines:
        out["lines"].append(text_sprite(line, body, rgb("walnut")))

    if scene.glyphs:
        big = symbol_font(84)
        for ch in scene.glyphs:
            if ch == " ":
                out["glyphs"].append(None)
            else:
                out["glyphs"].append(glyph_sprite(ch, big, rgb("moss")))
    return out


def render_scene(r: Renderer, timed: Timed, sprites: dict, local: float, absolute: float,
                 index: int) -> None:
    scene = timed.scene
    sweep = max(0.0, 1.0 - local / 0.55) if local < 0.55 else 0.0
    r.ctx.clear(*PALETTE["bone"])
    r.draw_background(absolute, seed=index * 3.7, sweep=1.0 - sweep if sweep else 0.0,
                      accent=scene.accent)

    # Measure first, then centre. Laying out from a fixed top leaves every short scene
    # bottom-heavy and every long one crowded.
    rows = 1 + sum(1 for g in sprites["glyphs"] if g) // 9
    block = ((96 if sprites["kicker"] else 0)
             + 128 * len(sprites["head"])
             + ((150 + 118 * rows) if sprites["glyphs"] else 0)
             + 82 * len(sprites["lines"]))
    y = max(240, int(H * 0.46 - block * 0.5))
    r.draw_sprite(SCRIM, 0, y - 130, 0.92 * ease_out(local / 0.5))
    if sprites["kicker"]:
        a = ease_out(local / 0.35)
        r.draw_sprite(sprites["kicker"], 96, int(y - 18 * (1 - a)), a)
        y += 96

    # Headline lines rise in, staggered — the beat that makes a cut feel edited rather than
    # merely changed.
    for i, sp in enumerate(sprites["head"]):
        t = ease_out((local - 0.10 - i * 0.09) / 0.42)
        r.draw_sprite(sp, 96 - 24, int(y - 40 * (1 - t)) - 30, t, scale=0.96 + 0.04 * t)
        y += 128

    y += 40
    if sprites["glyphs"]:
        gx, gy = 96, y
        for i, sp in enumerate(sprites["glyphs"]):
            if sp is None:                      # a space: also the only legal wrap point, so
                if gx > W * 0.55:               # "2:00" can never break across two lines
                    gx, gy = 96, gy + 118
                else:
                    gx += 42
                continue
            if gx + sp.size[0] > W - 96:
                gx, gy = 96, gy + 118
            t = ease_out((local - 0.22 - i * 0.045) / 0.40)
            r.draw_sprite(sp, gx, int(gy - 26 * (1 - t)) - 20, t)
            gx += sp.size[0] - 6
        y = gy + 150

    for i, sp in enumerate(sprites["lines"]):
        t = ease_out((local - 0.34 - i * 0.11) / 0.44)
        r.draw_sprite(sp, 96 - 24, int(y - 28 * (1 - t)) - 22, t)
        y += 82


SCRIM: Image.Image | None = None


def load_content(path: Path):
    """
    Load a scene list from a file rather than the import at the top.

    There is more than one thing to tell them now — the first video was what to make before any
    footage existed, this one is what to do with the footage that does. Same renderer, same
    voice, different script; the alternative was a copy of this file with two lists changed.
    """
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = module
    spec.loader.exec_module(module)
    if not getattr(module, "SCENES", None):
        raise SystemExit(f"! {path} defines no SCENES")
    return module


def main(argv: list[str] | None = None) -> int:
    global SCRIM, CONTENT, MUSIC

    ap = argparse.ArgumentParser(description="Render a vertical instruction video")
    ap.add_argument("--content", type=Path, default=HERE / "content.py",
                    help="a .py defining SCENES (default: the lettering handoff)")
    ap.add_argument("--out", type=Path, default=HERE / "what-to-make-first.mp4")
    ap.add_argument("--music", type=Path, default=MUSIC)
    ap.add_argument("--under", type=float, default=MUSIC_UNDER_DB,
                    help="dB under the speaking voice, measured in MUSIC_BAND (music.py)")
    ap.add_argument("--max", type=float, default=MAX_SECONDS,
                    help="warn past this runtime; nobody watches a long one")
    args = ap.parse_args(argv)

    CONTENT = load_content(args.content.resolve())
    MUSIC = args.music
    out = args.out.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    SCRIM = scrim(1180)
    # Per-content scratch, so rendering the second video does not read the first one's voice
    # files — they are named by index, and index 3 means a different sentence in each script.
    work = HERE / ".build" / args.content.stem
    work.mkdir(parents=True, exist_ok=True)

    timeline: list[Timed] = []
    cursor = 0.0
    for i, scene in enumerate(CONTENT.SCENES):
        audio = work / f"vo_{i:02d}.wav"
        hold = narrate(scene.say, audio)
        timeline.append(Timed(scene, audio, hold, cursor))
        cursor += hold
    total = cursor
    print(f"  {len(timeline)} scenes, {total:.1f}s")

    voice = work / "voice.wav"
    listing = work / "audio.txt"
    listing.write_text("".join(f"file '{t.audio.name}'\n" for t in timeline))
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0",
                    "-i", str(listing), "-c:a", "pcm_s16le", "-ar", "48000", str(voice)],
                   check=True, cwd=work)
    drift = abs(duration_of(voice) - total)
    print(f"  voice {duration_of(voice):.2f}s vs timeline {total:.2f}s (drift {drift:.3f}s)")
    assert drift < 0.15, "audio and picture disagree; they would truncate against each other"

    mix = work / "mix.m4a"
    if MUSIC.exists():
        gain = bed_gain(voice, MUSIC, args.under)
        fade_at = max(0.0, total - MUSIC_FADE_OUT)
        chain = (
            f"[1:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
            f"apad,atrim=0:{total:.3f},highpass=f={MUSIC_HIGHPASS_HZ},volume={gain:.5f},"
            f"afade=t=in:st=0:d={MUSIC_FADE_IN},"
            f"afade=t=out:st={fade_at:.3f}:d={MUSIC_FADE_OUT}[bed];"
            f"[0:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[vo];"
            f"[vo][bed]amix=inputs=2:duration=first:normalize=0,"
            f"loudnorm=I={TARGET_LUFS}:TP=-1.5:LRA=11[out]"
        )
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(voice), "-i", str(MUSIC),
                        "-filter_complex", chain, "-map", "[out]",
                        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", str(mix)], check=True)
        print(f"  music bed {MUSIC.name} at gain {gain:.4f} "
              f"({args.under:.0f} dB under the speaking voice, measured "
              f"{MUSIC_BAND[0]:.0f} Hz-{MUSIC_BAND[1] / 1000:.0f} kHz)")
    else:
        print(f"  ! no music at {MUSIC} — voice only")
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(voice),
                        "-af", f"loudnorm=I={TARGET_LUFS}:TP=-1.5:LRA=11",
                        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", str(mix)], check=True)

    r = Renderer()
    cache = [build_sprites(t.scene) for t in timeline]

    ff = subprocess.Popen([
        "ffmpeg", "-y", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
        "-r", C.FPS_STR, "-i", "pipe:0",
        "-i", str(mix),
        "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-pix_fmt", "yuv420p",
        "-r", C.FPS_STR, "-c:a", "copy", "-shortest", "-movflags", "+faststart", str(out),
    ], stdin=subprocess.PIPE)

    frames = int(total * FPS)
    scene_index, printed = 0, -1
    for f in range(frames):
        t = f / FPS
        while scene_index + 1 < len(timeline) and t >= timeline[scene_index + 1].start:
            scene_index += 1
        timed = timeline[scene_index]
        render_scene(r, timed, cache[scene_index], t - timed.start, t, scene_index)
        ff.stdin.write(r.read())
        pct = int(f / frames * 100)
        if pct % 20 == 0 and pct != printed:
            print(f"   {pct:3}%")
            printed = pct

    ff.stdin.close()
    ff.wait()

    print(f"\n  {out.name} — {total:.1f}s, {W}x{H}, {out.stat().st_size / 1e6:.1f} MB")
    if total > args.max:
        print(f"  ! over the {args.max:.0f}s limit by {total - args.max:.1f}s")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
