"""
fcpxml.py — Final Cut Pro handoff.

Writes FCPXML 1.13 (Final Cut Pro 11). The pipeline's job ends at a timeline she opens and
keeps editing — it does not flatten a master. Cuts, graphics, markers and roles arrive
already assembled; every one of them stays editable.

Three things this module is careful about, because they are the three ways an FCPXML import
goes wrong:

1. **Every time value sits on the frame grid.** FCPXML times are rationals like `5005/24000s`
   (= 5 frames at 23.976). An off-grid value makes FCP either reject the file or silently
   shift a clip a frame. All arithmetic here happens in integer frames and converts once.

2. **Connected-clip offsets are in the parent's local time, not timeline time.** A graphic at
   timeline 00:01:12 attached to a clip that starts at timeline 00:01:00 with a source start
   of 00:00:30 has offset 00:00:42 — parent.start + (timeline_pos − parent.offset). Getting
   this wrong is why graphics land in the wrong place.

3. **Assets need absolute file:// URLs.** Relative paths import as offline media.
"""

from __future__ import annotations

import hashlib
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote
from xml.etree import ElementTree as ET

import config as C


# --------------------------------------------------------------------------------------
# Time
# --------------------------------------------------------------------------------------

def t(seconds: float) -> str:
    return C.fcp_time(seconds)


def dur(seconds: float) -> str:
    return C.fcp_duration(seconds)


# --------------------------------------------------------------------------------------
# Media probing
# --------------------------------------------------------------------------------------

