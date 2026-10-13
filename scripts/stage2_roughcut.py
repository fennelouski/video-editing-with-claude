"""
Stage 2 — Rough cut.

Builds an edit decision list from the word timings: removes dead air, filler words, and
repeated takes, then renders a rough assembly.

The governing constraint is style_guide.md [S-002]: **never trim a gap below 120 ms.**
Cutting every pause to zero is the loudest signature of a machine edit. This stage
deliberately leaves breath in, and Stage 6 re-measures the export to confirm it.

Output: build/roughcut/<clip>.edl.json  +  build/roughcut/<clip>.roughcut.mp4
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import math
import re
import string
import subprocess
import sys
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from pathlib import Path

import cli
import config as C


PUNCT_END = re.compile(r"[.!?]$")
NORMALIZE = re.compile(r"[^a-z0-9 ]+")


@dataclass
class Keep:
    """A span of source time that survives into the rough cut."""
    start: float
    end: float
    reason: str = "speech"
    text: str = ""

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass
class Drop:
    start: float
    end: float
    reason: str
    text: str = ""

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass
class EDL:
    clip: str
    source: str
    fps: int
    keeps: list[Keep] = field(default_factory=list)
    drops: list[Drop] = field(default_factory=list)

    @property
    def source_duration(self) -> float:
        spans = self.keeps + self.drops
        return max((s.end for s in spans), default=0.0)

    @property
    def cut_duration(self) -> float:
        return sum(k.duration for k in self.keeps)


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------

def norm(text: str) -> str:
    return NORMALIZE.sub("", text.lower()).strip()


def snap_to_frame(t: float, mode: str = "nearest") -> float:
    """Cuts land on frame boundaries. An off-grid cut shows as a torn field on export."""
    f = t * C.FPS
    if mode == "floor":
        f = int(f)
    elif mode == "ceil":
        f = int(f) + (1 if f % 1 else 0)
    else:
        f = round(f)
    return round(f / C.FPS, 4)


def load_words(path: Path) -> tuple[dict, list[dict]]:
    data = json.loads(path.read_text())
    return data, data["words"]


# --------------------------------------------------------------------------------------
# Pass 1 — repeated takes
# --------------------------------------------------------------------------------------

def group_sentences(words: list[dict]) -> list[dict]:
    """Chunk words into sentences using punctuation, falling back on long gaps."""
    sentences: list[dict] = []
    cur: list[dict] = []
    for i, w in enumerate(words):
        cur.append(w)
        gap_next = (words[i + 1]["start"] - w["end"]) if i + 1 < len(words) else 99.0
        if PUNCT_END.search(w["word"]) or gap_next > 1.0:
            sentences.append(
                {
                    "start": cur[0]["start"],
                    "end": cur[-1]["end"],
                    "text": " ".join(x["word"] for x in cur),
                    "words": len(cur),
                }
            )
            cur = []
    if cur:
        sentences.append(
            {
                "start": cur[0]["start"],
                "end": cur[-1]["end"],
                "text": " ".join(x["word"] for x in cur),
                "words": len(cur),
            }
        )
    return sentences


def common_prefix_words(a: str, b: str) -> int:
    """How many opening words two lines share."""
    wa, wb = a.split(), b.split()
    n = 0
    for x, y in zip(wa, wb):
        if x != y:
            break
        n += 1
    return n


def is_fragment(a: str, b: str) -> bool:
    """
    Is one of these lines the head or the tail of the other?

    Similarity can't see this. "thousands of years ago." shares four words with the ten-word
    line it is the tail of, which scores well under the threshold, so it survived as its own
    shot immediately after the complete take it broke off from. What marks a run-up or a
    trail-off is that it is *contiguous* with one end of the full line — which is exactly what
    separates it from a phrase that merely shares vocabulary.
    """
    wa, wb = a.split(), b.split()
    short, long = (wa, wb) if len(wa) <= len(wb) else (wb, wa)
    if len(short) < C.FALSE_START_PREFIX_WORDS or len(short) == len(long):
        return False
    return short == long[:len(short)] or short == long[-len(short):]


def longest_shared_run(a: str, b: str) -> int:
    """Longest run of consecutive words these two lines have verbatim in common."""
    wa, wb = a.split(), b.split()
    best = 0
    for i in range(len(wa)):
        for j in range(len(wb)):
            n = 0
            while i + n < len(wa) and j + n < len(wb) and wa[i + n] == wb[j + n]:
                n += 1
            best = max(best, n)
    return best


def is_restart(a: str, b: str) -> bool:
    """
    Two attempts at the same passage, detected by verbatim overlap rather than by similarity.

    "…the earliest records that we have are from Egypt" ran fourteen words verbatim across two
    takes that scored 0.56 whole-sentence, so both shipped and the cut said Egypt twice. The run
    also has to be most of the shorter line: six words alone matches her "but we do know that"
    tic, which opens five unrelated sentences in this clip.
    """
    shorter = min(len(a.split()), len(b.split()))
    run = longest_shared_run(a, b)
    return run >= C.RETAKE_RUN_WORDS and run >= shorter * C.RETAKE_RUN_FRACTION


def is_complete(text: str) -> bool:
    """Did she finish the sentence, or trail off? An ellipsis is trailing off."""
    stripped = text.strip()
    return stripped.endswith(C.TERMINAL_PUNCTUATION) and not stripped.endswith("...")


def find_repeated_takes(
    sentences: list[dict],
    similarity: float = C.RETAKE_SIMILARITY,
    window_seconds: float = 45.0,
    min_words: int = 4,
) -> list[dict]:
    """
    Keep the LAST attempt at a line and drop every earlier one.

    Clustered, not paired. She rarely does a line twice — she does it five or six times, each
    slightly different, so a pairwise test at a high threshold catches the identical pairs and
    leaves the rest. Grouping transitively means take 1 and take 5 end up in the same cluster
    even when they are only similar *through* takes 2, 3 and 4.

    Two things count as the same line:

      **Similar enough**, at `RETAKE_SIMILARITY`. Lower than the old 0.86, because real retakes
      are rephrased rather than repeated — "as humans we started using yeast thousands of years
      ago" against "as humans we started using yeast" scores 0.74 and is obviously the same
      line being attempted twice.

      **An abandoned start.** A short line that shares its opening words with the *immediately
      following* longer one is a false start — "Hi, I'm Katie, this is…" before "Hi, I'm Katie,
      I'm a food scientist, and…". Similarity alone scores that far too low to catch, because
      the abandoned take is mostly missing rather than mostly different. Restricted to adjacent
      sentences: two lines that merely open the same way minutes apart are separate content,
      and "but we do know that…" opens three different sentences in this clip alone.
    """
    usable = [(i, s) for i, s in enumerate(sentences) if s["words"] >= min_words and norm(s["text"])]
    parent = {i: i for i, _ in usable}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x, y):
        parent[find(x)] = find(y)

    reasons: dict[int, str] = {}
    for pos, (i, a) in enumerate(usable):
        na = norm(a["text"])
        for j, b in usable[pos + 1:]:
            if b["start"] - a["end"] > window_seconds:
                break
            nb = norm(b["text"])
            ratio = SequenceMatcher(None, na, nb).ratio()
            if ratio >= similarity:
                union(i, j)
                reasons[i] = f"repeated take (≈{ratio:.0%} match with a later line)"
                continue
            if is_restart(na, nb):
                union(i, j)
                reasons.setdefault(i, "earlier attempt at a passage she restarted")
                continue
            if is_fragment(na, nb):
                union(i, j)
                reasons.setdefault(i, "run-up to a fuller take of the same line")
                continue
            # An abandoned start, only ever against the very next line.
            if j == i + 1 and a["words"] < b["words"]:
                shared = common_prefix_words(na, nb)
                if shared >= C.FALSE_START_PREFIX_WORDS and \
                        b["start"] - a["end"] < C.FALSE_START_GAP_SECONDS:
                    union(i, j)
                    reasons[i] = f"false start (abandoned after {shared} words, restarted)"

    clusters: dict[int, list[int]] = {}
    for i, _ in usable:
        clusters.setdefault(find(i), []).append(i)

    dropped: list[dict] = []
    for members in clusters.values():
        if len(members) < 2:
            continue
        members.sort()

        # The last attempt is usually the keeper, but not when she trailed off on it. On the
        # first real clip the final two attempts at one line were "As humans, we started using
        # yeast." and "thousands of years ago." — the line broken in half — while the complete
        # take sat earlier in the cluster and was being discarded for being earlier.
        fullest = max(sentences[i]["words"] for i in members)
        viable = [i for i in members
                  if is_complete(sentences[i]["text"])
                  and sentences[i]["words"] >= fullest * C.RETAKE_COMPLETE_FRACTION]

        # No attempt at this passage was finished, so there is no take of it to keep. Falling
        # back to "the last one" here is what closed the first cut on a five-word tail of an
        # abandoned sentence. Dropping the passage entirely is the honest outcome: it is
        # material she has to say again, and a rough cut should surface that, not paper over it.
        keeper = viable[-1] if viable else None

        for i in members:
            if i == keeper:
                continue
            why = None if keeper is None else reasons.get(i)
            if keeper is None:
                why = "no complete take of this passage — she never finished it"
            elif why is None:
                why = ("later fragment of a line she trailed off on"
                       if i > keeper else "earlier take of a line said again later")
            dropped.append({**sentences[i], "reason": why})
    # A line she trailed off on and then kept talking past is an abandoned take, whether or not
    # anything nearby resembles it enough to cluster. Restricted to lines she talked past: the
    # last thing on the tape may simply be where the camera stopped.
    already = {d["start"] for d in dropped}
    for pos, (i, a) in enumerate(usable):
        if a["start"] in already or is_complete(a["text"]):
            continue
        nxt = next((b for _, b in usable[pos + 1:] if b["start"] - a["end"] <= window_seconds),
                   None)
        if nxt is not None:
            dropped.append({**a, "reason": "abandoned mid-sentence, then said again"})

    return sorted(dropped, key=lambda d: d["start"])


# --------------------------------------------------------------------------------------
# Pass 2 — fillers
# --------------------------------------------------------------------------------------

def find_fillers(words: list[dict], min_gap_around: float = 0.12) -> list[dict]:
    """
    Only remove a filler when it is *isolated* — surrounded by small gaps. A filler word
    tucked mid-phrase can't be excised without a click, and the seam costs more than the
    word does.
    """
    out: list[dict] = []
    singles = {f for f in C.FILLER_WORDS if " " not in f}
    for i, w in enumerate(words):
        if norm(w["word"]) not in singles:
            continue
        gap_before = w["start"] - words[i - 1]["end"] if i else 99.0
        gap_after = words[i + 1]["start"] - w["end"] if i + 1 < len(words) else 99.0
        if gap_before >= min_gap_around or gap_after >= min_gap_around:
            out.append({"start": w["start"], "end": w["end"], "text": w["word"], "reason": "filler"})
    return out


# --------------------------------------------------------------------------------------
# Pass 3 — dead air, with the breath floor
# --------------------------------------------------------------------------------------

def voiced_spans(src: Path, duration: float | None = None) -> list[tuple[float, float]]:
    """
    Where the audio actually carries voice — measured, not inferred from the transcript.

    [S-024]: every silence decision in this file used to be read off gaps in the word list,
    which classifies anything WhisperX failed to transcribe as silence. Three false starts
    survived the intro of the first real clip that way: full-level, plainly audible, and
    invisible to a function that only ever looked at words.
    """
    proc = subprocess.run(
        ["ffmpeg", "-v", "info", "-i", str(src), "-af",
         f"highpass=f={C.VOICE_HIGHPASS_HZ},lowpass=f={C.VOICE_BAND_TOP_HZ},"
         f"silencedetect=n={C.SILENCE_THRESHOLD_DB}dB:d={C.SILENCE_MIN_MS / 1000.0}",
         "-f", "null", "-"],
        capture_output=True, text=True)
    starts = [float(x) for x in re.findall(r"silence_start: (-?[\d.]+)", proc.stderr)]
    ends = [float(x) for x in re.findall(r"silence_end: (-?[\d.]+)", proc.stderr)]

    spans: list[tuple[float, float]] = []
    cursor = 0.0
    for s, e in zip(starts, ends):          # a trailing start with no end = silent to EOF
        if s > cursor:
            spans.append((cursor, s))
        cursor = max(cursor, e)
    if duration and duration > cursor:
        spans.append((cursor, duration))
    return spans


def find_buried_takes(words: list[dict],
                      voiced: list[tuple[float, float]] | None) -> list[dict]:
    """
    A whole take can hide inside a single transcribed word.

    [S-026]: WhisperX gave the intro one token — "I'm" — spanning 2.0 seconds and four separate
    voiced bursts. The audio is "I'm Katie, I'm a foo—"; the transcript is one short word. Every
    check upstream reads the transcript, so the cut scored clean while the take was still in it.

    A word running far below her speaking rate *and* containing more than one voiced run is not
    a word. She restarts and then delivers, so the real word is the last run; everything before
    it is the discarded attempt.
    """
    out: list[dict] = []
    if not voiced:
        return out
    breath = C.BREATH_SENTENCE_MS / 1000.0
    for w in words:
        dur = w["end"] - w["start"]
        chars = len(w["word"].strip(string.punctuation + string.whitespace))
        if dur < C.BURIED_TAKE_MIN_S or not chars:
            continue
        if chars / dur > C.BURIED_TAKE_CHARS_PER_S:
            continue
        runs = [(s, e) for s, e in voiced if e > w["start"] and s < w["end"]]
        if len(runs) < 2:
            continue                    # one run is just a drawn-out word, which she does
        out.append({
            "start": w["start"],
            "end": max(w["start"], runs[-1][0] - breath),
            "reason": (f"{len(runs) - 1} take(s) buried inside a {dur:.1f}s {w['word']!r} — "
                       "WhisperX collapsed them into one token"),
            "text": "",
        })
    return out


def find_dead_air(words: list[dict], duration: float | None = None,
                  tight: bool = False,
                  voiced: list[tuple[float, float]] | None = None) -> list[dict]:
    """
    Shorten long gaps — but never past the breath floor.

    `voiced` is the measured speech from voiced_spans(). Passing None means the audio was
    never consulted, which is a different fact from "consulted and clean" — build_edl records
    which of the two happened rather than letting them share a representation.

    Gap shorter than MIN_SILENCE_TO_CUT_MS -> untouched.
    Longer -> trimmed down to a breath (150 ms mid-sentence, 250 ms at an idea boundary),
    never to zero.

    The head and tail are gaps too. Looking only *between* words leaves whatever sits before
    the first word and after the last one untouched — on the first real clip that was 21
    seconds of nobody speaking, kept in full as the opening shot.
    """
    out: list[dict] = []

    if words:
        lead = words[0]["start"]
        if lead * 1000.0 > C.BREATH_PARAGRAPH_MS + C.BREATH_FLOOR_MS:
            out.append({"start": 0.0,
                        "end": lead - C.BREATH_PARAGRAPH_MS / 1000.0,
                        "reason": f"lead-in ({lead:.1f}s before the first word)", "text": ""})
        if duration is not None:
            tail = duration - words[-1]["end"]
            if tail * 1000.0 > C.BREATH_PARAGRAPH_MS + C.BREATH_FLOOR_MS:
                out.append({"start": words[-1]["end"] + C.BREATH_PARAGRAPH_MS / 1000.0,
                            "end": duration,
                            "reason": f"tail ({tail:.1f}s after the last word)", "text": ""})

    for i in range(len(words) - 1):
        gap_start, gap_end = words[i]["end"], words[i + 1]["start"]
        gap_ms = (gap_end - gap_start) * 1000.0
        if gap_ms < C.MIN_SILENCE_TO_CUT_MS:
            continue

        boundary = bool(PUNCT_END.search(words[i]["word"]))
        keep_ms = C.BREATH_PARAGRAPH_MS if boundary else C.BREATH_SENTENCE_MS
        if tight:
            # Everything down to the floor and not one millisecond below it. [S-002] is the
            # one thing a length target is never allowed to buy its way past.
            keep_ms = C.BREATH_FLOOR_MS
        keep_ms = max(keep_ms, C.BREATH_FLOOR_MS)
        breath = keep_ms / 2000.0

        # Voiced audio inside a word gap is not dead air — it is a false start WhisperX never
        # turned into a word. Only runs wholly inside the gap count: one that touches either
        # edge is the neighbouring word, whose onset WhisperX routinely clips. [S-024]
        runs = [(s, e) for s, e in (voiced or []) if e > gap_start and s < gap_end]
        stumbles = [(s, e) for s, e in runs
                    if s > gap_start and e < gap_end
                    and (e - s) * 1000.0 >= C.UNTRANSCRIBED_MIN_MS]
        if stumbles:
            # Breathe from where the voice stops, not where the transcript says the word ended,
            # or the trim eats the consonant off the front of the next word.
            head = max([e for s, e in runs if s <= gap_start] or [gap_start])
            tail = min([s for s, e in runs if e >= gap_end] or [gap_end])
            out.append({
                "start": min(head + breath, stumbles[0][0]),
                "end": max(tail - breath, stumbles[-1][1]),
                "reason": (f"{len(stumbles)} false start(s) before {words[i + 1]['word']!r} "
                           f"— voiced, never transcribed"),
                "text": "",
            })
            continue

        removable_ms = gap_ms - keep_ms
        if removable_ms <= C.BREATH_FLOOR_MS:
            continue

        # Trim from the middle so both the outgoing and incoming breath stay natural.
        half = (removable_ms / 2000.0)
        mid = (gap_start + gap_end) / 2.0
        out.append(
            {
                "start": mid - half,
                "end": mid + half,
                "reason": f"dead air ({gap_ms:.0f}ms → {keep_ms:.0f}ms breath)",
                "text": "",
            }
        )
    return out


# --------------------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------------------

def merge_drops(drops: list[dict]) -> list[Drop]:
    if not drops:
        return []
    ordered = sorted(drops, key=lambda d: d["start"])
    merged = [Drop(ordered[0]["start"], ordered[0]["end"], ordered[0]["reason"], ordered[0].get("text", ""))]
    for d in ordered[1:]:
        last = merged[-1]
        if d["start"] <= last.end + 0.01:
            last.end = max(last.end, d["end"])
            if d["reason"] not in last.reason:
                last.reason += f" + {d['reason']}"
        else:
            merged.append(Drop(d["start"], d["end"], d["reason"], d.get("text", "")))
    return merged


def collapse_breath_runs(keeps: list[Keep], words: list[dict],
                         voiced: list[tuple[float, float]] | None = None) -> list[Keep]:
    """
    A run of consecutive wordless keeps becomes one breath, taken from one place.

    When three takes in a row are dropped, the breaths *between* them all survive. The audio is
    fine — they concatenate into one continuous stretch of room tone, which is what [S-002]
    wants under a cut. The picture is not: each fragment is a different moment, so she jumps
    position two or three times inside half a second while the sound flows straight through.
    That reads as a glitch rather than as an edit, and measuring only the audio is how it got
    past the first pass.

    One pause deserves one breath. Keeping the last fragment of a run keeps the breath adjacent
    to the take that follows it, still above the [S-002] floor, and leaves a single cut instead
    of four.
    """
    if not keeps:
        return keeps

    def has_speech(k: Keep) -> bool:
        return any(k.start <= (w["start"] + w["end"]) / 2 < k.end for w in words)

    speech = [has_speech(k) for k in keeps]
    out: list[Keep] = []
    pending = 0.0                       # breath owed to the next line
    for k, spoken in zip(keeps, speech):
        if not spoken:
            pending += k.duration       # collect it; don't emit it as its own shot
            continue
        if pending:
            # Give the breath to the take it leads into, by starting that take earlier. The
            # silence immediately before a line is in the same shot as the line, so the breath
            # costs no extra cut — where a standalone fragment is a third camera position
            # between two takes and reads as a glitch.
            # ...but only back into silence. The take before a kept one is usually a discarded
            # attempt at the same line, and reaching into it drags in its final word — the
            # first cut opened on a stray "action." from take three of four.
            # The floor is the last moment voice was *heard*, not the last word transcribed.
            # Taking it from the word list walks the take back over the false starts
            # find_dead_air just removed and puts them straight back in. [S-024]
            spoken_before = max((x["end"] for x in words if x["end"] <= k.start), default=0.0)
            heard_before = max((e for _, e in (voiced or []) if e <= k.start), default=0.0)
            floor = max(spoken_before, heard_before, out[-1].end if out else 0.0)
            room = k.start - floor
            k = Keep(k.start - min(pending, max(0.0, room)), k.end, k.reason, k.text)
            pending = 0.0
        out.append(k)
    return out


def build_edl(meta: dict, words: list[dict], aggressive: bool,
              target_seconds: float | None = None, tight: bool = False,
              voiced: list[tuple[float, float]] | None = None,
              extra_drops: list[dict] | None = None) -> EDL:
    sentences = group_sentences(words)
    raw_drops: list[dict] = list(extra_drops or [])

    takes = find_repeated_takes(sentences)
    raw_drops += takes

    fillers = find_fillers(words) if aggressive else []
    raw_drops += fillers

    duration = meta.get("duration") or (max(w["end"] for w in words) + 0.5)
    dead = find_dead_air(words, duration, tight, voiced)
    raw_drops += dead

    buried = find_buried_takes(words, voiced)
    raw_drops += buried

    drops = merge_drops(raw_drops)

    # Invert drops into keeps.
    keeps: list[Keep] = []
    cursor = 0.0
    for d in drops:
        s = snap_to_frame(d.start, "ceil")
        if s > cursor:
            keeps.append(Keep(snap_to_frame(cursor, "floor"), s))
        cursor = max(cursor, snap_to_frame(d.end, "floor"))
    if cursor < duration:
        keeps.append(Keep(snap_to_frame(cursor, "floor"), snap_to_frame(duration, "ceil")))

    # Drop keeps too short to be a real shot — a 3-frame island is a glitch, not an edit.
    keeps = [k for k in keeps if k.duration >= 4 / C.FPS]
    keeps = collapse_breath_runs(keeps, words, voiced)

    edl = EDL(clip=meta["clip"], source=meta["source"], fps=C.FPS, keeps=keeps, drops=drops)
    edl.stats = {  # type: ignore[attr-defined]
        "repeated_takes": len(takes),
        "fillers": len(fillers),
        "dead_air": len(dead),
        "false_starts": sum(1 for d in dead if "false start" in d["reason"]),
        "buried_takes": len(buried),
        # "not measured" and "measured, none found" are different facts and never share a value.
        "audio_checked": voiced is not None,
    }

    # A length target tightens breath toward the floor and stops there. Beyond that, hitting a
    # number means deciding which of her lines to lose, and that is an editorial call the
    # pipeline is not entitled to make — so it reports the shortfall instead of inventing one.
    if target_seconds and edl.cut_duration > target_seconds and not tight:
        tighter = build_edl(meta, words, aggressive, target_seconds, True, voiced, extra_drops)
        if tighter.cut_duration < edl.cut_duration:
            tighter.stats["tightened_from"] = round(edl.cut_duration, 2)  # type: ignore[attr-defined]
            edl = tighter
    if target_seconds:
        edl.stats["target"] = target_seconds                              # type: ignore[attr-defined]
        edl.stats["over_target"] = round(edl.cut_duration - target_seconds, 2)  # type: ignore
    return edl


def to_fcpxml(src: Path, edl: EDL, out: Path, project: str) -> Path:
    """
    The real Stage 2 deliverable: a Final Cut timeline with the cuts already made.

    Not a flattened render — every cut stays a real edit point she can slip, roll, or undo.
    Each removed span leaves a marker at the join so she can see what the pipeline took out
    and put it back if it was wrong.
    """
    import fcpxml as FX

    clips: list[FX.Clip] = []
    timeline = 0.0
    for i, k in enumerate(edl.keeps):
        clips.append(FX.Clip(
            asset_path=src,
            offset=C.snap_seconds(timeline),
            start=C.snap_seconds(k.start),
            duration=C.snap_seconds(k.duration),
            name=f"{src.stem} {i+1:02d}",
            role=C.ROLE_VIDEO,
        ))
        timeline += k.duration

    # Annotate each join with what was removed there, so she can see the pipeline's reasoning
    # at the cut point and put anything back that shouldn't have gone.
    joins = 0
    for i, clip in enumerate(clips):
        if i == 0:
            continue
        prev_out = edl.keeps[i - 1].end
        gap = next((d for d in edl.drops if abs(d.start - prev_out) < 0.25), None)
        if gap:
            clip.markers.append((clip.offset, f"cut −{gap.duration:.1f}s · {gap.reason}", True))
            joins += 1

    builder = FX.FCPXMLBuilder(project=f"{project} — rough cut", aspect=C.DEFAULT_ASPECT)
    tree = builder.build(clips, connected=[])
    builder.write(tree, out)

    problems = FX.validate(out)
    if problems:
        print(f"  ! FCPXML validation: {len(problems)} issue(s)")
        for p in problems[:5]:
            print(f"      {p}")
    return out, joins


def voice_chain(pre_db: float, post_db: float) -> str:
    """
    The taste_principles §8 dialogue chain — high-pass, 3:1 compression, light limiting.

    Compression is what actually answers "make it louder". The integrated level is already on
    target, so more gain only eats headroom; what reads as quiet is the *distance* between her
    loudest and quietest delivery. Pulling that in raises the quiet half and leaves the program
    where the channel masters it.

    Two gains, not one. The compressor only engages if the signal reaches its threshold, and her
    source runs about -56 dB, so it has to be brought up to working level first (`pre_db`);
    compressing then changes the loudness again, so a second static trim puts the program back
    on target (`post_db`). Both measured, neither dialled in.
    """
    return (f"highpass=f={C.VOICE_HIGHPASS_HZ},volume={pre_db:.2f}dB,"
            f"acompressor=threshold={C.COMP_THRESHOLD_DB}dB:ratio={C.COMP_RATIO}"
            f":attack={C.COMP_ATTACK_MS}:release={C.COMP_RELEASE_MS}:knee={C.COMP_KNEE_DB},"
            f"volume={post_db:.2f}dB")


def integrated_lufs(path: Path) -> float:
    """Integrated loudness of a file, from ffmpeg's own EBU R128 meter."""
    proc = subprocess.run(["ffmpeg", "-v", "info", "-i", str(path), "-af",
                           "ebur128=framelog=verbose", "-f", "null", "-"],
                          capture_output=True, text=True)
    match = re.findall(r"I:\s*(-?\d+\.\d+) LUFS", proc.stderr)
    if not match:
        raise RuntimeError(f"could not measure loudness of {path.name}")
    return float(match[-1])


