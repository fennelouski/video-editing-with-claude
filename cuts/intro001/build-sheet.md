# Intro 001 — build sheet

What has to exist before this cut can be finished. Ordered by what blocks what: everything in
§A stops the graphic pipeline from running at all, §B is the shot list, §C is what has to be
re-recorded, §D is what has to be checked by a person who knows chemistry, §E is technical.

Nothing here can be generated, substituted or approximated — [S-001]. A missing asset stops the
render and lands back on this page.

## Start here

The list is long and most of it can wait. In order:

1. **Shoot the inserts** (§B). The cut has almost nothing to look at, and this is the only item
   that fixes the biggest problem while blocking nothing else. One afternoon at the same table.
2. **Re-record the chemistry** (C1) and the four short pickups (C2–C6) in one sitting.
3. **Scan one blank sheet** (A1). Nothing in the graphic layer renders until it exists.

Everything else — the font, the LUT, the foley, the chapter cards — is real work but none of it
is on the critical path this week. There is a vertical cut of this same list as a video, if that
is easier to watch than read.

---

## A. Blocking — the pipeline will not run without these

Preflight fails on all of these today. None of them are specific to this video; they are the
channel's foundation, and every video after this one needs them too.

| | What | Where it goes | Spec |
|---|---|---|---|
| A1 | **Paper grain scan** | `assets/textures/paper-grain.png` | Flat-scan a blank sheet at 1200 dpi. Required by §4.3; the composite refuses to run without it and generated noise is not an option. |
| A2 | **Her marker font** | `assets/fonts/*.woff2` | ~1,320 hand-lettered glyphs per `font_character_set.md`. `kerning.json` is already checked in; the scans are not. |
| A3 | **Work Sans** | `assets/fonts/` | The body face, §3.1. Just needs downloading. |
| A4 | **The channel LUT** | `assets/luts/` | §7. |
| A5 | **Foley library** | `assets/foley/` | `tap_01.wav`, `slide_01.wav`, marker squeaks — real recordings of cardboard and paper. The placement code is written and tested against synthesised clicks; it works unchanged the moment real files land. |
| ~~A6~~ | ~~Music bed~~ | `assets/music/` | **Done** — *As Tall As Pine, "Twin Lakes"* and *SK Commercial, "Two Big Reasons"*. Both are in the cut; see §F. |

---

## B. Shot list — what this cut is asking for

The cut is **12:23 of one woman at one table**. §9 wants a pattern interrupt every 20–40 s and
the §12 rubric fails anything over 45 s without one. As it stands there are **zero**, so this
list is not decoration — it is most of the remaining work on the video.

Timecodes are positions in the rough cut.

### The ones the words directly promise

| TC | Shot | Notes |
|---|---|---|
| 0:00 | ~~Yeast bubbling~~ **— placed, wants a macro partner** | The starter-jar clip is now under the first line, sped 3.37× to fill it and deflickered. What it still wants is a **macro**: bubbles breaking at the surface, side-lit, shallow enough that the back of the jar goes soft. Two shots, not one — the wide establishes, the macro sells it. |
| 0:02 | ~~Katie waving~~ **— placed** | Lifted from between takes at 0:34 in MVI_0016, under "way too excited about yeast". Nothing further needed. |
| 0:05 | **Title card** | §9 wants the first graphic inside 30 s and there is none. It belongs under "my deep dive into yeast" — the last line of the cold open. |
| 2:39–3:03 | **Insert on each jar she picks up** | Mead yeast, instant dry, active dry with sugar, fresh yeast, the pre-ferment. Five clean close-ups of the labels — the wide shot cannot read them, and this 24-second run is the strongest sequence in the footage. Shoot on the same table, same light. |
| 3:09–3:27 | **Sourdough mother** | Being fed, being split, some of it handed over. Pairs with §4 and again with §11. |
| 6:14 | **Champagne / bubbly wine** | She names it as the payoff of the CO₂ point. |
| 6:20–6:36 | **Enriched dough vs lean dough** | §9's "show the failure before the fix": two doughs proofed side by side, same clock, one with fat and salt. This is the single most useful shot on the list. |
| 6:55 | **A pre-ferment being mixed** | Flour, water, yeast, nothing else — she says exactly that. |
| 7:14–7:31 | **Sugar vs no sugar rise** | Timelapse, two jars, same start. |
| 10:07–10:32 | **Stretchy vs short crumb** | Windowpane test on both, and a cut loaf of each. Again a failure-then-fix. |

