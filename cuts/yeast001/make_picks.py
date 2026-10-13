"""
make_picks.py — the editorial pass for Yeast 001, as a list a person can argue with.

Every row is one take chosen from the 46 minutes of a-cam: which clip, the first and last word
kept, and why. Cut points are word boundaries from the Stage 1 transcripts, padded into the
silence either side so a join lands on breath rather than on a consonant — never below the
[S-002] floor, never more than the silence that was actually there.

    ./run cuts/yeast001/make_picks.py        # writes cuts/yeast001/picks.json
    ./run tools/assemble.py cuts/yeast001/picks.json --preview
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import config as C  # noqa: E402

A = "footage/a-cam"
B = "footage/broll"

PAD_IN, PAD_OUT = 0.08, 0.12        # seconds of breath to keep either side of a take
MIN_GAP = C.BREATH_FLOOR_MS / 1000
# A pause inside a take longer than this is trimmed to BREATH — a paragraph breath, not zero
# [S-002]. 0.7 s leaves her natural rhythm alone and takes out the stretches where she is
# finding the next thought.
PAUSE_TRIM_S = 0.7
BREATH = C.BREATH_PARAGRAPH_MS / 1000

GRADE = {
    # Baked by tools/lut.py from: curves (midtone lift, highlights rolled to 0.965),
    # colorbalance (warmer mids and shadows), saturation ×1.35. Apply in Final Cut with the
    # Custom LUT effect on every a-cam clip; the preview uses the same file.
    "lut": "assets/luts/yeast001-grade.cube",
    # Preview-only: a soft-light ellipse over her head and shoulders, +~8% luminance. In
    # Final Cut this is a Color Board exposure lift inside a shape mask, same place.
    "face_lift": {"centre": [960, 330], "radius": [430, 330], "amount": 0.7},
}

# (clip, first-word start, last-word end, note, extras)
# `video` = split edit: sound from the take, picture from elsewhere.
# `cues`  = to-do markers for graphics / b-roll she still has to place, offset into the pick.
PICKS: list[tuple] = [
    # ---- Cold open -------------------------------------------------------------------------
    ("MVI_0043", 13.51, 15.51, "hook VO — yeast bubbling in action",
     {"video": {"source": f"{B}/Best Yeast Broll.MOV", "start": 4.0,
                "note": "starter glass, bubbles breaking at the surface"}}),
    ("MVI_0043", 19.60, 22.32, "hook VO — way too excited about yeast",
     {"video": {"source": f"{B}/Katie Dancing.MOV", "start": 56.8,
                "note": "Katie dancing, both arms up"}}),
    ("MVI_0040", 668.85, 673.97, "hook claim — you don't need sugar, you need time",
     {"push_to": 1.05}),
    ("MVI_0036", 35.29, 38.54, "name + promise (take 4)",
     {"cues": [{"at": 2.6, "text": "GFX: title card — 'Yeast' (§6.1, first graphic <30 s)"}]}),

    # ---- 1. Yeast is old -------------------------------------------------------------------
    ("MVI_0037", 19.09, 32.14, "yeast is really old — Egypt, Asia, Europe",
     {"chapter": "Yeast is old",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Yeast is old"},
               {"at": 5.0, "text": "GFX: timeline card — Egypt · Asia · Europe (vague on purpose)"}]}),
    ("MVI_0037", 33.00, 35.92, "it's around, it grows on grapes",
     {"cues": [{"at": 0.0, "text": "BROLL: wild yeast bloom on dark grapes (macro) — Storyblocks if needed"}]}),
    ("MVI_0038", 211.88, 236.57, "yeast in the air, on the grapes — not inoculated"),
    ("MVI_0037", 66.03, 86.16, "brewers → friends making doughs",
     {"cues": [{"at": 0.5, "text": "GFX: the exchange — brewer's jar passed to the baker (§6.4)"}]}),
    ("MVI_0037", 99.54, 108.60, "bakers get bubbly batches — passed back and forth"),
    ("MVI_0038", 254.60, 257.55, "selective breeding (the term)",
     {"cues": [{"at": 0.0, "text": "GFX: key term — Selective breeding (§6.3)"}]}),
    ("MVI_0037", 212.99, 219.55, "they may not know what they're breeding — dud batch"),
    ("MVI_0037", 224.90, 241.63, "successful batch passed on — genes selected",
     {"cues": [{"at": 0.0, "text": "GFX: dud batch ✗ pushed out, good batch ✓ passed on (§6.6)"}]}),

    # ---- 2. Pasteur ------------------------------------------------------------------------
    ("MVI_0038", 311.11, 337.12, "until Louis Pasteur — gooseneck, microbes",
     {"chapter": "Louis Pasteur",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Louis Pasteur"},
               {"at": 2.2, "text": "GFX: Pasteur portrait (Wikipedia, public domain) — see cuts/yeast001/wikipedia/",
                "picture": "cuts/yeast001/wikipedia/pasteur-portrait.jpg", "seconds": 7.0}]}),
    ("MVI_0041", 30.28, 39.04, "aside — glass bulb, stretches a neck",
     {"exact_start": 30.50,      # "which pots?" sits in the 30.18–30.50 before "If"
      "cues": [{"at": 4.0, "text": "GFX: swan-neck flask (Wellcome photo, CC BY 4.0) — to be redrawn as a cutout",
                "picture": "cuts/yeast001/wikipedia/pasteur-flask-wellcome.jpg", "seconds": 10.0}]}),
    ("MVI_0041", 41.20, 53.63, "open here, gooseneck shape — heats it to kill what's inside"),
    ("MVI_0041", 104.83, 114.33, "if spontaneous generation were true, the food breaks down"),
    ("MVI_0041", 115.25, 130.45, "germ theory — germs get stuck in the downspout",
     {"cues": [{"at": 9.0, "text": "GFX: flask — dust settling in the bend (rust mark)"}]}),
    ("MVI_0041", 134.92, 141.72, "nothing happens to the food — and that's what happens",
     {"exact_end": 139.75}),     # "happens." is timed 2.2 s: "And this is what Louis—" hides inside it
    ("MVI_0041", 146.91, 159.58, "Pasteur proves there is no spontaneous generation"),

    # ---- 3. One bug: Saccharomyces cerevisiae ---------------------------------------------
    ("MVI_0038", 413.48, 440.65, "we meet Saccharomyces cerevisiae",
     {"chapter": "One bug", "exact_start": 414.62,   # skips "and so we get Sac—"
      "cues": [{"at": 0.3, "text": "GFX: chapter card — One bug"},
               {"at": 1.0, "text": "GFX: name card — Saccharomyces cerevisiae (the recurring card)"}]}),
    ("MVI_0038", 441.63, 453.00, "a fungus, single cell, thrives in fertile environments",
     {"scale": 1.08,
      "cues": [{"at": 0.0, "text": "GFX: S. cerevisiae micrograph (Wikipedia, CC BY 3.0) — see cuts/yeast001/wikipedia/",
                "picture": "cuts/yeast001/wikipedia/yeast-sem.jpg", "seconds": 8.0}]}),
    ("MVI_0042", 1.49, 21.26, "aside — sourdough uses yeast too, plus lactic bacteria"),
    ("MVI_0042", 25.62, 48.77, "setting sourdough aside — S. cerevisiae is repeatable"),
    ("MVI_0038", 547.13, 580.36, "from a mother ferment to measured yeast on hand",
     {"exact_start": 548.95,     # "And with the—" false start, 547.1–547.8, then silence
      "cues": [{"at": 9.0, "text": "GFX: comparison — a mother ferment (jar) vs measured yeast (packet) (§6.6)"}]}),
    ("MVI_0038", 581.38, 585.28, "our way of baking and brewing changes"),
    ("MVI_0038", 595.69, 605.18, "because we can be intentional — measure the organism"),
    ("MVI_0038", 649.73, 665.56, "used all over — big brewers to at-home enthusiasts",
     {"video": {"source": f"{B}/MVI_0026.MOV", "start": 3.0, "duration": 6.0,
                "note": "insert — the jars of dry yeast, wide"},
      "cues": [{"at": 6.0, "text": "BROLL: a big bakery / brewery floor — Storyblocks, only if nothing real turns up"}]}),

    # ---- 4. The examples ------------------------------------------------------------------
    ("MVI_0045", 18.59, 29.45, "off camera I have examples of yeast you might find",
     {"chapter": "What's on the shelf", "exact_start": 22.30,   # "Right" timed 3 s hides "A couple of—"
      "cues": [{"at": 0.3, "text": "GFX: chapter card — What's on the shelf"}]}),
    ("MVI_0045", 35.19, 42.28, "active dry, pre-seeded with sugar — you don't need it",
     {"video": {"source": f"{B}/MVI_0027.MOV", "start": 6.0, "note": "insert — jar of dry yeast"}}),
    ("MVI_0045", 59.30, 61.10, "instant yeast right here",
     {"video": {"source": f"{B}/MVI_0028.MOV", "start": 1.5, "note": "insert — shallow jar, fine granules"}}),
    ("MVI_0045", 61.88, 72.19, "instant — smaller, wakes faster",
     {"exact_start": 62.72,      # "It's a little bit more…" false start before it
      "video": {"source": f"{B}/MVI_0028.MOV", "start": 3.4, "duration": 5.0, "note": "insert — shallow jar, continued"}}),
    ("MVI_0045", 72.89, 89.95, "fresh yeast — fragrant, straight into a dough, short shelf life",
     {"video": {"source": f"{B}/MVI_0031.MOV", "start": 1.0, "duration": 8.0, "note": "insert — fresh yeast cube in the glass"}}),
    ("MVI_0045", 107.88, 133.63, "eats through its food and goes dormant — dried yeast lasts"),
    ("MVI_0045", 134.21, 162.15, "mead yeast packet — it's just S. cerevisiae, all the same bug",
     {"video": {"source": f"{B}/MVI_0029.MOV", "start": 2.0, "duration": 10.0, "note": "insert — mead yeast packet with the jars"},
      "cues": [{"at": 19.0, "text": "GFX: name card returns — Saccharomyces cerevisiae"}]}),
    ("MVI_0045", 168.52, 187.48, "a different way to reach the brewer — same thing in the baking aisle"),
    ("MVI_0045", 187.58, 198.83, "someone with a marketing degree — it's all the same S. cerevisiae",
     {"push_to": 1.06}),

    # ---- 5. Access and need ---------------------------------------------------------------
    ("MVI_0040", 31.69, 35.79, "why so many names, so many formats?",
     {"chapter": "Access and need",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Access and need"}]}),
    ("MVI_0040", 45.37, 46.57, "the answer is access and need",
     {"cues": [{"at": 0.0, "text": "GFX: key term — Access and need"}]}),
    ("MVI_0040", 46.95, 80.47, "industrial bakers vs the farm in Kansas",
     {"cues": [{"at": 12.0, "text": "GFX: the two bakers — bakery / farmhouse an hour from a shop (§6.6)"}]}),
    ("MVI_0040", 89.83, 93.79, "fresh, dry — active dry and instant"),
    ("MVI_0040", 122.85, 132.95, "why doesn't the large baker use instant?"),
    ("MVI_0040", 136.19, 146.35, "processing damages the yeast — shows up in elasticity"),
    ("MVI_0040", 148.15, 157.31, "of the gluten — shears it, dries the bread faster"),
    ("MVI_0040", 172.46, 175.96, "glutathione (the term)",
     {"cues": [{"at": 0.0, "text": "GFX: key term — Glutathione (GSH) — ⚠︎ escalate mechanism"}]}),
    ("MVI_0040", 183.29, 202.32, "gets into the gluten network — shorter texture, sandwich bread",
     {"cues": [{"at": 0.5, "text": "GFX: gluten matrix — long strands, then strands cut short"}]}),
    ("MVI_0040", 208.32, 225.72, "fresh yeast is consistent — at home you might not notice",
     {"cues": [{"at": 1.0, "text": "BROLL: a cut loaf — stretchy crumb vs short crumb (shoot both; Storyblocks sandwich bread if needed)"}]}),
    ("MVI_0040", 248.88, 252.16, "it's about what's available"),
    ("MVI_0040", 254.60, 266.23, "not worth driving two hours for a day longer"),

    # ---- 6. How it reproduces -------------------------------------------------------------
    ("MVI_0040", 276.59, 283.72, "how does it reproduce?",
     {"chapter": "Budding",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Budding"}]}),
    ("MVI_0040", 328.33, 340.50, "mother cell buds a daughter — mitosis, two cells",
     {"cues": [{"at": 0.0, "text": "GFX: budding cycle — mother, bud, daughter, split (molecular kit, on 2s)"}]}),
    ("MVI_0040", 363.10, 385.51, "grows where there are nutrients — sugars and starches",
     {"scale": 1.08, "exact_start": 373.55}),   # 363–373 is a stumble WhisperX folded into "yeast"

    # ---- 7. What it eats ------------------------------------------------------------------
    ("MVI_0040", 387.56, 399.81, "amylases break starch into sugars",
     {"chapter": "What it eats",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — What it eats"},
               {"at": 2.0, "text": "GFX: pathway — starch → amylases → sugars (⚠︎ D-review before building)"}]}),
    ("MVI_0040", 409.13, 416.95, "sucrose with invertase"),
    ("MVI_0040", 444.38, 453.21, "simple sugars, zymase → CO₂ and alcohol",
     {"cues": [{"at": 4.0, "text": "GFX: pathway — zymase → CO₂ + ethanol"}]}),
    ("MVI_0040", 466.46, 480.31, "the byproducts we want — alcohol, or the rise we bake off",
     {"cues": [{"at": 8.0, "text": "BROLL: dough rising / oven spring — Storyblocks if needed"}]}),

    # ---- 8. Temperature -------------------------------------------------------------------
    ("MVI_0040", 492.31, 513.18, "the right environment — between 50 degrees dormant and 140 killed off",
     {"chapter": "Temperature",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Temperature"},
               {"at": 9.5, "text": "GFX: temperature gauge — 50 °F dormant · 93–102 °F sweet spot · 140 °F dead (⚠︎ E1)"}]}),
    ("MVI_0040", 518.16, 540.22, "the sweet spot — 93 to 100-and-a-couple — where we proof"),

    # ---- 9. What slows it down, and the sugar question ------------------------------------
    ("MVI_0040", 551.09, 569.75, "salt, fat, spices get in the way — slows proving",
     {"chapter": "Faster and slower",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Faster and slower"},
               {"at": 8.0, "text": "BROLL: fat, salt, spice going into a bowl (shoot) — or Storyblocks"}]}),
    ("MVI_0040", 583.19, 586.58, "sugar speeds it up"),
    ("MVI_0040", 625.22, 638.13, "active dry says add sugar — you don't have to, let it sit longer"),
    ("MVI_0040", 648.29, 663.12, "yeast just wants flour and water — the pre-ferment, bubbling",
     {"video": {"source": f"{B}/MVI_0023.MOV", "start": 14.0, "duration": 9.0,
                "note": "insert — the tall glass of pre-ferment, bubbling"}}),
    ("MVI_0040", 674.97, 678.68, "adding sugar speeds it up, but then — sweeter dough"),
    ("MVI_0040", 682.10, 689.29, "if that's not what you want, you don't need to add sugar",
     {"push_to": 1.05}),
    ("MVI_0040", 700.11, 715.70, "a pre-ferment is a version of a sourdough — easier to add later",
     {"video": {"source": f"{B}/MVI_0025.MOV", "start": 20.0, "duration": 7.0,
                "note": "insert — pre-ferment surface, bubbles close"}}),
    ("MVI_0040", 716.08, 719.95, "it also, as the yeast breaks down the flour,"),
    ("MVI_0040", 722.27, 726.91, "creates a more complex flavor"),

    # ---- Close ----------------------------------------------------------------------------
    ("MVI_0038", 709.93, 725.03, "close — the same little guy, factory cakes to store packets",
     {"chapter": "The same little bug", "push_to": 1.04,
      "cues": [{"at": 14.0, "text": "GFX: end card — one takeaway, one next action (⚠︎ C6: no next action recorded)"}]}),
]

MUSIC = [
    {"source": "assets/music/Audiio_AsTallAsPine_ATAP_TwinLakes.wav", "role": "bed",
     "at": 0.0, "until": 30.0, "fade_in": 1.5, "fade_out": 9.0, "under_db": 16.0,
     "note": "Twin Lakes under the cold open only; out by the end of the first chapter's first line"},
    {"source": "assets/music/Audiio_SK_Commercial_TwoBigReasons30.wav", "role": "outro",
     "fade_in": 2.0, "fade_out": 2.0, "under_db": 16.0,
     "note": "Two Big Reasons. Ends on the last frame — `at` is computed below"},
]


def words_of(clip: str) -> list[dict]:
    return json.loads((ROOT / "build/transcripts" / f"{clip}.words.json").read_text())["words"]


def padded(words: list[dict], start: float, end: float,
           exact_start: float | None = None,
           exact_end: float | None = None) -> tuple[float, float, str]:
    """
    Push the in/out points into the surrounding silence, and return the words kept.

    `exact_start` / `exact_end` are points measured off the audio (ffmpeg silencedetect), used as-is.
    It exists because WhisperX folds a false start into the token after it — "It's" timed at
    a full second is "It's a little bit more… It's" — so the word boundary is not where the
    clean take begins, and only the silence map knows where that is. [S-026]
    """
    # The rows above are typed to two decimals; the transcript carries three. Half a frame of
    # slack either way, so 668.85 still claims the word that starts at 668.848.
    inside = [w for w in words if w["start"] >= start - 0.02 and w["end"] <= end + 0.02]
    if exact_start is not None:
        inside = [w for w in words if w["end"] > exact_start and w["end"] <= end + 0.02]
    if exact_end is not None:
        inside = [w for w in inside if w["start"] < exact_end]
    if not inside:
        sys.exit(f"! no words between {start} and {end}")
    before = max((w["end"] for w in words if w["end"] <= inside[0]["start"]), default=0.0)
    after = min((w["start"] for w in words if w["start"] >= inside[-1]["end"]), default=1e9)
    gap_in, gap_out = inside[0]["start"] - before, after - inside[-1]["end"]
    # [S-029] — a boundary word timed far longer than its letters warrant is a false start
    # wearing that word's name; the cut point has to be measured off the audio, not read.
    for w, side, fixed in ((inside[0], "in", exact_start), (inside[-1], "out", exact_end)):
        length, letters = w["end"] - w["start"], max(1, len(w["word"].strip(".,?!…")))
        if fixed is None and (length > 0.45 and letters < 5 or length / letters > 0.2):
            print(f"  ? {side}-point on “{w['word']}” timed {length:.2f}s at {w['start']:.2f} — "
                  f"a lead, not a verdict [S-029]: the read-back decides; if it hears a stumble, "
                  f"measure with silencedetect and set exact_{'start' if side == 'in' else 'end'}")
    s = inside[0]["start"] - min(PAD_IN, max(gap_in - MIN_GAP, 0.0) / 2)
    if exact_start is not None:
        s = exact_start
    e = inside[-1]["end"] + min(PAD_OUT, max(gap_out - MIN_GAP, 0.0) / 2)
    if exact_end is not None:
        e = exact_end
    return C.snap_seconds(max(0.0, s)), C.snap_seconds(e), " ".join(w["word"] for w in inside)


def pauses(clip: str, s: float, e: float) -> list[tuple[float, float]]:
    """Interior silences ≥ PAUSE_TRIM_S inside [s, e], measured off the audio [S-024]."""
    r = subprocess.run(
        ["ffmpeg", "-v", "info", "-ss", f"{s:.3f}", "-t", f"{e - s:.3f}",
         "-i", str(ROOT / "build/transcripts/_audio" / f"{clip}.16k.wav"),
         "-af", f"silencedetect=n=-35dB:d={PAUSE_TRIM_S}", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    out = []
    for m in re.finditer(r"silence_end: ([\d.]+) \| silence_duration: ([\d.]+)", r):
        b, d = s + float(m.group(1)), float(m.group(2))
        a = b - d
        if a > s + 0.05 and b < e - 0.05:       # interior only; the pads own the ends
            out.append((a, b))
    return out


def split_at_pauses(pick: dict, clip: str) -> list[dict]:
    """
    One pick → several, with each long pause cut down to BREATH. Picture inserts carry across
    the split (the b-roll keeps running, which also hides the jump); cues go to whichever part
    holds their moment; a chapter stays on the first part. A push is never split — it would
    restart — so a pushed pick is left whole.
    """
    gaps = [] if pick.get("push_to") else pauses(clip, pick["start"], pick["end"])
    if not gaps:
        return [pick]
    parts, cur_start, origin = [], pick["start"], pick["start"]
    for a, b in gaps:
        parts.append((cur_start, C.snap_seconds(a + BREATH / 2)))
        cur_start = C.snap_seconds(b - BREATH / 2)
    parts.append((cur_start, pick["end"]))

    out, removed = [], 0.0
    for i, (ps, pe) in enumerate(parts):
        part = {k: v for k, v in pick.items() if k not in ("cues", "video", "chapter", "text")}
        part |= {"start": ps, "end": pe, "note": pick["note"] + ("" if i == 0 else f" ({i + 1})")}
        if i == 0:
            part["text"] = pick["text"]
            if pick.get("chapter"):
                part["chapter"] = pick["chapter"]
        # Where this part sits in the *original* pick's clock, so cues and the insert line up.
        local0 = ps - origin - removed
        if v := pick.get("video"):
            vdur = v.get("duration", pick["end"] - pick["start"])
            if local0 < vdur:
                part["video"] = {**v, "start": round(v["start"] + local0, 3),
                                 "duration": round(min(vdur - local0, pe - ps), 3)}
        part["cues"] = [{**c, "at": round(c["at"] - local0, 3)} for c in pick.get("cues", [])
                        if local0 <= c["at"] < local0 + (pe - ps)
                        or (i == 0 and c["at"] < 0)]
        if not part["cues"]:
            del part["cues"]
        out.append(part)
        if i < len(gaps):
            removed += (parts[i + 1][0] - pe)
    return out


def main() -> int:
    cache: dict[str, list[dict]] = {}
    picks, total, chapter_n = [], 0.0, 0
    gfx = "build/graphics/yeast001"
    for clip, start, end, note, *rest in PICKS:
        extras = json.loads(json.dumps(rest[0])) if rest else {}
        words = cache.setdefault(clip, words_of(clip))
        s, e, text = padded(words, start, end, extras.pop("exact_start", None),
                            extras.pop("exact_end", None))
        if extras.get("chapter"):
            chapter_n += 1
        # Cards and pictures are rendered by tools/cards.py into build/graphics; the cue
        # carries the path so the assembler can place what exists and mark what doesn't.
        for cue in extras.get("cues", []):
            if cue["text"].startswith("GFX: title card"):
                cue["layer"] = f"{gfx}/title_placeholder.mov"
            elif cue["text"].startswith("GFX: chapter card"):
                cue["layer"] = f"{gfx}/chapter-{chapter_n:02d}_placeholder.mov"
            elif cue.get("picture"):
                cue["layer"] = f"{gfx}/picture-{Path(cue['picture']).stem}.mov"
        pick = {"source": f"{A}/{clip}.MOV", "start": s, "end": e,
                "note": note, "text": text, **extras}
        picks += split_at_pauses(pick, clip)

    total = sum(x["end"] - x["start"] for x in picks)
    music = [dict(m) for m in MUSIC]
    outro_len = 32.143  # Two Big Reasons, measured; ends on the last frame
    music[1]["at"] = C.snap_seconds(max(0.0, total - outro_len))

    out = ROOT / "cuts/yeast001/picks.json"
    out.write_text(json.dumps({"project": "yeast001", "music": music, "grade": GRADE,
                               "picks": picks},
                              indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  ✓ {out.relative_to(ROOT)}  {len(picks)} picks, "
          f"{int(total // 60)}:{int(total % 60):02d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