def render_cut_audio(src: Path, edl: EDL, out: Path) -> Path:
    """The cut's audio and nothing else — what a viewer's ears actually receive."""
    out.parent.mkdir(parents=True, exist_ok=True)
    cuts = ";".join(f"[0:a]atrim=start={k.start}:end={k.end},asetpts=PTS-STARTPTS[c{i}]"
                    for i, k in enumerate(edl.keeps))
    graph = (cuts + ";" + "".join(f"[c{i}]" for i in range(len(edl.keeps)))
             + f"concat=n={len(edl.keeps)}:v=0:a=1[cut]")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(src), "-filter_complex", graph,
                    "-map", "[cut]", "-ar", "16000", "-ac", "1", str(out)], check=True)
    return out


def verify_cut(src: Path, edl: EDL, workdir: Path) -> tuple[list[str], list[str]]:
    """
    Transcribe the *cut* and read that, rather than reading the transcript it was built from.

    [S-026]: every check in this file read the input transcript, so every check inherited its
    mistakes. WhisperX collapsed a failed take into a single 2.0 s "I'm"; the script printed a
    clean sentence and the audio still had "I'm Katie, I'm a foo—" in it. Nathan heard it. The
    only description of the cut that cannot inherit an upstream error is one taken *from the
    cut*, so this re-transcribes the rendered audio and runs the same read-through over it.

    Returns (lines, problems) with the lines timed on the *cut* timeline.
    """
    import stage1_transcribe as S1

    wav = render_cut_audio(src, edl, workdir / f"{Path(edl.clip).stem}.verify.wav")
    try:
        result = S1.transcribe(wav)
        heard = [dataclasses.asdict(w) for w in S1.flatten_words(result)]
    finally:
        wav.unlink(missing_ok=True)
    lines = group_sentences(heard)
    return lines, read_through(lines)