### The ones the graphics have to carry

Cardboard and marker per `molecular_kit.md` and §1.1 — all built physically, photographed, matted.

| TC | Graphic | Notes |
|---|---|---|
| 0:13–0:55 | **Timeline card** — 1000 BC, Egypt, then Asia and Europe | Hand-drawn. Blocked on the date being confirmed, see D1. |
| 0:55–1:53 | **Baker ↔ brewer exchange** | Jar passing between two hands; a dud batch crossed out. Reuses the ✗ mark from the standing library. |
| 1:53–2:19 | **Pasteur's gooseneck flask** | The one prop that has to be drawn or built rather than shot. |
| 2:19 | **Name card** — Meyen, 1838, *Saccharomyces cerevisiae* | Blocked on D2. The species name is the channel's most repeated word; it wants a permanent card. |
| 3:43–4:02 | **Budding cycle** — mother, bud, daughter, mitosis | Cutout set, 4–6 variants, stepped on 2s. The layout solver handles the placement once the pieces exist. |
| 4:37–5:24 | **Temperature scale** — 54 °F, 100 °F, 140 °F | Thermometer cutout is already in the §1.1 kit list. Blocked on D3. |
| 5:24–6:20 | **The enzyme cascade** | Blocked twice over — on the re-shoot (C1) and on the chemistry review (D4). Do not build this until both clear. |
| 9:49–10:07 | **Glutathione / GSH** | Structure from the molecular kit, plus a label card introducing the abbreviation. She uses "GSH" in the cut without ever introducing it, because the take where she does is not usable — a label fixes it without a re-record. |
| 10:07 | **Gluten matrix, intact vs attacked** | Strands, and strands cut short. |
| 11:20 | **Sourdough goes west** | Map card. |

### Chapter cards

§9 wants one per chapter. The cut has twelve sections; they are listed with timecodes in
`script.md` and the section titles there are written to be usable as card text.

---

## C. Pickups — what has to be said again

| | What | Why |
|---|---|---|
| C1 | **The whole enzyme cascade, 5:24–6:20** | She says on tape, immediately before it, *"I think this is where I'm missing — my notes are not complete enough,"* and qualifies the invertase step with *"I believe."* As cut it also states that the amylases produce sucrose, which is not a step. Re-record against confirmed notes; do not patch this in the edit. |
| C2 | **"…and that is why we use yeast in our foods"** | She reaches the payoff of the whole chemistry section and trails off. Cut, so the section ends on champagne instead of on the point. One sentence. |
| C3 | **The alcohol contrast** | *"But the alcohol is left behind into… your alcohol."* The point — it bakes off in bread, it stays in beer and wine — never lands. One sentence, and it is the natural setup for the champagne shot. |
| C4 | **Sourdough going west** | The take with the westward-migration detail is too tangled to use; the clean restart survives but loses "they took it out west with them". Worth 20 seconds. |
| C5 | **A hook that names a mistake** | §9: a concrete claim about something home cooks get wrong, inside 15 s. What's there promises a subject. The obvious candidate is already in the video — that you do not need sugar to activate yeast, or that the water people proof in is too hot. |
| C6 | **An outro, under 20 s** | One takeaway, one next action. There isn't one; it ends on a thought. |
| C7 | *(optional)* **"one of the offsets" — sandwich bread** | A good line about shorter gluten strands, cut because it repeats the phrase directly before it. Re-say it once with different opening words and it goes back in. |