def probe(path: Path) -> dict:
    """ffprobe an asset. FCP needs to know whether a file carries video, audio, or both."""
    cmd = [
        "ffprobe", "-v", "error", "-of", "default=nw=1",
        "-show_entries",
        "format=duration:stream=codec_type,width,height,channels,sample_rate,r_frame_rate",
        str(path),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    # fps is None until a video stream reports one — "not known" and "matches the timebase"
    # are different facts, and a caller checking [S-007] must be able to tell them apart.
    info: dict = {"duration": 0.0, "has_video": False, "has_audio": False,
                  "width": 0, "height": 0, "channels": 2, "sample_rate": 48000,
                  "fps": None, "frame_duration": None}
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == "codec_type":
            if v == "video":
                info["has_video"] = True
            elif v == "audio":
                info["has_audio"] = True
        elif k == "duration" and v not in ("N/A", ""):
            info["duration"] = float(v)
        elif k == "width" and v.isdigit():
            info["width"] = int(v)
        elif k == "height" and v.isdigit():
            info["height"] = int(v)
        elif k == "channels" and v.isdigit():
            info["channels"] = int(v)
        elif k == "sample_rate" and v.isdigit():
            info["sample_rate"] = int(v)
        elif k == "r_frame_rate" and "/" in v:
            num, den = v.split("/", 1)
            if den.isdigit() and int(den) and num.isdigit() and int(num):
                info["fps"] = int(num) / int(den)
                info["frame_duration"] = f"{int(den)}/{int(num)}s"
    return info


def file_url(path: Path) -> str:
    return "file://" + quote(str(path.resolve()))


def sig(path: Path) -> str:
    """A stable signature so re-importing the same media doesn't duplicate it in the library."""
    stat = path.stat()
    return hashlib.md5(f"{path.name}:{stat.st_size}".encode()).hexdigest().upper()


# --------------------------------------------------------------------------------------
# Model
# --------------------------------------------------------------------------------------

class TimelineMap:
    """
    Maps source-media time onto the cut timeline.

    This is the piece that is easy to forget and expensive to get wrong. Stage 3 anchors every
    cue to the *transcript*, which is in source time. Stage 2 then removes ~35% of that source.
    A graphic anchored at source 31.5s belongs at timeline ~19s — placing it at 31.5s puts it
    past the end of a 24s timeline, where it silently disappears.
    """

    def __init__(self, keeps: list[dict]):
        self.spans: list[tuple[float, float, float]] = []   # (src_in, src_out, timeline_in)
        t = 0.0
        for k in keeps:
            self.spans.append((k["start"], k["end"], t))
            t += k["end"] - k["start"]
        self.duration = t

    def to_timeline(self, src: float) -> float | None:
        """Exact mapping, or None if this moment was cut out."""
        for s, e, tl in self.spans:
            if s <= src < e:
                return tl + (src - s)
        return None

    def source_ranges(self, t0: float, t1: float) -> list[tuple[float, float]]:
        """
        The inverse: every source range the cut plays between two timeline moments.

        A span of the finished cut can straddle several keeps, so this returns a list rather
        than a single range. Used to take something heard in the rendered cut back to the
        source time where it lives, so it can be dropped — see stage 2's read-back [S-026].
        """
        out: list[tuple[float, float]] = []
        for s, e, tl in self.spans:
            lo, hi = max(t0, tl), min(t1, tl + (e - s))
            if hi > lo:
                out.append((s + (lo - tl), s + (hi - tl)))
        return out

    def nearest(self, src: float) -> tuple[float, bool]:
        """
        Map to the timeline, snapping to the closest surviving moment if the anchor landed
        inside a removed span. Returns (timeline_time, was_snapped).
        """
        exact = self.to_timeline(src)
        if exact is not None:
            return exact, False
        if not self.spans:
            return 0.0, True
        best, best_d = 0.0, float("inf")
        for s, e, tl in self.spans:
            for edge, mapped in ((s, tl), (e, tl + (e - s))):
                d = abs(src - edge)
                if d < best_d:
                    best_d, best = d, mapped
        return max(0.0, min(best, self.duration)), True


@dataclass
class Clip:
    """A segment on the primary storyline."""
    asset_path: Path
    offset: float           # position on the timeline, seconds
    start: float            # in-point within the source, seconds
    duration: float
    name: str = ""
    role: str = C.ROLE_VIDEO
    markers: list[tuple[float, str, bool]] = field(default_factory=list)  # (timeline_s, text, is_todo)
    # A level, written as an <adjust-volume> child rather than baked into the media, so it
    # stays a fader she can move. Used where one camera was recorded far below the others.
    gain_db: float | None = None
    # A framing, written as <adjust-transform> rather than rendered — the same reason as the
    # level above. `scale` is a static punch-in (a cut between two takes of the same framing
    # reads as a jump; 8% closer reads as a second camera). `push_to` animates from `scale` to
    # this value across the clip: a slow push under an emphasised line. Keyframes are in
    # parent-local time, like everything else attached to the clip.
    scale: float | None = None
    push_to: float | None = None
    # Source-time intervals during which the clip is reframed (config.REFRAME_*) so a picture
    # can take the left of the frame. Composed with `scale`/`push_to` into one keyframed
    # transform; a snap in and out, one frame long.
    reframe: list[tuple[float, float]] = field(default_factory=list)
    conform: str | None = None
    position: tuple[float, float] = (0.0, 0.0)
    audio_enabled: bool = True

    def transform_keys(self) -> list[tuple[float, float, float, float]]:
        """(source time, scale, x, y) keyframes describing the whole clip's framing."""
        base0 = self.scale if self.scale is not None else 1.0
        base1 = self.push_to if self.push_to is not None else base0
        t0, t1 = self.start, self.start + self.duration
        base = lambda t: base0 + (base1 - base0) * ((t - t0) / (t1 - t0) if t1 > t0 else 0.0)
        keys = [(t0, base0, 0.0, 0.0)]
        f = 1 / C.FPS
        for a, b in sorted(self.reframe):
            a, b = max(a, t0), min(b, t1)
            if b <= a:
                continue
            if a > t0:
                keys.append((a - f, base(a - f), 0.0, 0.0))
            keys.append((a, base(a) * C.REFRAME_SCALE, float(C.REFRAME_X), float(C.REFRAME_Y)))
            keys.append((b, base(b) * C.REFRAME_SCALE, float(C.REFRAME_X), float(C.REFRAME_Y)))
            if b < t1:
                keys.append((b + f, base(b + f), 0.0, 0.0))
        if keys[-1][0] < t1:
            keys.append((t1, base1, 0.0, 0.0))
        return keys


@dataclass
class Connected:
    """
    A clip attached to the storyline — a graphic above it, or a sound below it.

    `audio` decides both which role attribute is written and which way the lane points. Final
    Cut stacks positive lanes above the primary storyline and negative lanes below it, so a
    foley hit on lane 1 would sit in the video stack and a graphic on lane -1 would disappear
    under the picture.
    """
    asset_path: Path
    offset: float           # timeline position, seconds
    duration: float
    name: str = ""
    lane: int = C.LANE_GRAPHICS
    role: str = C.ROLE_GRAPHICS_SUB
    start: float = 0.0
    audio: bool = False
    # Emit a <video> element rather than an <asset-clip>. `<video>` references only the asset's
    # video stream, which is what a picture-only insert means — an asset-clip would also bring
    # the source's audio into the mix, and cutting picture from one moment over sound from
    # another is the entire point of a split edit.
    video_only: bool = False
    # Written as an <adjust-volume> child rather than baked into the media. A bed imported at
    # unity blasts over her until someone drags it down, and a bed rendered into the audio is
    # a level she can no longer change — this lands it where it was measured and leaves the
    # fader where she can reach it. [S-006]
    gain_db: float | None = None
    scale: float = 1.0
    position: tuple[float, float] = (0.0, 0.0)
    conform: str | None = None


class FCPXMLBuilder:
    def __init__(self, project: str, aspect: str = C.DEFAULT_ASPECT,
                 event: str = C.LIBRARY_EVENT_NAME, resolution: str | None = None):
        self.project = project
        self.aspect = aspect
        self.event = event
        self.spec = C.canvas_spec(aspect, resolution)
        self._resources: dict[str, str] = {}     # path -> resource id
        self._assets: list[tuple[str, Path, dict]] = []
        self._next_id = 2                        # r1 is the format

    def _asset_id(self, path: Path) -> str:
        key = str(path.resolve())
        if key in self._resources:
            return self._resources[key]
        rid = f"r{self._next_id}"
        self._next_id += 1
        self._resources[key] = rid
        self._assets.append((rid, path, probe(path)))
        return rid

    # ----------------------------------------------------------------------------------

    def build(self, clips: list[Clip], connected: list[Connected],
              chapters: list[tuple[float, str]] | None = None) -> ET.ElementTree:
        if not clips:
            raise ValueError("an FCPXML needs at least one clip on the primary storyline")

        # Register everything up front so resource ids are stable.
        for c in clips:
            self._asset_id(c.asset_path)
        for g in connected:
            self._asset_id(g.asset_path)

        root = ET.Element("fcpxml", version=C.FCPXML_VERSION)
        resources = ET.SubElement(root, "resources")

        w, h = self.spec["author"]
        ET.SubElement(
            resources, "format",
            id="r1",
            name=self.spec.get("fcp_format_name", "FFVideoFormatRateUndefined"),
            frameDuration=C.FRAME_DURATION,
            width=str(w), height=str(h),
            colorSpace="1-1-1 (Rec. 709)",
        )

        source_formats: dict[tuple, str] = {}
        for _, _, info in self._assets:
            if not info["has_video"]: continue
            key = (info["width"], info["height"], info.get("frame_duration") or C.FRAME_DURATION)
            if key == (w,h,C.FRAME_DURATION): source_formats[key] = "r1"; continue
            if key not in source_formats:
                fid = f"sourceFormat{len(source_formats)+1}"
                source_formats[key] = fid
                ET.SubElement(resources,"format",id=fid,name="FFVideoFormatRateUndefined",width=str(key[0]),height=str(key[1]),frameDuration=key[2],colorSpace="1-1-1 (Rec. 709)")

        for rid, path, info in self._assets:
            attrs = {
                "id": rid,
                "name": path.stem,
                "start": "0s",
                "duration": dur(info["duration"] or 1.0),
                "hasVideo": "1" if info["has_video"] else "0",
                "format": source_formats.get((info["width"],info["height"],info.get("frame_duration") or C.FRAME_DURATION),"r1"),
            }
            if info["has_audio"]:
                attrs |= {
                    "hasAudio": "1",
                    "audioSources": "1",
                    "audioChannels": str(info["channels"]),
                    "audioRate": str(info["sample_rate"]),
                }
            asset = ET.SubElement(resources, "asset", **attrs)
            ET.SubElement(asset, "media-rep", kind="original-media",
                          sig=sig(path), src=file_url(path))

        library = ET.SubElement(root, "library")
        event = ET.SubElement(library, "event", name=self.event)
        project = ET.SubElement(event, "project", name=self.project)

        total = max((c.offset + c.duration) for c in clips)
        sequence = ET.SubElement(
            project, "sequence",
            format="r1",
            duration=dur(total),
            tcStart="0s",
            tcFormat="NDF",
            audioLayout="stereo",
            audioRate="48k",
        )
        spine = ET.SubElement(sequence, "spine")

        for clip in clips:
            el = ET.SubElement(
                spine, "asset-clip",
                ref=self._asset_id(clip.asset_path),
                offset=t(clip.offset),
                name=clip.name or clip.asset_path.stem,
                start=t(clip.start),
                duration=dur(clip.duration),
                format="r1",
                tcFormat="NDF",
            )
            info = next(i for r, p, i in self._assets if p.resolve() == clip.asset_path.resolve())
            if info["has_audio"]:
                el.set("audioRole", C.ROLE_DIALOGUE)
            if not clip.audio_enabled:
                el.set("srcEnable", "video")
            if clip.conform is not None:
                if clip.conform not in ("fit", "fill", "none"):
                    raise ValueError("unsupported conform mode")
                ET.SubElement(el, "adjust-conform", type=clip.conform)
            # Video intrinsics precede audio intrinsics in the DTD, so this sits before volume.
            if clip.scale is not None or clip.push_to is not None or clip.reframe or clip.position != (0.0, 0.0):
                keys = clip.transform_keys()
                frm = keys[0][1]
                xf = ET.SubElement(el, "adjust-transform", scale=f"{frm:.4f} {frm:.4f}")
                if clip.position != (0.0, 0.0):
                    xf.set("position", f"{clip.position[0]:.6f} {clip.position[1]:.6f}")
                if len(keys) > 1:
                    for name, fmt in (("scale", lambda k: f"{k[1]:.4f} {k[1]:.4f}"),
                                      ("position", lambda k: f"{k[2] + clip.position[0]:.6f} {k[3] + clip.position[1]:.6f}")):
                        prm = ET.SubElement(xf, "param", name=name)
                        kfa = ET.SubElement(prm, "keyframeAnimation")
                        for k in keys:
                            ET.SubElement(kfa, "keyframe", time=t(k[0]), value=fmt(k),
                                          interp="linear")
            if clip.gain_db is not None:
                ET.SubElement(el, "adjust-volume", amount=f"{clip.gain_db:.1f}dB")

            # Connected clips whose timeline position lands inside this clip.
            for g in connected:
                if not (clip.offset <= g.offset < clip.offset + clip.duration):
                    continue
                # parent-local time — see the module docstring, point 2.
                local = clip.start + (g.offset - clip.offset)
                # The two elements take different attributes, and an undeclared one surfaces as
                # "The file could not be imported" with nothing further ([S-017]). `<video>`
                # declares a bare `role` and no `format`; `<asset-clip>` declares `format` and
                # `videoRole`/`audioRole` but no bare `role`. So neither set is optional dressing.
                extra = ({"role": g.role} if g.video_only else
                         {"format": "r1",
                          **({"audioRole": g.role} if g.audio else {"videoRole": g.role})})
                sub = ET.SubElement(
                    el, "video" if g.video_only else "asset-clip",
                    ref=self._asset_id(g.asset_path),
                    lane=str(g.lane),
                    offset=t(local),
                    name=g.name or g.asset_path.stem,
                    start=t(g.start),
                    duration=dur(g.duration),
                    **extra,
                )
                if g.audio:
                    if g.video_only: raise ValueError("a connected clip cannot be both audio-only and video-only")
                    sub.set("srcEnable","audio")
                if not g.audio:
                    if g.conform is not None:
                        if g.conform not in ("fit", "fill", "none"): raise ValueError("unsupported connected conform mode")
                        ET.SubElement(sub,"adjust-conform",type=g.conform)
                    if g.scale != 1 or g.position != (0.0,0.0):
                        ET.SubElement(sub,"adjust-transform",scale=f"{g.scale:.6f} {g.scale:.6f}",position=f"{g.position[0]:.6f} {g.position[1]:.6f}")
                if g.gain_db is not None:
                    if g.video_only: raise ValueError("a video-only connected clip cannot carry an audio gain")
                    ET.SubElement(sub, "adjust-volume", amount=f"{g.gain_db:.1f}dB")

            for at, text, todo in clip.markers:
                if not (clip.offset <= at < clip.offset + clip.duration):
                    continue
                local = clip.start + (at - clip.offset)
                m = ET.SubElement(el, "marker", start=t(local),
                                  duration=C.FRAME_DURATION, value=text)
                if todo:
                    m.set("completed", "0")

            for at, title in (chapters or []):
                if not (clip.offset <= at < clip.offset + clip.duration):
                    continue
                local = clip.start + (at - clip.offset)
                ET.SubElement(el, "chapter-marker", start=t(local),
                              duration=C.FRAME_DURATION, value=title)

        return ET.ElementTree(root)

    def write(self, tree: ET.ElementTree, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        ET.indent(tree, space="    ")
        xml = ET.tostring(tree.getroot(), encoding="unicode")
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<!DOCTYPE fcpxml>\n" + xml + "\n",
            encoding="utf-8",
        )
        return path


# --------------------------------------------------------------------------------------
# Captions — iTunes Timed Text
# --------------------------------------------------------------------------------------

def smpte(seconds: float) -> str:
    """HH:MM:SS:FF at 23.976, non-drop."""
    f = C.frames(seconds)
    fps = 24                      # iTT counts frames at the nominal rate…
    total, ff = divmod(f, fps)    # …with frameRateMultiplier declaring the 1000/1001 pulldown
    mm, ss = divmod(total, 60)
    hh, mm = divmod(mm, 60)
    return f"{hh:02d}:{mm:02d}:{ss:02d}:{ff:02d}"


def escape(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;"))


def wrap_balanced(text: str, max_chars: int = C.CAPTION_MAX_CHARS_PER_LINE,
                  max_lines: int = C.CAPTION_MAX_LINES) -> list[str]:
    """
    Break a caption into balanced lines.

    Splitting at the halfway *character* leaves one line noticeably longer than the other and
    can overshoot the limit. Instead, try every word boundary and take the split that minimises
    the longest line, preferring a break after punctuation when two splits tie — that puts the
    break where the sentence already pauses.
    """
    text = " ".join(text.split())
    if len(text) <= max_chars or max_lines < 2:
        return [text]

    words_ = text.split()
    if len(words_) < 2:
        # One token longer than the measure — a compound, a URL read aloud, or a WhisperX
        # mis-join. There is no word boundary to break on, and hyphenating would invent a
        # break that isn't in the word, so let it run long. Overshooting the measure on one
        # card is recoverable; raising here would take the whole caption build down with it.
        return [text]

    best: tuple[int, int, list[str]] | None = None
    for i in range(1, len(words_)):
        a, b = " ".join(words_[:i]), " ".join(words_[i:])
        longest = max(len(a), len(b))
        # tie-break: 0 if the first line ends on punctuation, 1 otherwise
        punctuated = 0 if a.rstrip()[-1:] in ",.;:!?—" else 1
        cand = (longest, punctuated, [a, b])
        if best is None or cand[:2] < best[:2]:
            best = cand

    assert best is not None
    longest, _, lines = best
    if longest <= max_chars or max_lines == 2:
        return lines
    # Three-plus lines: greedy fill, only reached if the card budget was raised.
    out, cur = [], ""
    for w in words_:
        if cur and len(cur) + 1 + len(w) > max_chars:
            out.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}".strip()
    if cur:
        out.append(cur)
    return out[:max_lines]


def build_itt(words: list[dict], path: Path, language: str = C.ITT_LANGUAGE,
              tmap: "TimelineMap | None" = None) -> tuple[Path, int]:
    """
    Native FCP captions. Imports into Final Cut as real caption objects she can edit as text.

    Grouped into 2-line cards on natural speech gaps, capped at the §6.7 character count so
    the line breaks are decided here rather than by FCP's auto-wrap.

    **Captions must be remapped onto the cut timeline.** The transcript is in source time; by
    the time Stage 2 has removed the retakes and dead air, a caption timed to the source is
    seconds out and still contains the lines that were cut. Words that fall inside a removed
    span are dropped entirely — that stumbled take is not in the video any more.

    Returns (path, words_dropped).
    """
    dropped = 0
    if tmap is not None:
        remapped: list[dict] = []
        for w in words:
            s = tmap.to_timeline(w["start"])
            e = tmap.to_timeline(w["end"])
            if s is None or e is None or e <= s:
                dropped += 1
                continue
            # Keep the source times: after the cut, the timeline gaps are all breath-floor
            # sized, so they no longer reveal where sentences ended. The source times still do.
            remapped.append({**w, "start": s, "end": e,
                             "src_start": w["start"], "src_end": w["end"]})
        words = remapped

    cards: list[list[dict]] = []
    cur: list[dict] = []
    # Leave a little headroom under the theoretical two-line maximum so the balanced wrap
    # always has a split that fits.
    budget = C.CAPTION_MAX_CHARS_PER_LINE * C.CAPTION_MAX_LINES - 4
    for i, wd in enumerate(words):
        cur.append(wd)
        nxt = words[i + 1] if i + 1 < len(words) else None
        length = sum(len(x["word"]) + 1 for x in cur)

        ends_sentence = wd["word"].rstrip()[-1:] in ".!?"
        tl_gap = (nxt["start"] - wd["end"]) if nxt else 99.0
        src_gap = (nxt.get("src_start", nxt["start"]) - wd.get("src_end", wd["end"])) if nxt else 99.0
        # A source gap much larger than the timeline gap means Stage 2 removed something here.
        # Never let one caption card straddle an edit point.
        crosses_cut = (src_gap - tl_gap) > 0.20

        if nxt is None or length >= budget or ends_sentence or tl_gap > 0.45 \
                or src_gap > 0.7 or crosses_cut:
            cards.append(cur)
            cur = []
    if cur:
        cards.append(cur)

    # Fold a stranded one- or two-word tail back into the card before it.
    merged: list[list[dict]] = []
    for card in cards:
        if (merged and len(card) <= 2
                and sum(len(x["word"]) + 1 for x in merged[-1] + card) < budget
                and card[0]["start"] - merged[-1][-1]["end"] < 0.5):
            merged[-1].extend(card)
        else:
            merged.append(card)
    cards = merged

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<tt xmlns="http://www.w3.org/ns/ttml"',
        '    xmlns:tts="http://www.w3.org/ns/ttml#styling"',
        '    xmlns:ttp="http://www.w3.org/ns/ttml#parameter"',
        '    xmlns:ittp="http://www.apple.com/itunes/timed-text#parameter"',
        f'    xml:lang="{language}"',
        '    ttp:timeBase="smpte"',
        '    ttp:frameRate="24"',
        '    ttp:frameRateMultiplier="1000 1001"',
        '    ttp:dropMode="nonDrop">',
        "  <head>",
        "    <styling>",
        '      <style xml:id="basic" tts:fontWeight="bold" tts:textAlign="center"/>',
        "    </styling>",
        "    <layout>",
        '      <region xml:id="bottom" tts:origin="10% 75%" tts:extent="80% 20%"'
        ' tts:displayAlign="after"/>',
        "    </layout>",
        "  </head>",
        "  <body>",
        '    <div>',
    ]

    for card in cards:
        raw = " ".join(w["word"] for w in card).strip()
        text = "<br/>".join(escape(line) for line in wrap_balanced(raw))
        lines.append(
            f'      <p region="bottom" style="basic" '
            f'begin="{smpte(card[0]["start"])}" end="{smpte(card[-1]["end"] + 0.08)}">{text}</p>'
        )

    lines += ["    </div>", "  </body>", "</tt>"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path, dropped


# --------------------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------------------

# Final Cut ships the authoritative schema for every FCPXML version it reads. Validating
# against it is worth far more than any hand-written check, because it is the same contract the
# importer enforces — and FCP's own report on a violation is "The file could not be imported",
# with nothing further.
FCP_DTD = Path(
    "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework"
    f"/Versions/A/Resources/FCPXMLv{C.FCPXML_VERSION.replace('.', '_')}.dtd"
)


def dtd_problems(path: Path) -> list[str] | None:
    """
    Validate against Final Cut's own DTD, or None if it isn't installed.

    None rather than [] on purpose: "the machine has no FCP" and "FCP's schema is satisfied"
    are different facts, and a caller that conflates them reports a green tick it did not earn.
    """
    if not FCP_DTD.exists():
        return None
    try:
        from lxml import etree
    except ImportError:      # pragma: no cover
        return None

    with FCP_DTD.open() as handle:
        dtd = etree.DTD(handle)
    if dtd.validate(etree.parse(str(path))):
        return []
    return [f"FCP schema: {e.message}" for e in dtd.error_log.filter_from_errors()]


def validate(path: Path) -> list[str]:
    """
    Structural checks that catch the failures FCP reports as an unhelpful
    "The file could not be imported".

    The hand-written checks below came first and still earn their place — they catch off-grid
    times and offline media, which are semantic errors the DTD cannot see. But the DTD is the
    real contract, so it runs too wherever Final Cut is installed.
    """
    problems: list[str] = []
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return [f"XML is malformed: {exc}"]
    root = tree.getroot()

    if root.tag != "fcpxml":
        problems.append(f"root element is <{root.tag}>, expected <fcpxml>")
    version = root.get("version")
    if version != C.FCPXML_VERSION:
        problems.append(f"version {version}, expected {C.FCPXML_VERSION}")

    # Every time attribute must be an exact multiple of the frame duration.
    for el in root.iter():
        for attr in ("offset", "start", "duration"):
            v = el.get(attr)
            if not v or v == "0s" or "/" not in v:
                continue
            try:
                num, den = v.rstrip("s").split("/")
                num, den = int(num), int(den)
            except ValueError:
                problems.append(f"<{el.tag} {attr}='{v}'> is not a rational")
                continue
            if den != C.FCPXML_TIMESCALE:
                problems.append(f"<{el.tag} {attr}='{v}'> timescale {den}, expected {C.FCPXML_TIMESCALE}")
            elif num % C.FCPXML_FRAME_TICKS:
                problems.append(
                    f"<{el.tag} {attr}='{v}'> is off the frame grid "
                    f"({num} is not a multiple of {C.FCPXML_FRAME_TICKS})"
                )

    refs = {a.get("id") for a in root.iter("asset")} | {f.get("id") for f in root.iter("format")}
    for el in root.iter():
        r = el.get("ref")
        if r and r not in refs:
            problems.append(f"<{el.tag} ref='{r}'> points at a resource that doesn't exist")

    for rep in root.iter("media-rep"):
        src = rep.get("src", "")
        if not src.startswith("file://"):
            problems.append(f"media-rep src is not an absolute file:// URL: {src[:60]}")

    if not list(root.iter("spine")):
        problems.append("no <spine> — the sequence has no primary storyline")

    schema = dtd_problems(path)
    if schema:
        problems.extend(schema)

    return problems