def drops_from_readback(edl: EDL, heard: list[dict]) -> list[dict]:
    """
    Take what the read-back heard twice and put it back in source time, so it can be cut.

    The read-back is timed on the finished cut; drops are expressed in source time. Anything
    that skips this conversion lands in the wrong place — the mistake CLAUDE.md warns about
    twice over. The *earlier* of a duplicated pair goes, matching the keeper rule everywhere
    else in this file: she restarts and then delivers. [S-026]
    """
    from fcpxml import TimelineMap

    tmap = TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])
    out: list[dict] = []
    for i, why in duplicate_lines(heard):
        line = heard[i]
        for s, e in tmap.source_ranges(line["start"], line["end"]):
            out.append({"start": s, "end": e,
                        "reason": f"heard twice on read-back — {why}", "text": line["text"]})
    return out


def render_preview(src: Path, edl: EDL, out: Path, crf: int = 20,
                   music: Path | None = None,
                   loudness: float = C.TARGET_LUFS) -> Path:
    """
    Optional flattened preview, for checking pacing without opening FCP.
    Never the deliverable — see to_fcpxml().

    A bed can be laid under it for judging feel. It is placed by measuring the *cut* voice, not
    the source: the cut is 82% shorter and drops the loudest run-ups, so a gain derived from the
    original sits in the wrong place. Music never reaches the FCPXML — where the bed sits, and
    against which take, is a decision for the timeline.
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    parts, streams = [], []
    for i, k in enumerate(edl.keeps):
        parts.append(
            f"[0:v]trim=start={k.start}:end={k.end},setpts=PTS-STARTPTS[v{i}];"
            f"[0:a]atrim=start={k.start}:end={k.end},asetpts=PTS-STARTPTS[a{i}]"
        )
        streams.append(f"[v{i}][a{i}]")
    graph = ";".join(parts) + ";" + "".join(streams) + f"concat=n={len(edl.keeps)}:v=1:a=1[v][a]"

    amap = "[a]"
    inputs = ["-i", str(src)]
    if music is not None:
        from music import MUSIC_UNDER_DB, bed_gain, bed_filter

        # Audio-only graph: ffmpeg refuses a filtergraph with an unconnected output, so the
        # measurement passes cannot reuse the one that also carries picture.
        cuts = ";".join(f"[0:a]atrim=start={k.start}:end={k.end},asetpts=PTS-STARTPTS[m{i}]"
                        for i, k in enumerate(edl.keeps))
        voice_graph = (cuts + ";" + "".join(f"[m{i}]" for i in range(len(edl.keeps)))
                       + f"concat=n={len(edl.keeps)}:v=0:a=1")
        voice = out.with_suffix(".voice.wav")

        def render_voice(chain: str = "") -> float:
            graph_a = voice_graph + (f",{chain}" if chain else "") + "[voice]"
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(src),
                            "-filter_complex", graph_a, "-map", "[voice]", str(voice)],
                           check=True)
            return integrated_lufs(voice)

        # Bring her level up to where the compressor's threshold means something, compress, then
        # measure again and correct — the compressor moves the loudness it was handed.
        pre = loudness - render_voice()
        post = loudness - render_voice(voice_chain(pre, 0.0))
        chain = voice_chain(pre, post)

        # The bed sits under the *processed* voice, so that is what it is measured against.
        render_voice(chain)
        gain = bed_gain(voice, music, MUSIC_UNDER_DB)
        voice.unlink()

        inputs += ["-i", str(music)]
        graph += (f";[a]{chain}[vox]" + ";" + bed_filter(gain, edl.cut_duration)
                  + ";[vox][bed]amix=inputs=2:duration=first:normalize=0,"
                  # level=false matters: alimiter auto-levels its output by default, which put
                  # the preview 2 dB over the channel target and its true peak 1.2 dB over the
                  # ceiling — a limiter silently acting as a normaliser. The ceiling is set half
                  # a dB under the -1.5 dBTP the rubric asks for, because AAC overshoots what
                  # the limiter hands it and the number that matters is the one in the file.
                  + f"alimiter=limit={C.PREVIEW_LIMIT_DBTP:.1f}dB:level=false[mix]")
        print(f"    voice: high-pass {C.VOICE_HIGHPASS_HZ} Hz, {C.COMP_RATIO:.0f}:1 at "
              f"{C.COMP_THRESHOLD_DB:.0f} dB, {pre:+.1f} dB in / {post:+.1f} dB out "
              f"(§8 dialogue chain) → {loudness:.0f} LUFS")
        amap = "[mix]"
        print(f"    bed {20 * math.log10(gain):+.1f} dB ({MUSIC_UNDER_DB:.0f} dB under the "
              f"compressed cut voice, measured 200 Hz–4 kHz): {music.name}")

    cmd = [
        "ffmpeg", "-y", *inputs,
        "-filter_complex", graph,
        "-map", "[v]", "-map", amap,
        "-c:v", "libx264", "-crf", str(crf), "-preset", "medium",
        "-pix_fmt", "yuv420p", "-r", C.FPS_STR,
        "-c:a", "aac", "-b:a", "192k",
        str(out),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"preview render failed:\n{proc.stderr[-1200:]}")

    # Measure the encoded file, not the graph that produced it. AAC overshoots the limiter by an
    # amount that depends on the material — 0.1 dB on one cut and 0.8 dB on the next, which is
    # how a ceiling picked from a single render drifted out of spec unnoticed. [S-026]
    measured = measure(out)
    lufs, peak = measured["lufs"], measured["peak"]
    print(f"    measured: {lufs:+.1f} LUFS, true peak {peak:+.1f} dBFS", end="")
    ok = (abs(lufs - loudness) <= C.LUFS_TOLERANCE and peak <= C.TRUE_PEAK_MAX_DBTP)
    print("" if ok else "   ← OUT OF SPEC")
    return out, lufs, peak


def measure(path: Path) -> dict[str, float]:
    """Integrated loudness and true peak of a finished file, from ffmpeg's EBU R128 meter."""
    proc = subprocess.run(["ffmpeg", "-v", "info", "-i", str(path), "-af",
                           "ebur128=peak=true:framelog=verbose", "-f", "null", "-"],
                          capture_output=True, text=True)
    lufs = re.findall(r"I:\s*(-?\d+\.\d+) LUFS", proc.stderr)
    peak = re.findall(r"Peak:\s*(-?\d+\.\d+) dBFS", proc.stderr)
    if not lufs or not peak:
        raise RuntimeError(f"could not measure {path.name}")
    return {"lufs": float(lufs[-1]), "peak": float(peak[-1])}