Shoot C1–C6 in one session, same setup, same shirt. Everything else in the video is already
covered from two angles' worth of material.

---

## D. Escalated to her — chemistry and claims

The pipeline gets no vote on any of these (`config.ESCALATE_TO_HUMAN`). Each one is a number,
a name or a mechanism that ends up on screen as a graphic, and a graphic makes a claim harder
to hedge than speech does.

| | Claim, as cut | Why it's flagged |
|---|---|---|
| D1 | "About 3,000 years ago, about 1,000 BC… Egypt, buried with the pharaohs" | Date and framing. Becomes a timeline card. |
| D2 | "Franz Julius Ferdinand **Mayen**, in 1838… he discovers *Saccharomyces cerevisiae*" | Spelling is **Meyen**, and the discovery is usually shared out between Cagniard-Latour, Schwann and Meyen around 1837–38, with Meyen supplying the genus name. She stops on tape to check it and still lands on "Mayen". Becomes a name card. |
| D3 | 54 °F / just over 100 °F / 140 °F | Three numbers, one graphic. |
| D4 | starch → α- and β-amylase → **sucrose** → invertase → glucose + fructose → zymase → CO₂ + ethanol | See C1. Amylases cut starch toward maltose; dough sucrose mostly comes from the flour or from what you added. |
| D5 | "It is like **90%** of all the yeast that we use is this one bug" | Ends up as on-screen type. §12 wants a source for any number. |
| D6 | Damaged dry yeast releases **glutathione**, which attacks the gluten matrix and makes bread dry out faster | Real mechanism, but the "starch has a harder time holding onto water" step needs checking, and it needs a source. |
| D7 | "It's in **meat**" (0:55) | Almost certainly "mead". Ear, then captions. |
| D8 | "from what the DNA test can **solve**" (0:27) | Reads as "can tell". |

---

## E. Technical

| | Issue | Fix |
|---|---|---|
| E1 | **MVI_0016 is 29.97 fps.** Everything else is 23.976. It is the only scripted material and it carries the whole cold open. | Final Cut will conform it, and the motion will not match its neighbours. Either re-shoot the four VO lines at 23.976 — they are 14 seconds — or accept the conform knowingly. [S-007]. The assembler now warns about this on every run. |
| E2 | **Level.** The four intro shots were **19.7 dB** under the body — −49.7 LUFS against −30.0 — and are now lifted by exactly that, as a fader on the clip rather than baked in. The programme still measures around −27 LUFS overall. | Expected: it's unprocessed, and the §8 dialogue chain lives in the finish. But her source runs quiet enough that stage 2 has to add ~30 dB before the compressor's threshold means anything, and that lifts the room with it. Get the mic closer, or the gain up, on the pickups. |
| E3 | **Room tone.** | 30 seconds of silence from each camera position. §12 check 16 fails a cut with no room tone under the joins, and this cut has 59 of them. |
| E4 | **Crosstalk.** Nathan is on the camera mic through MVI_0018 and MVI_0019. | The cut avoids all of it, but it cost some good answers. A lav on her for the pickups. |
| E7 | **One prepared media file.** `footage/broll/starter-jar-rise_prepped.mov` — 3.37× faster, flicker taken out of both brightness *and* colour, 1080p ProRes at 23.976. | The camera was hunting badly: worst frame-to-frame jump was 68 levels of luma and 22 of chroma, which at 3.4× speed reads as a strobe with a green flash in it. It is now 1.7 and 0.9. The original sits untouched beside it and the prep is one command — `./run tools/prep_clip.py` — so this is reproducible, not baked. If you would rather do it in the grade, delete the `video` block from pick 1 in `picks.json` and the original is right there. |
| E5 | **No chapter markers in the FCPXML yet.** | The writer supports them; the twelve chapter points are in `script.md`. Say the word and they go in — deliberately left out so the structure gets argued about in the timeline first. |
| E6 | **One read-back flag stands**, at 5:00. | Not a bad cut: it is one continuous take with no join in it, and the checker split a sentence at a breath. Left visible rather than silenced, because "checked and fine" and "could not tell" must not look the same. |
| E8 | **The read-back hears a phantom "As humans" at 0:13**, at the cut from the intro into the history. | It is not in the audio. Silence measured off the tape puts a clear gap either side of that join, and transcribing each of the two shots on its own returns both of them clean — the repeat only appears when the two are transcribed as one file. Whisper does this at hard cuts: having just decoded a phrase, it re-emits its opening across a discontinuity. Worth knowing, because the read-back is the check everything else defers to and this is the one way it lies. When it flags a repeat *at a join*, transcribe the two shots separately before believing it. |

