"""
pickslib.py — what every cut's picks builder needs and none of them should re-implement.

A picks builder is an editorial list: clip, first word, last word, why. Everything that turns
that list into frame-accurate picks lives here so it is the same for every video:

  - `padded()`     — word boundaries pushed into the silence either side, never below the
                     [S-002] floor; measured in/out points override the transcript [S-029].
  - `tighten()`    — the umms and pauses. A gap between two words is measured off the audio,
                     not read from the transcript [S-024]: the silent part is kept as breath,
                     the voiced part (an "um" the transcript never wrote down) is cut.
  - `level_match()`— one gain per source so two shoots sit at one level, measured in the band
                     the voice lives in [S-022].
  - `finish()`     — cards, pictures and chapters resolved to the files tools/cards.py makes.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import config as C

ROOT = C.ROOT
AUDIO = ROOT / "build/transcripts/_audio"

PAD_IN, PAD_OUT = 0.08, 0.12
MIN_GAP = C.BREATH_FLOOR_MS / 1000
BREATH = C.BREATH_SENTENCE_MS / 1000        # what a tightened gap is cut down to
GAP_TRIM_S = 0.40                            # a word gap longer than this is tightened
SILENCE_DB = -35


def words_of(clip: str) -> list[dict]:
    """`clip` may carry a folder ("Intro 001/MVI_0019"); the transcript is named by the stem."""
    stem = Path(clip).name
    return json.loads((ROOT / "build/transcripts" / f"{stem}.words.json").read_text())["words"]


def silences(clip: str, s: float, e: float, min_len: float, db: int = SILENCE_DB
             ) -> list[tuple[float, float]]:
    """Silent stretches ≥ min_len inside [s, e] of a clip, as absolute times."""
    if e - s < min_len:
        return []
    r = subprocess.run(
        ["ffmpeg", "-v", "info", "-ss", f"{s:.3f}", "-t", f"{e - s:.3f}",
         "-i", str(AUDIO / f"{Path(clip).name}.16k.wav"),
         "-af", f"silencedetect=n={db}dB:d={min_len}", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    out = []
    for m in re.finditer(r"silence_end: ([\d.]+) \| silence_duration: ([\d.]+)", r):
        b, d = s + float(m.group(1)), float(m.group(2))
        out.append((b - d, b))
    # A silence still open at the end of the window is reported as a start only.
    opens = re.findall(r"silence_start: ([\d.]+)", r)
    if len(opens) > len(out):
        out.append((s + float(opens[-1]), e))
    return out


def padded(words: list[dict], start: float, end: float,
           exact_start: float | None = None, exact_end: float | None = None
           ) -> tuple[float, float, list[dict]]:
    """In/out points around the words in [start, end], and the words themselves."""
    inside = [w for w in words if w["start"] >= start - 0.02 and w["end"] <= end + 0.02]
    if exact_start is not None:
        inside = [w for w in words if w["end"] > exact_start and w["end"] <= end + 0.02]
    if exact_end is not None:
        inside = [w for w in inside if w["start"] < exact_end]
    if not inside:
        raise SystemExit(f"! no words between {start} and {end}")
    before = max((w["end"] for w in words if w["end"] <= inside[0]["start"]), default=0.0)
    after = min((w["start"] for w in words if w["start"] >= inside[-1]["end"]), default=1e9)
    gap_in, gap_out = inside[0]["start"] - before, after - inside[-1]["end"]
    s = inside[0]["start"] - min(PAD_IN, max(gap_in - MIN_GAP, 0.0) / 2)
    e = inside[-1]["end"] + min(PAD_OUT, max(gap_out - MIN_GAP, 0.0) / 2)
    if exact_start is not None:
        s = exact_start
    if exact_end is not None:
        e = exact_end
    return C.snap_seconds(max(0.0, s)), C.snap_seconds(e), inside


def cuts_for(clip: str, s: float, e: float, inside: list[dict]) -> list[tuple[float, float]]:
    """
    The stretches to remove inside one take: every word gap over GAP_TRIM_S, cut down to a
    BREATH of *silence*. The breath is taken from the silent part of the gap, next to the word
    that follows — so a voiced "um" in the gap goes, and what stays is the intake before she
    speaks. A gap with no measurable silence is an um wall to wall; it is cut to a hair either
    side, which is the one place this goes under the [S-002] floor and it is by design:
    nothing in that gap was a pause.
    """
    removals = []
    for a, b in zip(inside, inside[1:]):
        g0, g1 = a["end"], b["start"]
        if g1 - g0 < GAP_TRIM_S:
            continue
        quiet = silences(clip, g0, g1, 0.10)
        keep = next(((q0, q1) for q0, q1 in reversed(quiet) if q1 - q0 >= BREATH), None)
        if keep is None:
            removals.append((g0 + 0.04, g1 - 0.04))
            continue
        q0, q1 = keep
        # Keep BREATH of the silence, ending where the silence ends; cut the rest of the gap.
        hold_from = max(q0, q1 - BREATH)
        if hold_from - g0 > 0.02:
            removals.append((g0, hold_from))
        if g1 - q1 > 0.02:
            removals.append((q1, g1))
    # Pauses inside a single long token [S-029] — silence the transcript has no gap for.
    for q0, q1 in silences(clip, s, e, 0.7):
        if q0 > s + 0.05 and q1 < e - 0.05 and not any(r0 <= q0 and q1 <= r1 for r0, r1 in removals):
            removals.append((q0 + BREATH / 2, q1 - BREATH / 2))
    removals.sort()
    return [(C.snap_seconds(a), C.snap_seconds(b)) for a, b in removals if b - a > 1 / C.FPS]


def split(pick: dict, removals: list[tuple[float, float]]) -> list[dict]:
    """
    One pick → several with the removals cut out. Picture inserts carry across (the b-roll
    keeps running, which hides the jump); cues go to the part holding their moment; chapter
    and text stay on the first part. A push is never split — it would restart.
    """
    if not removals or pick.get("push_to"):
        return [pick]
    bounds, cur = [], pick["start"]
    for a, b in removals:
        if a <= cur:
            cur = max(cur, b)
            continue
        bounds.append((cur, a))
        cur = b
    if pick["end"] - cur > 1 / C.FPS:
        bounds.append((cur, pick["end"]))
    bounds = [(a, b) for a, b in bounds if b - a >= 2 / C.FPS]

    # Each part's place on the original pick's clock, with the removed stretches taken out.
    locals_, removed, prev_end = [], 0.0, pick["start"]
    for ps, pe in bounds:
        removed += ps - prev_end
        locals_.append(ps - pick["start"] - removed)
        prev_end = pe

    out = []
    for i, ((ps, pe), local0) in enumerate(zip(bounds, locals_)):
        part = {k: v for k, v in pick.items() if k not in ("cues", "video", "chapter", "text")}
        part |= {"start": ps, "end": pe, "note": pick["note"] + ("" if i == 0 else f" ({i + 1})")}
        if i == 0:
            part["text"] = pick["text"]
            if pick.get("chapter"):
                part["chapter"] = pick["chapter"]
        if v := pick.get("video"):
            vdur = v.get("duration", pick["end"] - pick["start"])
            if local0 < vdur:
                part["video"] = {**v, "start": round(v["start"] + local0, 3),
                                 "duration": round(min(vdur - local0, pe - ps), 3)}
        # A cue goes to the last part that starts at or before its moment — so a moment that
        # fell inside a removed pause lands at the end of the part before it, not nowhere.
        cues = []
        for c in pick.get("cues", []):
            owner = max((k for k, l0 in enumerate(locals_) if l0 <= c["at"]), default=0)
            if owner == i:
                cues.append({**c, "at": round(min(max(0.0, c["at"] - local0), pe - ps), 3)})
        if cues:
            part["cues"] = cues
        out.append(part)
    return out


def level_match(picks: list[dict], band=(200, 4000)) -> dict[str, float]:
    """One gain per source clip, so every take sits at the cut's median in-band level."""
    by_src: dict[str, list[dict]] = {}
    for p in picks:
        by_src.setdefault(p["source"], []).append(p)
    loud: dict[str, float] = {}
    for src, ps in by_src.items():
        clip = Path(src).stem
        parts = "".join(f"[0:a]atrim=start={p['start']:.3f}:end={p['end']:.3f},asetpts=PTS-STARTPTS[a{i}];"
                        for i, p in enumerate(ps))
        graph = (parts + "".join(f"[a{i}]" for i in range(len(ps)))
                 + f"concat=n={len(ps)}:v=0:a=1,highpass=f={band[0]},lowpass=f={band[1]},"
                 f"ebur128=framelog=quiet")
        r = subprocess.run(["ffmpeg", "-v", "info", "-i", str(AUDIO / f"{clip}.16k.wav"),
                            "-filter_complex", graph, "-f", "null", "-"],
                           capture_output=True, text=True).stderr
        m = re.findall(r"I:\s+(-?[\d.]+) LUFS", r)
        loud[src] = float(m[-1]) if m else float("nan")
    target = sorted(v for v in loud.values() if v == v)[len(loud) // 2]
    gains = {src: round(target - v, 1) for src, v in loud.items() if v == v}
    for p in picks:
        if gains.get(p["source"]):
            p["gain_db"] = gains[p["source"]]
    return gains


def build(rows: list[tuple], *, a_dir: str, gfx: str, tighten: bool = True) -> list[dict]:
    """Rows of (clip, first-word start, last-word end, note, extras) → picks."""
    cache: dict[str, list[dict]] = {}
    picks, chapter_n = [], 0
    for clip, start, end, note, *rest in rows:
        extras = json.loads(json.dumps(rest[0])) if rest else {}
        words = cache.setdefault(clip, words_of(clip))
        s, e, inside = padded(words, start, end, extras.pop("exact_start", None),
                              extras.pop("exact_end", None))
        if extras.get("chapter"):
            chapter_n += 1
        for cue in extras.get("cues", []):
            if cue["text"].startswith("GFX: title card"):
                cue["layer"] = f"{gfx}/title_placeholder.mov"
            elif cue["text"].startswith("GFX: chapter card"):
                cue["layer"] = f"{gfx}/chapter-{chapter_n:02d}_placeholder.mov"
            elif cue.get("picture"):
                cue["layer"] = f"{gfx}/picture-{Path(cue['picture']).stem}.mov"
        src = f"{clip}.MOV" if "/" in clip else f"{a_dir}/{clip}.MOV"
        pick = {"source": src, "start": s, "end": e, "note": note,
                "text": " ".join(w["word"] for w in inside), **extras}
        picks += split(pick, cuts_for(clip, s, e, inside)) if tighten else [pick]
    return picks


def write(out: Path, project: str, picks: list[dict], music: list[dict], **extra) -> float:
    total = sum(p["end"] - p["start"] for p in picks)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"project": project, "music": music, **extra, "picks": picks},
                              indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  ✓ {out.relative_to(ROOT)}  {len(picks)} picks, {int(total // 60)}:{int(total % 60):02d}")
    return total