def write_edl(edl: EDL, path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "clip": edl.clip,
        "source": edl.source,
        "fps": edl.fps,
        "breath_floor_ms": C.BREATH_FLOOR_MS,
        "source_duration": round(edl.source_duration, 3),
        "cut_duration": round(edl.cut_duration, 3),
        "removed_seconds": round(edl.source_duration - edl.cut_duration, 3),
        "stats": getattr(edl, "stats", {}),
        "keeps": [{"start": k.start, "end": k.end} for k in edl.keeps],
        "drops": [
            {"start": round(d.start, 3), "end": round(d.end, 3),
             "reason": d.reason, "text": d.text[:120]}
            for d in edl.drops
        ],
    }
    path.write_text(json.dumps(payload, indent=2))
    return path


def cut_script(words: list[dict], edl) -> list[dict]:
    """The lines the finished video actually says, in order, reconstructed from the EDL."""
    from fcpxml import TimelineMap          # deferred, as in to_fcpxml()

    tmap = TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])
    kept = [w for w in words if tmap.to_timeline((w["start"] + w["end"]) / 2) is not None]
    return group_sentences(kept)


def duplicate_lines(lines: list[dict]) -> list[tuple[int, str]]:
    """
    Consecutive lines that say the same thing twice, at any length.

    RETAKE_RUN_WORDS is tuned to spot a long passage restarted mid-flow. It cannot see
    "I'm Katie." said twice in a row — four words in total, and unmistakably a defect.
    Returns (index of the earlier line, why). [S-026]
    """
    out: list[tuple[int, str]] = []
    for i, (a, b) in enumerate(zip(lines, lines[1:])):
        na, nb = norm(a["text"]), norm(b["text"])
        if not na or not nb:
            continue
        run = longest_shared_run(na, nb)
        if na == nb or is_fragment(na, nb):
            out.append((i, f"says {a['text']!r} and then {b['text']!r} — the same line twice"))
        elif run >= C.RETAKE_RUN_WORDS:
            shared = " ".join(nb.split()[:run])
            out.append((i, f"repeats {run} words verbatim from the line before it — "
                           f"two takes both survived (…{shared}…)"))
    return out