---

## F. Music — placed, and what is still a decision

Both tracks are in the cut and in the FCPXML, on the **Music** role, lane −2, below the
storyline. They are *not* rendered into anything: each one is a real clip carrying an
`<adjust-volume>` you can drag, so the level is set but not spent. [S-006].

| | | |
|---|---|---|
| **Bed** | *As Tall As Pine — Twin Lakes* | 0:00 → 0:32, at **−26.7 dB**. Plays once. Fades out across 0:22–0:32. |
| **Outro** | *SK Commercial — Two Big Reasons* | 11:51 → 12:23, at **−23.9 dB**. Ends on the last frame. |

Both levels are **16 dB under the cut voice, measured 200 Hz–4 kHz** — three further under than the first pass — the §8 figure, in the
§8 band. The band is half the specification: matched full-band, a bass-heavy track sets its own
level from energy a phone never reproduces, which is how a bed once sat 7 dB below where the
number claimed ([S-022], [S-025]). Measured against *this* cut, not the tapes, because the cut
is 43% of the source and drops the loudest run-ups.

The bed now **plays once and leaves**. It runs under the cold open, holds through the first
minute of the history, and fades out over ten seconds ending at 0:32 — so the rest of the video
is her voice and nothing else, and the outro song arriving at 11:51 reads as an event rather
than as more of the same.

Those are the gains the filtergraph was given; the level is verified by measuring it back off
the finished mp4 — aligning and subtracting the voice-only render, which leaves the bed — rather
than by trusting the filtergraph that set it.

The outro is positioned so its own ending lands on the last frame of the video rather than being
faded out mid-phrase. It runs under her closing lines, which is what lifts them.

Still open, and all of them yours:

| | | |
|---|---|---|
| F1 | **Eleven minutes with no music at all.** | That is the deliberate consequence of playing it once. It suits a talk this dense, but it does mean the middle has nothing carrying it but her — worth deciding whether one more cue should come back under a chapter change. |
| F2 | **Where the fade lands is a judgement.** | It currently completes at 0:32, ten seconds into the Egypt passage. If it should hold longer, move `until` in `picks.json` and re-run; the fade length follows it. |
| F3 | **The level will need re-measuring after the dialogue chain.** | Her voice is raw in this preview — the §8 high-pass, 3:1 compression and limiting all land in the finish, and compression narrows exactly the range the bed was measured against. The *balance* is right; the absolute number will move. |
| F4 | **Licence.** | Both are Audiio tracks. Whatever attribution the licence asks for belongs in the description, and the licence IDs belong somewhere durable — this file is a good place. |

---

## How to rebuild any of this

```bash
./run tools/assemble.py cuts/intro001/picks.json --preview   # timeline, preview, read-back
./run tools/md_pdf.py cuts/intro001/build-sheet.md           # this page, as a PDF
```

`cuts/intro001/picks.json` is the edit — 60 in/out points with a note on each, and the two music
cues. Move a number, re-run, and it rebuilds the timeline, re-measures the bed against the new
voice, and re-transcribes the result to check the cut still says what it should. It is meant to
be edited by hand; it is the argument, not the output.
