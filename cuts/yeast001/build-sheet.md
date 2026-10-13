# Yeast 001 — build sheet

What has to exist before this cut can be finished, ordered by what blocks what. §A is the
channel's foundation and stops the graphic pipeline outright; §B is what is in the timeline
today as a stand-in; §C is the shot list; §D is pickups; §E is escalated to her; §F is technical.

Nothing here is generated or approximated by the pipeline — [S-001]. Where something *is* a
stand-in it says so in its filename.

## Start here

1. **Import the FCPXML and watch it** (`Yeast 001 — rough cut.fcpxml`, or the preview mp4 if
   Final Cut isn't to hand). The cut is the thing; everything below is in service of it.
2. **Decide the three escalations that gate graphics** (E1–E3): the temperature numbers, the
   enzyme chain, the glutathione mechanism. Three cards are blocked on them.
3. **Scan one blank sheet** (A1). Every card in the timeline is a placeholder until it exists.

---

## A. Blocking — the channel's foundation

Unchanged from the June 9 sheet except A3, which is done.

| | What | Where | Spec |
|---|---|---|---|
| A1 | **Paper grain scan** | `assets/textures/paper-grain.png` | Flat-scan a blank sheet at 1200 dpi (§4.3). Stage 5 refuses to run without it. |
| A2 | **Her marker font** | `assets/fonts/*.woff2` | Per `font_character_set.md`. Until then the cards use **Kalam** (OFL, in `assets/fonts/`) — relaxed, marker-ish, reads as a teacher's hand; swap is one constant in `tools/cards.py`. |
| ~~A3~~ | ~~Work Sans~~ | `assets/fonts/WorkSans[wght].ttf` | **Done.** OFL, variable weight. |
| A4 | **The channel LUT** | `assets/luts/yeast001-grade.cube` | **First version done** — see §G. A grade for this footage, not yet the channel's look; it will want revisiting against the T3i once that body is in rotation ([S-008]). |
| A5 | **Foley library** | `assets/foley/` | Cardboard taps, paper slides. The placement code is written. |
| A6 | **Cutouts** | `assets/cutouts/` | None exist yet. Every graphic in §B2 below is a cutout job. |

---

## B. What is in the timeline now

### B1. Placeholder cards — 11 of them

`build/graphics/yeast001/*_placeholder.mov`, on the Graphics.Cutouts lane, at the chapter
starts. Flat `bone` under Kalam, walnut ink, rust underline drawing on over 4 frames, placed on
the §5.3 curve with §5.2 jitter, held per §5.4. **The timing is final; the pixels are not.**
§6.1 wants a scanned surface and §10 fails a flat fill — they are named `_placeholder` so they
cannot be mistaken for the card. When A1 lands, `./run tools/cards.py cuts/yeast001/picks.json`
re-renders them onto it.

| TC | Card | TC | Card |
|---|---|---|---|
| 0:13 | *Yeast* (title, 120 px) | 7:25 | *Access and need* |
| 0:13 | *Yeast is old* | 9:30 | *Budding* |
| 1:45 | *Louis Pasteur* | 10:01 | *What it eats* |
| 3:09 | *One bug* | 10:43 | *Temperature* |
| 5:25 | *What's on the shelf* | 11:24 | *Faster and slower* |
| | | 12:48 | *The same little bug* |

### B2. Wikipedia pictures — 3 of them, real

`cuts/yeast001/wikipedia/` with `CREDITS.md` (source page, licence, artist for each). Placed
in the left column beside her, never over her face, on the same clock as the cards. These are
photographs, not generated — they don't violate [S-001] — but the flask one carries a black
background that §4.1 doesn't allow in a graphic. It's a reference until the flask is drawn.

| TC | Picture | Licence | Hold |
|---|---|---|---|
| 1:47 | Pasteur, by Nadar (1886) | Public domain | 7 s |
| 2:11 | Swan-neck flask, Wellcome Collection | CC BY 4.0 — **credit required on screen or in the description** | 10 s |
| 3:35 | *S. cerevisiae* SEM (Murtey & Ramasamy) | CC BY 3.0 — **credit required** | 8 s |

Also fetched, not placed: `yeast-dic.jpg` (budding cells under DIC, public domain) for the
Budding chapter if the cutout cycle isn't ready; `pasteur-flask-glass.jpg` (CC BY 4.0), an
alternate flask on a light background.

### B3. Inserts from the b-roll folder — 10 split edits

| TC | Clip | Under |
|---|---|---|
| 0:00 | `Best Yeast Broll` @ 4 s | "This is yeast bubbling in action" |
| 0:02 | `Katie Dancing` @ 57 s | "way too excited about yeast" |
| 5:52 | `MVI_0026` @ 3 s, 6 s | "from the big brewers … to the at-home enthusiasts" |
| 5:32 | `MVI_0027` @ 6 s | active dry |
| 5:39 | `MVI_0028` @ 1.5 s, then @ 3.4 s for 5 s | instant (two picks — a false start is cut between them) |
| 5:51 | `MVI_0031` @ 1 s, 8 s | fresh yeast |
| 6:30 | `MVI_0029` @ 2 s, 10 s | the mead packet |
| 11:58 | `MVI_0023` @ 14 s, 9 s | "this is what I have going right here" |
| 12:25 | `MVI_0025` @ 20 s, 7 s | the pre-ferment |

Unused from the folder: `MVI_0022`, `MVI_0030`, `starter-jar-rise` (the 4K 30p timelapse —
prepped 1080p version exists from the last cut; it was the first shot last time and could be
again if the starter glass reads as too busy).

### B4. Framing — 6 transforms, all editable

Two static punch-ins at 1.08× (the fungus line at 3:35, "grows where there are nutrients" at
9:50) where both neighbours run ≥ 10 s, so the cut between two takes of the same framing reads
as a second camera rather than a jump. A third, on "eats through its food", was dropped when
the pause-tightening left only 7 s of settled picture before it — the assembler refused it.
Four slow pushes — 1.05× under the hook claim (0:05), 1.06× under "it's really all just the
same" (7:14), 1.05× under "you do not actually need to add sugar" (12:17), 1.04× under the close
(12:48). Each is an `<adjust-transform>` on the clip: select the clip, Transform, drag.
`tools/assemble.py` refuses a static punch-in beside a pick shorter than 10 s.

---

## C. Shot list — still wanted

The cut has a pattern interrupt inside every 40 s window except 8:08–8:38 (§9). These are the
shots that would earn their keep, in order of how much they fix.

| TC | Shot | Why |
|---|---|---|
| 11:24–12:25 | **Sugar vs no sugar, two jars, one clock** | The failure-then-fix the whole last chapter is about. Locked-off timelapse, 3–4 h. |
| 9:00 | **A cut loaf — stretchy crumb vs short crumb** | "More of a shorter texture … in a sandwich bread." Windowpane both doughs, then cut both. |
| 0:27 | **Wild yeast bloom on a dark grape** | Macro. She names it; it is also beautiful. Storyblocks if it can't be shot. |
| 11:32 | **Fat, salt, spice into a bowl** | Close, three things in, that's it. |
| 10:37 | **Dough rising / oven spring** | "The gas that we will eventually bake off." A glass-door oven and a timelapse. |
| 4:37 | **Feeding a mother** | Pairs with the comparison card. Worth shooting once from three angles — it recurs. |
| 8:08–8:38 | **A supermarket baking aisle** | The one window with no interrupt. The actual small yeast shelf lands the point. |
| 5:25 | **The whole table of jars, wide, hands** | An establishing shot for the insert run. |

**Graphics to build** (cardboard, per `molecular_kit.md` and §1.1), in timeline order: timeline
card (0:18) · the exchange (0:52) · *Selective breeding* key term (1:19) · ✗/✓ batches (1:29) ·
the swan-neck flask, drawn (2:11) and the dust in its bend (2:47) · *Saccharomyces cerevisiae*
name card (3:10, 6:49, 12:48) · mother-vs-measured comparison (4:37) · *Access and need* key term
(7:30) · the two bakers (7:43) · *Glutathione* key term (8:38, **blocked E3**) · gluten matrix
(8:43) · budding cycle (9:37) · pathway (10:03, 10:25, **blocked E2**) · gauge (10:52, **blocked
E1**) · end card (13:02, **blocked D1**). All of these are to-do markers in the FCPXML at the
moment they belong.

---

## D. Pickups

| | What | Why |
|---|---|---|
| D1 | **The last line, and a next action — under 20 s together** | The take's button, *"It's the same little bug, Saccharomyces cerevisiae"*, is cut off by the camera: MVI_0038 stops at 12:07.81 (the 12-minute clip limit) with "cerevisiae" half said, so the cut ends on "…for at-home baking". Say the button once more, then the one thing you want them to do — §9 wants a next action and nothing on either tape has one. Same table, same cardigan. |
| D2 | **Meyen, in the right order** | The only take has "After Louis Pasteur, we get to 1838", and 1838 is before Pasteur. Suggested: *"Twenty years before Pasteur's flask, in 1838, Franz Meyen had already given it a name: Saccharomyces cerevisiae."* Confirm the date and the credit first (E4). |
| D3 | *(optional)* **"because of germ theory"** without the stumble | MVI_0041 1:55. Only if it bothers you; the stumble is honest. |

---

## E. Escalated to her

The pipeline gets no vote on these (`config.ESCALATE_TO_HUMAN`). Each ends up on screen as a
number or a diagram, and a graphic can't hedge the way speech can.

| | Claim, as cut | Why |
|---|---|---|
| E1 | **50 °F** dormant · **93 °F to 100-and-a-couple** sweet spot · **140 °F** killed | June 9 tape said 54 / "just over 100" / 140. Two shoots, two sets of numbers; the gauge carries one. |
| E2 | starch → α- and β-amylase → sugars; **sucrose → invertase**; simple sugars → **zymase** → CO₂ + alcohol | Better than last time (no "starch → sucrose"), but she restarts five times to get there and is reading. Sign the chain before the pathway is built. |
| E3 | Dried yeast releases **glutathione**, which weakens the gluten network and helps starch release water, so the crumb is shorter and dries faster | Real mechanism; the starch/water step and the "dries faster" claim want a source. |
| E4 | Meyen, 1838, naming *S. cerevisiae* | Spelling (she says "Mayen"), date, and whether the credit is his alone (Cagniard-Latour and Schwann are usually in the same sentence). For D2. |
| E5 | "Most sourdoughs are using *Saccharomyces cerevisiae*" | Stated as fact at 4:27. |
| E6 | "It's a single-cell organism … member of the fungi family" | Fine, but it's the line under the micrograph, so it is effectively a caption. |

---

## G. The grade — applied in the preview, one click in Final Cut

The footage is flat: average saturation ~8, her face at ~125 luma against windows at 235.
Two things fix it, and both are in the preview so the look can be judged now:

| | What | In the preview | In Final Cut |
|---|---|---|---|
| G1 | **The LUT** — midtone lift (0.5 → 0.545), highlights rolled to 0.965 so the windows never clip (§7), shadows and mids warmed (+0.03 R / −0.04 B), saturation ×1.35 | `lut3d` on every a-cam clip, before the graphics | Effects ▸ Color ▸ **Custom LUT** on each a-cam clip (or on a compound of the whole storyline), pointed at `assets/luts/yeast001-grade.cube` |
| G2 | **The face lift** — a soft-light ellipse over her head and shoulders, ≈ +8 % luminance, 140 px feather, centred (960, 330) | preview-only mask, `build/roughcut/yeast001.preview.face-lift.png` | Color Board ▸ Exposure, midtones +6–8, inside a **shape mask** over the same ellipse; keyframe the mask if she leans |

Measured on a table frame: face 138/126/119 → 162/143/127; kitchen 119/99/91 → 146/112/91.
Peak white 235 → 228. The b-roll inserts take the LUT too — they were shot in the same rooms.
The LUT is baked by `tools/lut.py` from the ffmpeg chain in `make_picks.py` (`GRADE`), so the
numbers live in one place. Not in the FCPXML: a LUT effect reference is a Motion template id
that can't be checked without Final Cut's own import, and a wrong one fails the whole file
([S-017]) — one click per clip beat that risk.

## F. Technical

| | Issue | Fix |
|---|---|---|
| F1 | **Room tone.** 69 joins, no tone under any of them. | 30 s of silence from each of the two setups. §12 check 16. |
| F2 | **Level.** The whole programme is her unprocessed camera audio. | Expected — the §8 chain lives in the finish. The beds are measured against the *cut* voice in the 200 Hz–4 kHz band and will need re-measuring once the chain is on. |
| F3 | **"between … 50 degrees" at 10:53** — a 1.6 s pause after "between" on tape. | Left whole rather than cut across the pause; the read-back hears the number. Listen once. |
| F4 | **Two setups, hard cuts between them.** Table ↔ kitchen at 2:07, 3:09, 3:46, 4:28, 6:08. | Motivated (the asides are asides) but §8 wants a J- or L-cut on every setup change. Drag the audio edits a few frames either way in Final Cut. |
| F5 | **Captions.** No `.itt` yet. | The read-back words are in `build/roughcut/yeast001.heard.txt`; captions come from Stage 5 once the plan exists. |
| F6 | **CC BY credits.** The flask and SEM pictures require attribution. | In the description at minimum; `wikipedia/CREDITS.md` has the exact lines. |
| F7 | **WhisperX folds false starts into the next word.** "It's" timed at 1.0 s, "yeast" at 9.6 s, "If" at 0.46 s — each one a stumble hidden inside a token, invisible in the transcript and audible in the cut. | Six cut points in this cut are set from `silencedetect` on the audio instead (`exact_start` in `make_picks.py`). The read-back is what found them, which is the whole argument of [S-026]. Worth a rule: any pick whose first word is timed longer than ~0.4 s gets its in-point measured, not read. |