def join_paused_lines(lines: list[dict]) -> list[dict]:
    """
    Put back together the sentences a pause split in half.

    `group_sentences` ends a line at terminal punctuation *or* at a gap over a second, because
    it also has to cope with speech the punctuation never arrives for. On a scripted read those
    two agree. On her unscripted delivery they do not: she thinks mid-sentence, and every one of
    those thinking pauses becomes a line with no full stop on the end — which is indistinguishable
    from trailing off if each line is read on its own.

    A continuation is a line that starts lower-case after a line that has not finished. That is a
    breath, not an abandoned take, and it must not be reported as one: a check that fires 28 times
    on one cut and is wrong 28 times is not a strict check, it is an ignored one.

    What it deliberately does not merge is a line starting with a capital, which is where a
    restart lives — "…and there's other records from" / "And there are other records from all
    over Asia" is the [S-021] defect, and it stays visible.
    """
    joined: list[dict] = []
    for line in lines:
        prev = joined[-1] if joined else None
        head = line["text"].lstrip()[:1]
        if prev and head and head.islower() and not is_complete(prev["text"]):
            prev["text"] = f"{prev['text']} {line['text']}"
            prev["end"] = line["end"]
        else:
            joined.append(dict(line))
    return joined


def read_through(lines: list[dict]) -> list[str]:
    """
    Read the cut as prose and report what a viewer would hear as a mistake.

    Every acceptance check on this stage measured timing — clip counts, durations, the frame
    grid, the breath floor — and every one of them passed on a cut whose last third said Egypt
    twice, said "we do know that there are records" three times, and ended on a comma. Numbers
    about the shape of the edit say nothing about whether it makes sense out loud, and that is
    the only thing the viewer receives. So the script gets read, mechanically, every run.

    It reads *sentences*, not lines — see join_paused_lines() for why those differ.
    """
    read = join_paused_lines(lines)
    problems: list[str] = []
    for i, why in duplicate_lines(read):
        problems.append(f"{read[i + 1]['start']:.1f}s {why}")
    for line in read:
        if not is_complete(line["text"]):
            problems.append(f"{line['start']:.1f}s ends mid-sentence: …{line['text'][-46:]!r}")
    return problems


