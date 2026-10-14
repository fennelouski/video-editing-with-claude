"""
config.py — single source of truth for every number in taste_principles.md.

If a constant appears in taste_principles.md, it lives here and nowhere else.
Changing a value here changes it for every stage. Never hard-code these in a stage.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

# --------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent

# Where the big, un-versioned folders live. Resolution order, first hit wins:
#   1. paths.json at the repo root (written by `./run setup.py`; see SETUP.md)
#   2. a folder of that name in a parent directory (the repo sits inside the video folder)
#   3. inside the repo
_PATH_KEYS = ("footage", "assets", "build", "cuts", "script", "templates")
PATHS_FILE = Path(os.environ.get("CLAUTO_PATHS", str(ROOT / "paths.json"))).expanduser().resolve()
if "CLAUTO_PATHS" in os.environ and not PATHS_FILE.is_file():
    raise ValueError(f"project paths file unavailable: {PATHS_FILE}; reopen the project drive")
_PATH_SETTINGS = json.loads(PATHS_FILE.read_text()) if PATHS_FILE.is_file() else {}
if "CLAUTO_PATHS" in os.environ:
    missing = [key for key in ("footage", "assets", "build", "cuts") if not _PATH_SETTINGS.get(key)]
    if missing:
        raise ValueError(f"project paths missing {', '.join(missing)}; reopen setup for this project")
ENGINE_VERSION = (ROOT / "ENGINE_VERSION").read_text().strip()
WHISPER_MODEL = os.environ.get("CLAUTO_WHISPER_MODEL", _PATH_SETTINGS.get("whisper_model", "large-v3"))


def _find_path(key: str) -> Path:
    chosen = _PATH_SETTINGS.get(key)
    if chosen:
        path = Path(chosen).expanduser()
        return path if path.is_absolute() else PATHS_FILE.parent / path
    for parent in list(ROOT.parents)[:3]:
        if (parent / key).is_dir():
            return parent / key
    return ROOT / key


FOOTAGE = _find_path("footage")
ASSETS = _find_path("assets")
BUILD = _find_path("build")
CUTS = _find_path("cuts")

CUTOUTS = ASSETS / "cutouts"
TEXTURES = ASSETS / "textures"
FONTS = ASSETS / "fonts"
FOLEY = ASSETS / "foley"
MUSIC = ASSETS / "music"
LUTS = ASSETS / "luts"

SCRIPT_DIR = _find_path("script") if _PATH_SETTINGS.get("script") else (CUTS / "script" if CUTS != ROOT / "cuts" else ROOT / "script")
TEMPLATES = _find_path("templates")

TRANSCRIPTS = BUILD / "transcripts"
ROUGHCUT = BUILD / "roughcut"
PLAN_DIR = BUILD / "plan"
FRAMES = BUILD / "frames"
GRAPHICS = BUILD / "graphics"
REVIEW = BUILD / "review"
EXPORTS = BUILD / "exports"

TASTE_PRINCIPLES = ROOT / "taste_principles.md"
STYLE_GUIDE = ROOT / "style_guide.md"

ALL_BUILD_DIRS = [TRANSCRIPTS, ROUGHCUT, PLAN_DIR, FRAMES, GRAPHICS, REVIEW, EXPORTS]


def path_label(path: Path) -> str:
    """Keep repo paths readable and external media references usable as absolute paths."""
    path = Path(path).expanduser()
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


# --------------------------------------------------------------------------------------
# Canvas  (taste_principles §2)
# --------------------------------------------------------------------------------------

# --- Timebase -------------------------------------------------------------------------
# All three Canon bodies (T3i / 600D, R100, RP) record "24p" as 23.976, not true 24.000 —
# Canon consumer bodies in NTSC regions have no exact-24 mode. So the whole chain is
# 24000/1001. Mixing a true-24 asset into this timeline causes progressive audio drift.
FPS_NUM = 24000
FPS_DEN = 1001
FPS = FPS_NUM / FPS_DEN             # 23.976023976…
FPS_STR = f"{FPS_NUM}/{FPS_DEN}"    # for ffmpeg -r
FRAME_MS = 1000.0 * FPS_DEN / FPS_NUM   # 41.708 ms

# FCPXML expresses every time as a rational on the frame grid.
FCPXML_TIMESCALE = FPS_NUM              # 24000
FCPXML_FRAME_TICKS = FPS_DEN            # 1001 ticks per frame
FRAME_DURATION = f"{FPS_DEN}/{FPS_NUM}s"

GRAPHIC_STEP = 2            # graphics step on 2s -> ~11.99 unique positions/second


def frames(seconds: float) -> int:
    """Seconds -> whole frames on the 23.976 grid."""
    return int(round(seconds * FPS))


def fcp_time(seconds: float) -> str:
    """
    Seconds -> an FCPXML rational time string, snapped to the frame grid.

    Every time value in an FCPXML must be an integer multiple of the frame duration.
    An off-grid value is the single most common reason FCP rejects an import or silently
    shifts a clip by a frame.
    """
    ticks = frames(seconds) * FCPXML_FRAME_TICKS
    return f"{ticks}/{FCPXML_TIMESCALE}s" if ticks else "0s"


def fcp_duration(seconds: float, minimum_frames: int = 1) -> str:
    """Same as fcp_time but never zero-length — FCP drops zero-duration elements."""
    n = max(minimum_frames, frames(seconds))
    return f"{n * FCPXML_FRAME_TICKS}/{FCPXML_TIMESCALE}s"


def snap_seconds(seconds: float) -> float:
    """Round a time to the nearest frame boundary, in seconds."""
    return frames(seconds) * FPS_DEN / FPS_NUM

ASPECTS = {
    "16:9": {
        "author": (1920, 1080),
        # The T3i is 1080-only, so the timeline is 1080p. R100/RP 4K is useful for reframing
        # and punch-ins in the edit, but it does not set the sequence format.
        "render": (1920, 1080),
        "fcp_format_name": "FFVideoFormat1080p2398",
        "margin_left": 120,
        "margin_right": 120,
        "margin_top": 80,
        "margin_bottom": 100,
        "margin_bottom_captioned": 160,
        # player chrome exclusion (progress bar, timestamp, end cards)
        "chrome_bottom": 120,
        "chrome_right": 320,
        "caption_baseline": 940,
        "root_divisor": 120,        # html font-size: 100vw / 120
    },
    "9:16": {
        "author": (1080, 1920),
        "render": (1080, 1920),
        "fcp_format_name": "FFVideoFormatRateUndefined",
        "margin_left": 60,
        "margin_right": 220,        # like/comment/share rail
        "margin_top": 220,
        "margin_bottom": 480,       # caption, handle, audio ticker, CTA
        "margin_bottom_captioned": 480,
        "chrome_bottom": 480,
        "chrome_right": 220,
        "caption_baseline": 1300,
        "root_divisor": 45,
        # hero band — the only region guaranteed visible on all platforms
        "hero_band": (480, 1300),
    },
}

DEFAULT_ASPECT = "16:9"

RESOLUTIONS = {"720p": 720, "1080p": 1080, "2160p": 2160}
DEFAULT_RESOLUTION = _PATH_SETTINGS.get("export_resolution", "1080p")
if DEFAULT_RESOLUTION not in RESOLUTIONS:
    raise ValueError("export_resolution must be 720p, 1080p, or 2160p")


def canvas_spec(aspect: str, resolution: str | None = None) -> dict:
    """Scale the authoring grid, captions and safe areas together from the 1080p design."""
    resolution = DEFAULT_RESOLUTION if resolution is None else resolution
    if resolution not in RESOLUTIONS:
        raise ValueError("resolution must be 720p, 1080p, or 2160p")
    spec = dict(ASPECTS[aspect])
    factor = RESOLUTIONS[resolution] / 1080
    for key in ("author", "render", "hero_band"):
        if key in spec:
            spec[key] = tuple(round(v * factor) for v in spec[key])
    for key in ("margin_left", "margin_right", "margin_top", "margin_bottom", "margin_bottom_captioned",
                "chrome_bottom", "chrome_right", "caption_baseline"):
        spec[key] = round(spec[key] * factor)
    spec["pixel_scale"] = factor
    spec["resolution"] = resolution
    spec["fcp_format_name"] = "FFVideoFormatRateUndefined"
    return spec

SPACING_RAMP = (8, 16, 24, 32, 48, 64, 96, 128)
GRID_UNIT = 8


# --------------------------------------------------------------------------------------
# Imperfection budget  (§2.3)
# --------------------------------------------------------------------------------------

ROTATION_MIN_DEG = 0.5
ROTATION_MAX_DEG = 2.5
ROTATION_HARD_MAX_DEG = 4.0     # above this = mistake, not a choice
POSITION_JITTER_MAX_PX = 6
SCALE_VARIANCE = (0.94, 1.06)
BASELINE_JITTER_PX = 4

# Idle jitter, resampled on the step clock (§5.2)
IDLE_JITTER_XY_PX = 1.5
IDLE_JITTER_ROT_DEG = 0.4
IDLE_JITTER_SCALE = 0.004
IDLE_JITTER_SCALE_EVERY = 4     # frames
STATIC_FRAMES_FAIL = 12         # zero delta longer than this = bug


# --------------------------------------------------------------------------------------
# Palette — Sage & Oat  (§4.1)
# --------------------------------------------------------------------------------------

PALETTE = {
    "bone":   "#F2EDE1",
    "oat":    "#E8DFC8",
    "kraft":  "#CBB893",
    "sage":   "#8A9A7B",
    "moss":   "#5C6B4F",
    "rust":   "#A5613F",
    "walnut": "#4A3C2E",
    "ink":    "#2B241D",
    "stone":  "#8B8377",
}

SEMANTIC = {
    "bg": "bone",
    "fg": "walnut",
    "fg_muted": "stone",
    "accent": "rust",
    "structure": "sage",
}

ACCENT_MAX_FRAME_FRACTION = 0.12    # rust budget, §12 check 8
PALETTE_DELTA_E_MAX = 6.0           # drift tolerance, §12 check 7
FORBIDDEN_EXACT = ("#000000", "#FFFFFF")

GRAIN_OPACITY = (0.08, 0.14)
VIGNETTE_MAX = 0.06

SHADOW = {
    "offset_x": (4, 8),
    "offset_y": (5, 10),
    "blur": (10, 20),
    "opacity": (0.20, 0.30),
    "rgb": (74, 60, 46),            # --walnut, never pure black
    "direction": "down-right",      # constant across the entire channel
}

MAX_DEPTH_PLANES = 3


# --------------------------------------------------------------------------------------
# Typography  (§3)
# --------------------------------------------------------------------------------------

FONT_MARKER = "HerMarker"           # rename once the font ships
FONT_TEXT = "Work Sans"
FONT_EDITORIAL = "Fraunces"         # optional, chapter cards only

TYPE_FLOOR_MARKER_PX = 40           # @1080p
TYPE_FLOOR_TEXT_PX = 24

TYPE_SCALE = {
    # role: (px @16:9, px @9:16, family, tracking_em, leading)
    "display": (120, 104, "marker", 0.01, 1.10),
    "h1":      (84,  84,  "marker", 0.01, 1.15),
    "h2":      (60,  64,  "marker", 0.02, 1.20),
    "label":   (44,  52,  "marker", 0.03, 1.25),
    "body":    (34,  42,  "text",   0.00, 1.45),
    "caption": (54,  62,  "text",   0.005, 1.25),
    "micro":   (24,  28,  "text",   0.01, 1.40),
}

MEASURE_CH = {"marker": (22, 36), "text": (28, 42)}
MEASURE_CH_VERTICAL = {"marker": (16, 26), "text": (18, 30)}

MAX_HIERARCHY_LEVELS = 3
MAX_LIST_ITEMS = 5

CAPTION_MAX_LINES = 2
CAPTION_MAX_CHARS_PER_LINE = 36
CAPTION_PLATE_ALPHA = 0.82


# --------------------------------------------------------------------------------------
# Motion  (§5)
# --------------------------------------------------------------------------------------

def frames_to_ms(n: int) -> float:
    return n * FRAME_MS


PLACE_FRAMES = (6, 10)          # settle-in
POP_FRAMES = (2, 3)
REMOVE_FRAMES = (4, 6)
STAGGER_FRAMES = 4
RISE_PX = 40
SETTLE_ROTATION_DEG = (3.0, 5.0)
MARKER_DRAW_SECONDS = (0.6, 1.1)
GRAPHIC_GAP_MS = 250            # clean frame between consecutive graphics
STAGGER_MAX_ITEMS = 5

# Hold time: max(1.6, words / 2.8 + 0.8)
HOLD_MIN_SECONDS = 1.6
HOLD_WORDS_PER_SECOND = 2.8
HOLD_PADDING_SECONDS = 0.8


def hold_seconds(word_count: int) -> float:
    """Minimum on-screen hold for a graphic carrying `word_count` words (§5.4)."""
    return max(HOLD_MIN_SECONDS, (word_count / HOLD_WORDS_PER_SECOND) + HOLD_PADDING_SECONDS)


BANNED_MOTION = (
    "spin", "flip", "cube", "wipe", "page-curl", "glitch", "vhs", "scanline",
    "light-leak", "lens-flare", "particles", "float", "bob", "pulse",
    "parallax", "zoom-punch", "ease-in-out", "motion-blur", "crossfade",
)


# --------------------------------------------------------------------------------------
# Audio  (§8)
# --------------------------------------------------------------------------------------

BREATH_FLOOR_MS = 120           # never trim below this — the machine-edit tell
BREATH_SENTENCE_MS = 150
BREATH_PARAGRAPH_MS = 250
MIN_SILENCE_TO_CUT_MS = 400     # gaps shorter than this are left alone

# What counts as silence, measured in the speech band rather than assumed from the transcript.
# Calibrated against MVI_0016, whose room floor sits at -95 dB and whose speech averages -45 dB
# in band: -50 separates them with margin and gives the same segmentation as -55. This constant
# existed for two phases marked "for ffmpeg silencedetect" and wired to nothing, which is why
# every silence decision was made from gaps in the word list. See [S-024].
SILENCE_THRESHOLD_DB = -50.0
SILENCE_MIN_MS = 100            # shortest run silencedetect will call silence
# A voiced run inside a word gap that no word accounts for. Her false starts measured 84 and
# 115 ms, so this has to sit below both; a lip smack caught alongside them is no loss.
UNTRANSCRIBED_MIN_MS = 60

# A word whose characters-per-second falls far below her speaking rate is not a word. WhisperX
# collapses a failed take into one long token — "I'm" carrying 2.0 s and four separate voiced
# bursts, which reads as a clean sentence in the transcript and as a stumble in the audio. Her
# median across the clip is 22 chars/sec; the longest legitimate trailing word manages 5.4. The
# voiced-run count below is the real discriminator, so this can stay conservative. See [S-026].
BURIED_TAKE_MIN_S = 1.0
BURIED_TAKE_CHARS_PER_S = 3.0

# How many times stage 2 will cut what the read-back heard twice and listen again. Each pass
# costs a transcription of the cut. Two is enough for a duplicate exposed by removing the take
# in front of it; more than that means the transcript is wrong in a way another pass will not
# fix, and the run should fail and say so rather than grind. See [S-026].
READBACK_MAX_PASSES = 3

# The dialogue chain from taste_principles §8: "High-pass at 80 Hz, gentle de-ess, 3:1
# compression, light limiting. Never over-processed." 3:1 at a soft knee is what §8 calls
# gentle; the release is long enough not to breathe between her words and short enough to
# recover inside a sentence. Raising the quiet half is what makes a track feel louder — the
# integrated level stays on target either way, so reaching for more gain instead just clips.
VOICE_HIGHPASS_HZ = 80
VOICE_BAND_TOP_HZ = 4000        # silence is judged in the band the voice occupies, not full-range
# Set high on purpose, so 3:1 catches her occasional loud take and leaves the rest alone. Her
# delivery is already even — the first real clip measures 3.6 LU loudness range before any
# processing, against the 6-8 LU a dialogue compressor normally exists to pull in — so a low
# threshold squashes a track that has nothing to squash, which is what §8 means by
# "never over-processed". Measured, not chosen: at -18 dB it took the range to 2.5 LU.
COMP_THRESHOLD_DB = -12.0
COMP_RATIO = 3.0
COMP_ATTACK_MS = 5.0
COMP_RELEASE_MS = 120.0
COMP_KNEE_DB = 6.0

TARGET_LUFS = -16.0
LUFS_TOLERANCE = 1.0
TRUE_PEAK_MAX_DBTP = -1.5
# The limiter has to sit below the ceiling by however much the codec overshoots it. Measured
# across two cuts of MVI_0016: 0.1 dB and 0.8 dB. A ceiling picked from one render and never
# re-measured drifted out of spec the moment the cut changed, so the preview is now measured
# after encoding and says so when it misses. [S-026]
CODEC_OVERSHOOT_DB = 1.0
PREVIEW_LIMIT_DBTP = TRUE_PEAK_MAX_DBTP - CODEC_OVERSHOOT_DB
# The music bed level lives in music.py, next to the band it is measured in — see [S-022].
# A -20 dB duck constant sat here unused; it is the figure §8 used to carry, at which the bed
# is inaudible.
HIGHPASS_HZ = 80

# Retake detection. She does five or six attempts at a line, each slightly different, so the
# threshold is well below "identical" — real retakes are rephrased, not repeated. Measured on
# her first clip: genuine retakes scored 0.74-1.00, genuinely different lines 0.45-0.59.
RETAKE_SIMILARITY = 0.70

# An abandoned start shares its opening with the line that replaces it but is mostly missing,
# so similarity cannot see it. Only applied to immediately adjacent lines: "but we do know
# that…" opens three unrelated sentences in one clip, and matching those would delete content.
# Within a cluster of takes, the last attempt is usually the keeper — but not when she trails
# off on it. An attempt this much shorter than the fullest one in its cluster is a fragment,
# not a take, so the last *substantially complete* attempt wins instead.
RETAKE_COMPLETE_FRACTION = 0.75

# She restarts mid-passage, not just mid-line, so two attempts can share a long verbatim run
# and still score barely half on whole-sentence similarity. A shared run this long, that is
# also this much of the shorter line, is a restart — nobody says the same six words twice in a
# row by accident. Both conditions are needed: "but we do know that" is a tic of hers and turns
# up in five unrelated sentences.
RETAKE_RUN_WORDS = 6
RETAKE_RUN_FRACTION = 0.5

# A line that does not end on one of these is one she trailed off on, whatever its length.
TERMINAL_PUNCTUATION = (".", "?", "!")

FALSE_START_PREFIX_WORDS = 3
FALSE_START_GAP_SECONDS = 6.0

FILLER_WORDS = (
    "um", "uh", "erm", "hmm", "like", "you know", "i mean",
    "sort of", "kind of", "basically", "actually", "so yeah",
)

BANNED_SFX_KEYWORDS = ("whoosh", "riser", "impact", "sub-drop", "boom", "swoosh", "transition")


# --------------------------------------------------------------------------------------
# Grade  (§7)
# --------------------------------------------------------------------------------------

BLACK_LIFT_IRE = (4, 6)
HIGHLIGHT_ROLLOFF_IRE = (90, 94)
CLIP_WHITE_FAIL_THRESHOLD = 0.001   # fraction of pixels at 255 that fails the check


# --------------------------------------------------------------------------------------
# Pacing  (§9)
# --------------------------------------------------------------------------------------

HOOK_MAX_SECONDS = 15
FIRST_GRAPHIC_BY_SECONDS = 30
PATTERN_INTERRUPT_MAX_SECONDS = 45
OUTRO_MAX_SECONDS = 20
LOGO_STING_MAX_SECONDS = 2


# --------------------------------------------------------------------------------------
# Final Cut Pro handoff
# --------------------------------------------------------------------------------------

# FCPXML is version-locked: FCP refuses to import a document newer than itself.
# 1.13 = Final Cut Pro 11.x.
FCPXML_VERSION = "1.13"

LIBRARY_EVENT_NAME = "Handmade pipeline"

# Roles keep the timeline navigable and make it possible to solo or disable a whole layer
# in one click. FCP creates any role named here on import.
ROLE_VIDEO = "Video"
ROLE_GRAPHICS = "Graphics"
ROLE_GRAPHICS_SUB = "Graphics.Cutouts"
ROLE_DIALOGUE = "Dialogue"
ROLE_MUSIC = "Music"
ROLE_EFFECTS = "Effects.Foley"

# Connected clips stack upward from lane 1. Captions ride in FCP's own caption lane.
LANE_GRAPHICS = 1
LANE_BROLL = 2

# Final Cut stacks negative lanes *below* the primary storyline, which is where audio belongs.
# A foley hit on a positive lane would sit in the video stack instead.
LANE_FOLEY = -1
# Music sits below foley so a tap is never buried under the bed when both are soloed.
LANE_MUSIC = -2

# When a picture comes in, the footage gets out of its way: scaled to REFRAME_SCALE and moved
# REFRAME_X px right of centre (Final Cut's position units, y up), inside a paper mat whose
# window is exactly that rectangle. The picture takes the left column at full height instead
# of sitting over her. A snap, not a move — the graphic layer cuts on a beat (§5.3).
REFRAME_SCALE = 0.5
REFRAME_X = 420
REFRAME_Y = 0

# §8 — "Every graphic placement gets a real sound: cardboard tap, paper slide, marker squeak,
# pencil scratch." The category is chosen per cue; `tap` is the default because most graphics
# are cut cardboard being set down.
FOLEY_CATEGORIES = ("tap", "slide", "squeak", "scratch")
FOLEY_DEFAULT_CATEGORY = "tap"
FOLEY_AUDIO_SUFFIXES = (".wav", ".aif", ".aiff", ".m4a", ".flac")

# Captions are native FCP objects (.itt), not a burned-in layer. This is her call and it
# trades the word-level rust highlight for captions she can actually edit as text.
# See taste_principles §6.7 and style_guide [S-005].
CAPTION_MODE = "itt"            # "itt" | "burn" | "both"
ITT_LANGUAGE = "en"

# Camera bodies in rotation. The T3i is a 2011 8-bit body with visibly different colour
# science from the R-series; matching it takes a per-body correction before the channel LUT.
CAMERAS = {
    "t3i":  {"max_res": (1920, 1080), "bit_depth": 8,  "clip_limit_min": 12, "log": False},
    "r100": {"max_res": (3840, 2160), "bit_depth": 8,  "clip_limit_min": None, "log": False},
    "rp":   {"max_res": (3840, 2160), "bit_depth": 8,  "clip_limit_min": 30, "log": True},
}


# --------------------------------------------------------------------------------------
# Policy
# --------------------------------------------------------------------------------------

# The channel does not generate footage or imagery. Missing assets block the render and
# produce a build sheet instead. See style_guide.md [S-001].
ALLOW_GENERATIVE_ASSETS = False

# Things Stage 6 must never silently fix.
ESCALATE_TO_HUMAN = (
    "scientific_claim", "numeric_value", "chart_data",
    "person_name", "credential", "repeat_failure",
)

SEED = 20260811     # deterministic jitter; bump only with a style_guide.md entry
