"""
make_picks.py — the Yeast 001 supercut: both shoots, shortest route through the argument.

Built on the June 16 structure with the punchier June 9 lines dropped in where they beat the
reshoot — the jar run ("guess what? Saccharomyces cerevisiae"), the list ("it's in mead, it's in
wine, it's in beer"), the close ("eat sugars and fart"). Every explanation is the shortest take
that still says the thing, except the gooseneck experiment, which is kept whole. Umms and
pauses are tightened off the audio by pickslib; sources are level-matched; pictures reframe
the footage instead of covering her.

    ./run cuts/yeast001-supercut/make_picks.py
    ./run tools/cards.py cuts/yeast001-supercut/picks.json
    ./run tools/assemble.py cuts/yeast001-supercut/picks.json --preview
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts/tools"))

import config as C          # noqa: E402
import pickslib as P        # noqa: E402

B = "footage/broll"
J9 = "Intro 001"            # the June 9 card — white top, braid; reads as a second day
WIKI = "cuts/yeast001/wikipedia"
GFX = "build/graphics/yeast001s"

PICKS: list[tuple] = [
    # ---- Cold open --------------------------------------------------------------------------
    ("MVI_0043", 13.51, 15.51, "hook VO — yeast bubbling in action",
     {"video": {"source": f"{B}/Best Yeast Broll.MOV", "start": 4.0,
                "note": "starter glass, bubbles breaking at the surface"}}),
    ("MVI_0043", 19.60, 22.32, "hook VO — way too excited about yeast",
     {"video": {"source": f"{B}/Katie Dancing.MOV", "start": 56.8, "note": "Katie dancing"}}),
    ("MVI_0040", 668.85, 673.97, "hook claim — you don't need sugar, you need time",
     {"push_to": 1.05}),
    ("MVI_0036", 35.29, 38.54, "name + promise",
     {"cues": [{"at": 2.6, "text": "GFX: title card — 'Yeast'"}]}),

    # ---- 1. Yeast is old ----------------------------------------------------------------------
    ("MVI_0037", 19.09, 32.14, "yeast is really old — Egypt, Asia, Europe",
     {"chapter": "Yeast is old",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Yeast is old"},
               {"at": 5.0, "text": "GFX: timeline card — Egypt · Asia · Europe (vague on purpose)"}]}),
    (f"{J9}/MVI_0019", 123.00, 147.58, "J9 — passed between brewers and bakers; mead, wine, beer",
     {"cues": [{"at": 3.5, "text": "BROLL: wild yeast bloom on dark grapes (macro)"},
               {"at": 9.0, "text": "GFX: the exchange — jar passed baker ↔ brewer (§6.4)"}]}),
    ("MVI_0037", 212.99, 219.55, "they may not know what they're breeding — dud batch",
     {"cues": [{"at": 3.0, "text": "GFX: dud batch ✗ pushed out (§6.6)"}]}),
    (f"{J9}/MVI_0019", 170.59, 185.89, "J9 — selective breeding of good yeast, years and years",
     {"cues": [{"at": 1.2, "text": "GFX: key term — Selective breeding (§6.3)"}]}),

    # ---- 2. Pasteur — kept whole --------------------------------------------------------------
    ("MVI_0038", 311.11, 322.76, "until Louis Pasteur — what's being passed on",
     {"chapter": "Louis Pasteur",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Louis Pasteur"},
               {"at": 2.2, "text": "GFX: Pasteur portrait (Nadar, public domain) — footage reframes",
                "picture": f"{WIKI}/pasteur-portrait.jpg", "seconds": 7.0, "reframe": True}]}),
    ("MVI_0038", 327.20, 337.12, "has a gooseneck experiment — disproves spontaneous generation",
     {"exact_start": 327.15}),   # "He uses—" is folded into the "He" token before it [S-029]
    ("MVI_0041", 30.28, 39.04, "aside — glass bulb, stretches a neck",
     {"exact_start": 30.50,
      "cues": [{"at": 3.0, "text": "GFX: swan-neck flask (Wellcome, CC BY 4.0) — footage reframes; redraw as a cutout",
                "picture": f"{WIKI}/pasteur-flask-wellcome.jpg", "seconds": 12.0, "reframe": True}]}),
    ("MVI_0041", 41.20, 53.63, "open here, gooseneck shape — heats it to kill what's inside"),
    ("MVI_0041", 104.83, 114.33, "if spontaneous generation were true, the food breaks down"),
    ("MVI_0041", 115.25, 130.45, "germ theory — germs get stuck in the downspout",
     {"cues": [{"at": 9.0, "text": "GFX: flask — dust settling in the bend (rust mark)"}]}),
    ("MVI_0041", 134.92, 141.72, "nothing happens to the food — and that's what happens",
     {"exact_end": 139.75}),
    ("MVI_0041", 146.91, 159.58, "Pasteur proves there is no spontaneous generation"),

    # ---- 3. One bug ---------------------------------------------------------------------------
    ("MVI_0038", 413.48, 440.65, "we meet Saccharomyces cerevisiae",
     {"chapter": "One bug", "exact_start": 414.62,
      "cues": [{"at": 0.3, "text": "GFX: chapter card — One bug"},
               {"at": 1.0, "text": "GFX: name card — Saccharomyces cerevisiae (the recurring card)"},
               {"at": 6.0, "text": "GFX: S. cerevisiae micrograph (CC BY 3.0) — footage reframes",
                "picture": f"{WIKI}/yeast-sem.jpg", "seconds": 8.0, "reframe": True}]}),
    (f"{J9}/MVI_0019", 279.90, 285.36, "J9 — 90% of all the yeast we use is this one bug",
     {"cues": [{"at": 1.3, "text": "GFX: stat — 90 % (⚠︎ needs a source, §6.8)"}]}),
    (f"{J9}/MVI_0019", 358.17, 373.73, "J9 — everywhere, same guy, again and again",
     {"video": {"source": f"{B}/MVI_0026.MOV", "start": 3.0, "duration": 5.0,
                "note": "insert — the jars of dry yeast, wide"}}),

    # ---- 4. What's on the shelf — the June 9 run, cut on each item ----------------------------
    (f"{J9}/MVI_0019", 251.53, 256.49, "J9 — mead yeast: S. cerevisiae",
     {"chapter": "What's on the shelf",
      "video": {"source": f"{B}/MVI_0029.MOV", "start": 2.0, "note": "insert — mead packet"},
      "cues": [{"at": 0.3, "text": "GFX: chapter card — What's on the shelf"}]}),
    (f"{J9}/MVI_0019", 256.51, 259.45, "J9 — instant dry: S. cerevisiae",
     {"video": {"source": f"{B}/MVI_0028.MOV", "start": 1.5, "note": "insert — fine granules"}}),
    (f"{J9}/MVI_0019", 259.47, 263.93, "J9 — active dry with sugar — guess what",
     {"video": {"source": f"{B}/MVI_0027.MOV", "start": 6.0, "note": "insert — jar of dry yeast"}}),
    (f"{J9}/MVI_0019", 264.05, 265.87, "J9 — fresh yeast: S. cerevisiae",
     {"video": {"source": f"{B}/MVI_0031.MOV", "start": 1.0, "note": "insert — fresh cube"}}),
    (f"{J9}/MVI_0019", 265.93, 274.69, "J9 — even a pre-ferment is S. cerevisiae, flour and water",
     {"video": {"source": f"{B}/MVI_0023.MOV", "start": 14.0, "duration": 5.0,
                "note": "insert — the tall glass, bubbling"},
      "cues": [{"at": 5.5, "text": "GFX: name card returns — Saccharomyces cerevisiae"}]}),
    ("MVI_0045", 187.58, 198.83, "someone with a marketing degree — it's all the same",
     {"push_to": 1.06}),

    # ---- 5. Access and need -------------------------------------------------------------------
    ("MVI_0040", 31.69, 35.79, "why so many names, so many formats?",
     {"chapter": "Access and need",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Access and need"}]}),
    ("MVI_0040", 45.37, 46.57, "the answer is access and need",
     {"cues": [{"at": 0.0, "text": "GFX: key term — Access and need"}]}),
    ("MVI_0040", 59.43, 80.47, "the farm in Kansas — needs something that won't die off",
     {"cues": [{"at": 1.0, "text": "GFX: the two bakers — bakery / farmhouse an hour from a shop (§6.6)"}]}),
    ("MVI_0040", 89.83, 93.79, "fresh, dry — active dry and instant"),
    ("MVI_0040", 136.19, 141.37, "in the processing, the yeast gets a little damaged"),
    ("MVI_0040", 153.95, 157.31, "it helps dry out the bread a little faster",
     {"cues": [{"at": 0.0, "text": "BROLL: a cut loaf — stretchy crumb vs short crumb"}]}),
    ("MVI_0040", 217.42, 225.72, "an at-home baker might not care — one loaf at a time"),
    ("MVI_0040", 257.90, 266.23, "not worth driving two hours for a day longer"),

    # ---- 6. Budding ---------------------------------------------------------------------------
    ("MVI_0040", 328.33, 340.50, "mother cell buds a daughter — mitosis, two cells",
     {"chapter": "Budding",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Budding"},
               {"at": 1.5, "text": "GFX: budding cycle — mother, bud, daughter, split (on 2s)"}]}),
    ("MVI_0040", 373.55, 385.51, "grows where there are nutrients — sugars and starches",
     {"exact_start": 373.55}),

    # ---- 7. What it eats — simplified to the one line that matters ----------------------------
    ("MVI_0040", 444.38, 453.21, "simple sugars, zymase → CO₂ and alcohol",
     {"chapter": "What it eats",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — What it eats"},
               {"at": 3.5, "text": "GFX: pathway — sugar → zymase → CO₂ + ethanol (⚠︎ E2)"}]}),
    ("MVI_0040", 466.46, 480.31, "the byproducts we want — alcohol, or the rise we bake off",
     {"cues": [{"at": 8.0, "text": "BROLL: dough rising / oven spring"}]}),
    (f"{J9}/MVI_0019", 713.27, 719.01, "J9 — that's where you get your bubbly wines, like champagne",
     {"cues": [{"at": 2.0, "text": "BROLL: champagne — Storyblocks"}]}),

    # ---- 8. Temperature -----------------------------------------------------------------------
    ("MVI_0040", 492.31, 504.36, "the right environment — a temperature between…",
     {"chapter": "Temperature", "exact_end": 504.40,
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Temperature"},
               {"at": 8.5, "text": "GFX: gauge — 50 °F · 93–102 °F · 140 °F (⚠︎ E1)"}]}),
    ("MVI_0040", 506.28, 513.18, "…50 degrees dormant and 140 killed off",
     {"exact_start": 505.12}),   # "fifty" is a 0.26 s blip in the pause the transcript mistimed
    ("MVI_0040", 518.16, 530.87, "the sweet spot — 93 to 100-and-a-couple — grow and thrive"),

    # ---- 9. Faster and slower -----------------------------------------------------------------
    ("MVI_0040", 551.09, 569.75, "salt, fat, spices get in the way — slows proving",
     {"chapter": "Faster and slower",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — Faster and slower"},
               {"at": 6.0, "text": "BROLL: fat, salt, spice into a bowl"}]}),
    ("MVI_0040", 583.19, 586.58, "sugar speeds it up"),
    ("MVI_0040", 625.22, 638.13, "active dry says add sugar — you don't have to, let it sit"),
    ("MVI_0040", 648.29, 663.12, "yeast just wants flour and water — the pre-ferment, bubbling",
     {"video": {"source": f"{B}/MVI_0025.MOV", "start": 20.0, "duration": 7.0,
                "note": "insert — pre-ferment surface, bubbles close"}}),
    ("MVI_0040", 674.97, 678.68, "adding sugar speeds it up, but — sweeter dough"),
    ("MVI_0040", 682.10, 689.29, "if that's not what you want, you don't need sugar",
     {"push_to": 1.05}),

    # ---- Close — June 9 -----------------------------------------------------------------------
    (f"{J9}/MVI_0021", 415.90, 417.50, "J9 — use what's available, it's all the same",
     {"chapter": "The same little bug",
      "cues": [{"at": 0.3, "text": "GFX: chapter card — The same little bug"}]}),
    (f"{J9}/MVI_0021", 486.48, 499.01, "J9 — not a hard and fast rule; the same little bug again and again"),
    (f"{J9}/MVI_0021", 500.89, 506.99, "J9 — all the little bug wants is to eat sugars and fart (⚠︎ channel voice)"),
    (f"{J9}/MVI_0021", 515.07, 520.69, "J9 — produce CO₂ and ethanol; a happy life; not that complicated",
     {"push_to": 1.04, "exact_start": 514.90,   # the first go at the line (513.0–514.7) is cut
      "cues": [{"at": 5.0, "text": "GFX: end card — one next action (⚠︎ D1: none recorded)"}]}),
]

MUSIC = [
    {"source": "assets/music/Audiio_AsTallAsPine_ATAP_TwinLakes.wav", "role": "bed",
     "at": 0.0, "until": 30.0, "fade_in": 1.5, "fade_out": 9.0, "under_db": 16.0,
     "note": "Twin Lakes under the cold open only"},
    {"source": "assets/music/Audiio_SK_Commercial_TwoBigReasons30.wav", "role": "outro",
     "fade_in": 2.0, "fade_out": 2.0, "under_db": 16.0,
     "note": "Two Big Reasons. Ends on the last frame"},
]

GRADE = {
    "lut": "assets/luts/yeast001-grade.cube",
    "face_lift": {"centre": [960, 330], "radius": [430, 330], "amount": 0.7},
}


def main() -> int:
    picks = P.build(PICKS, a_dir="footage/a-cam", gfx=GFX)
    gains = P.level_match(picks)
    for src, g in sorted(gains.items()):
        print(f"    {Path(src).name}: {g:+.1f} dB")
    total = sum(p["end"] - p["start"] for p in picks)
    music = [dict(m) for m in MUSIC]
    music[1]["at"] = C.snap_seconds(max(0.0, total - 32.143))
    P.write(ROOT / "cuts/yeast001-supercut/picks.json", "yeast001s", picks, music, grade=GRADE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