def main(argv: list[str] | None = None) -> int:
    from music import MUSIC_UNDER_DB       # the level and its band travel together — [S-022]

    failed = False
    cli.preflight()
    ap = argparse.ArgumentParser(description="Stage 2 — rough cut with a breath floor")
    ap.add_argument("transcripts", nargs="*", help="*.words.json; default = all in build/transcripts")
    ap.add_argument("--aggressive", action="store_true", help="also remove isolated filler words")
    ap.add_argument("--loudness", type=float, default=C.TARGET_LUFS,
                    help=f"preview program loudness in LUFS (default {C.TARGET_LUFS:.0f}, the "
                         "channel master target from §8). YouTube normalises to about -14, so "
                         "a master at -16 plays quieter than what surrounds it — pass -14 to "
                         "judge the preview at playback level.")
    ap.add_argument("--music", type=Path, default=None,
                    help=f"music bed for the preview, placed {MUSIC_UNDER_DB:.0f} dB under the "
                         "cut voice in the 200 Hz–4 kHz band "
                         "(preview only — never reaches the FCPXML)")
    ap.add_argument("--preview", action="store_true",
                    help="also render a flattened preview mp4 (not the deliverable)")
    ap.add_argument("--no-render", action="store_true", help="write the EDL only, no FCPXML")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip transcribing the finished cut and reading it back. The read-back "
                         "is the only check that does not inherit the input transcript's "
                         "mistakes, so skipping it leaves the cut unverified, not approved")
    ap.add_argument("--target", type=float, metavar="SECONDS",
                    help="wanted runtime; tightens breath toward the [S-002] floor and reports "
                         "any shortfall rather than cutting her lines to hit a number")
    ap.add_argument("--project", default="video001")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    paths = (
        [cli.resolve_or_exit(p, expect=(".json",), label='transcript')
         for p in args.transcripts]
        if args.transcripts
        else sorted(C.TRANSCRIPTS.glob("*.words.json"))
    )
    if not paths:
        print("! no transcripts found — run stage 1 first")
        return 1

    print(f"Stage 2 — rough cut on {len(paths)} clip(s)  (breath floor {C.BREATH_FLOOR_MS} ms)")
    for tp in paths:
        meta, words = load_words(tp)
        if not words:
            print(f"  ! {tp.name} has no words, skipping")
            continue

        # The transcript cannot tell us what she said and WhisperX missed, so ask the audio.
        src = C.ROOT / meta["source"]
        if not src.exists():
            print(f"  ! {meta['source']} not found — cannot check for untranscribed false "
                  f"starts. Restore the source next to build/ and re-run stage 2.")
            failed = True
            continue
        voiced = voiced_spans(src, meta.get("duration"))

        edl = build_edl(meta, words, args.aggressive, args.target, voiced=voiced)
        removed = edl.source_duration - edl.cut_duration
        pct = (removed / edl.source_duration * 100) if edl.source_duration else 0
        s = getattr(edl, "stats", {})
        print(
            f"→ {meta['clip']}: {edl.source_duration:.1f}s → {edl.cut_duration:.1f}s "
            f"(−{removed:.1f}s, {pct:.0f}%) · {len(edl.keeps)} segments · "
            f"{s.get('repeated_takes',0)} retakes, {s.get('fillers',0)} fillers, "
            f"{s.get('dead_air',0)} gaps, {s.get('false_starts',0)} false starts"
        )
        if s.get("target"):
            over = s["over_target"]
            if s.get("tightened_from"):
                print(f"  breath tightened to the {C.BREATH_FLOOR_MS} ms floor: "
                      f"{s['tightened_from']:.1f}s → {edl.cut_duration:.1f}s")
            print(f"  target {s['target']:.0f}s — "
                  + (f"over by {over:.1f}s; the rest is an editorial call"
                     if over > 0 else f"under by {-over:.1f}s"))

        if args.dry_run:
            continue

        stem = tp.stem.replace(".words", "")
        write_edl(edl, C.ROUGHCUT / f"{stem}.edl.json")

        lines = cut_script(words, edl)
        script = C.ROUGHCUT / f"{stem}.script.txt"
        script.write_text("\n".join(x["text"] for x in lines) + "\n", encoding="utf-8")
        print(f"\n  reads as ({len(lines)} lines, {script.relative_to(C.ROOT)}):")
        for x in lines:
            print(f"    {x['text']}")
        # Provisional: this reads the *input* transcript, so it inherits that transcript's
        # mistakes in both directions — it missed a whole take buried inside one token, and it
        # calls a line unfinished that WhisperX merely mistimed. The read-back below is the
        # authority; this runs first because it is free and catches the obvious early. [S-026]
        problems = read_through(lines)
        if problems:
            print(f"\n  the input transcript reads badly here — {len(problems)} note(s), "
                  f"pending read-back:")
            for problem in problems:
                print(f"    - {problem}")

        # The read-through above is over the *input* transcript, so it inherits that
        # transcript's mistakes — a take buried inside one long token reads as a clean
        # sentence. Listening to the cut is the only description of it that cannot. [S-026]
        if args.no_verify:
            # Without the read-back the input transcript is all there is, so it has to gate —
            # and a run that skipped the only authoritative check is not an approved cut.
            if problems:
                print("    ...and --no-verify means nothing checked them against the audio.")
                failed = True
        else:
            extra: list[dict] = []
            for attempt in range(C.READBACK_MAX_PASSES):
                print(f"  listening back{'' if not attempt else f' (pass {attempt + 1})'}…")
                try:
                    heard, heard_problems = verify_cut(src, edl, C.ROUGHCUT)
                except Exception as exc:  # noqa: BLE001
                    print(f"  ! could not listen back: {exc}")
                    print("    The cut is UNVERIFIED — which is not the same as clean.")
                    failed = True
                    break

                again = drops_from_readback(edl, heard)
                if again and attempt + 1 < C.READBACK_MAX_PASSES:
                    for d in again:
                        print(f"    heard twice: {d['text']!r} — cutting it and re-reading")
                    extra += again
                    edl = build_edl(meta, words, args.aggressive, args.target,
                                    voiced=voiced, extra_drops=extra)
                    write_edl(edl, C.ROUGHCUT / f"{stem}.edl.json")
                    continue

                verify_path = C.ROUGHCUT / f"{stem}.heard.txt"
                verify_path.write_text("\n".join(x["text"] for x in heard) + "\n",
                                       encoding="utf-8")
                print(f"  what it actually says ({verify_path.relative_to(C.ROOT)}):")
                for line in heard:
                    print(f"    {line['text']}")
                if heard_problems:
                    print(f"\n  ! the cut does not survive its own read-back — "
                          f"{len(heard_problems)} problem(s):")
                    for problem in heard_problems:
                        print(f"    - {problem}")
                    failed = True
                break
        print()

        if args.no_render:
            continue

        src = C.ROOT / meta["source"]
        if not src.exists():
            print(f"  ! source missing: {meta['source']} — EDL written, FCPXML skipped")
            continue

        try:
            fx, joins = to_fcpxml(src, edl, C.ROUGHCUT / f"{stem}.roughcut.fcpxml", args.project)
            print(f"  ✓ {fx.relative_to(C.ROOT)}  ({len(edl.keeps)} clips, {joins} joins marked)")
            print("    File ▸ Import ▸ XML… in Final Cut")
        except Exception as exc:  # noqa: BLE001
            print(f"  ! FCPXML failed: {exc}", file=sys.stderr)

        if args.preview:
            out = C.ROUGHCUT / f"{src.stem}.preview.mp4"
            try:
                _, lufs, peak = render_preview(src, edl, out, music=args.music,
                                               loudness=args.loudness)
                print(f"  ✓ {out.relative_to(C.ROOT)} (preview only)")
                if abs(lufs - args.loudness) > C.LUFS_TOLERANCE:
                    print(f"  ! preview is {lufs:.1f} LUFS, wanted {args.loudness:.1f} "
                          f"±{C.LUFS_TOLERANCE:.1f}")
                    failed = True
                if peak > C.TRUE_PEAK_MAX_DBTP:
                    print(f"  ! preview true peak {peak:.1f} dBFS is over the "
                          f"{C.TRUE_PEAK_MAX_DBTP:.1f} dBFS ceiling (§8)")
                    failed = True
            except Exception as exc:  # noqa: BLE001
                print(f"  ! preview failed: {exc}", file=sys.stderr)

    if failed:
        print("Stage 2 finished with a cut that does not read cleanly", file=sys.stderr)
        return 1
    print("Stage 2 complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
