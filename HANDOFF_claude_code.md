# Handoff — work to pass to Claude Code

Scoped, self-contained projects. Each one has a clear input, a clear output, and can be verified
without a human watching a video.

Read `taste_principles.md` and `style_guide.md` first — they are the spec, and several of these
tasks exist to enforce them.

---

## 1. Font builder — scan sheet → woff2 with contextual alternates ⭐  ✅ SHIPPED

> **Done**, except deskew. `scripts/tools/build_font.py` — grid segmentation via the shared
> `sheet.find_grid`, tracing through `trace.py` (Douglas–Peucker only, tolerance in font units,
> nothing smoothed), TTF/woff2 via `fontTools.fontBuilder`, and ordered `calt` cycling whose
> period is chosen so no alternate repeats across the wrap. Kerning is a checked-in data file.
> **No UFO** — a hand-edited source could not be regenerated from the scans, which would break
> determinism; see `font_character_set.md` "Build outputs".
> Acceptance test passes twice over: uharfbuzz shaping in `tests/test_build_font.py`, and a real
> Chrome render via `scripts/tools/verify_font_browser.py`, which is the only thing that can
> confirm `calt` is on **by default** (§3.2).
> **Still blocked:** deskew and registration-mark detection, pending her test sheet.

**The highest-value item on this list.** She is producing ~1,320 hand-lettered glyphs
(see `font_character_set.md`). Doing anything manual 1,320 times is not viable.

**Input:** scanned grid sheets at 1200 dpi, one glyph per sheet, versions in labelled cells.

**Output:** `assets/fonts/HerMarker.woff2` with `calt` wired up.

Pipeline to build:

1. **Segment** the grid — detect registration marks, split into per-cell images, deskew.
2. **Threshold and trace** to SVG. Do *not* smooth or simplify aggressively; the wobble and the
   marker skips are the entire value. Expose the tolerance as a tunable and default it low.
3. **Assemble** a UFO with `fontTools`/`fontmake`. Base glyph plus `.alt01`…`.alt19`.
4. **Generate the `calt` feature** — ordered cycling, not random. The rule set should guarantee a
   glyph never repeats within N positions. This is the part that determines whether the font
   reads as handwriting or as a font.
5. **Verify automatically:** render a test string with every letter tripled (`aaa bbb ccc…`) and
   assert no two adjacent glyphs share an outline hash. That test is the acceptance criterion.
6. Set `font-synthesis: none`, loose default sidebearings, kern only colliding pairs.

**Watch out for:** FontForge and fontmake disagree about `calt` ordering; verify in an actual
browser render, not just by inspecting the feature file.

---

## 2. Scan sheet segmenter (standalone)  ✅ SHIPPED

> **Done.** `scripts/tools/segment_sheet.py` on the shared `scripts/tools/sheet.py`.
> 1–2 px feather (0 px refused with the reason), fibre preserved by hysteresis thresholding,
> nothing deskewed or rescaled, `<key>_v<NN>_<variant>.png` naming, and pieces under the §1.2
> 2400 px floor skipped with a reshoot instruction and a non-zero exit.
> Two rules came out of building it: [S-012] the matte boundary is not the optical edge, so a
> thin ring of colour is corrected outward; [S-014] backdrop distance is measured along the
> backdrop ray and floored by a **measured** shadow depth, without which a dark near-neutral
> piece is read as deep shadow and disappears entirely.
> **Still blocked:** validation against a real capture, pending her cutout test sheet.

Same segmentation problem, but for **cutouts** rather than glyphs. She'll photograph multiple
cardboard pieces per sheet.

**Input:** one photo of several pieces on mid-grey seamless.
**Output:** individual matted PNGs named per the `assets/cutouts/<key>_v01_<a-f>.png` convention.

Requirements from `taste_principles.md` §1.3:
- Matte with a **1–2 px feather** — a 0 px matte gives a vector-crisp edge, the exact tell we're
  avoiding.
- **Preserve fibre.** If the matte eats the fuzz on a torn edge, the matte is wrong.
- Grey-card-driven white balance, applied consistently across a session.
- Reject and report pieces under 2400 px on the long edge.

---

## 3. FCPXML round-trip reader ⭐  ✅ SHIPPED

> **Done.** `scripts/roundtrip.py`. Detects restored cuts (highest priority), deleted, retimed
> and moved graphics, and reports a conformed timebase. Entries are grouped by defect and
> carry an unfilled rule line, so writing them gates stages 3–5 until a human writes the rule
> ([S-016]) — deliberate, since turning an observation into a testable rule is a judgement the
> pipeline is not entitled to make.
> Run with only the handoff for inspection mode, which reports the format Final Cut actually
> built.

**Closes the learning loop, and nothing else does.**

Right now `style_guide.md` only learns from Stage 6's automated frame checks. But the richest
signal is what the *editor* actually changed in Final Cut — which graphics got moved, retimed,
or deleted.

**Input:** an FCPXML exported back out of FCP after editing.
**Output:** a diff against the pipeline's original, written as `style_guide.md` entries.

Detect and report:
- Graphics deleted → the pipeline proposed something unwanted.
- Graphics retimed → the §5.4 hold formula is wrong for that cue type. **Report the delta**, so
  the constant can be tuned rather than guessed.
- Graphics moved → the anchoring in Stage 3 is landing early or late; report the direction.
- Cuts restored → Stage 2 removed something it shouldn't have. Highest-priority signal.

Reuse `scripts/fcpxml.py` for parsing; `TimelineMap` already handles source↔timeline mapping.

---

## 4. Molecule layout solver  ✅ SHIPPED

> **Done.** `scripts/molecule.py`. Correct bond angles per the geometry stated on each atom,
> rings closed as regular polygons, 8 px grid, safe box, §2.3 imperfection budget.
> **It computes geometry and never decides chemistry**: SMILES is refused rather than expanded,
> atom geometry is never inferred from bond count, and an unreviewed or placeholder-reviewed
> structure will not draw. Ring-forced angle deviations are reported *into the structure file*,
> so they are part of what she signs rather than a log line she never sees.

So she doesn't hand-place 24 atom cutouts for one glucose molecule.

**Input:** a structure spec (SMILES, or a simple JSON of atoms and bonds).
**Output:** 2D positions and rotations for each atom/bond cutout, on the 8 px grid, inside the
safe box, respecting the §2.3 imperfection budget.

Feed the result into `stage5_composite.render_cue()` as an explicit layout instead of the current
`layout_slots()` horizontal distribution.

**Constraints:** correct bond angles (109.5° tetrahedral, 120° trigonal) — this is a chemistry
video and wrong angles are a factual error. Rings must close. See `molecular_kit.md` for the
material coding, and note the palette has no blue or yellow, so atoms are coded by material and
mark, not hue.

---

## 5. Camera-matching helper

Per `style_guide.md` [S-008]: the T3i is a 2011 8-bit body and looks visibly greener and flatter
than the R100/RP. One LUT across all three will make cross-camera cuts read as a mistake.

**Input:** colour-checker frames from each body, same lighting.
**Output:** a per-body correction `.cube` that maps each camera to the RP as reference, to be
applied *before* the channel LUT.

Also useful: a checker that flags any clip whose body can't be identified from metadata.

---

## 6. Stage 6 face detection

`taste_principles.md` §12 check 3 — no text over faces — is currently a stub.

Add optional MediaPipe face detection to `stage6_watch.py`, failing when a text bounding box
intersects a detected face box. Must **degrade gracefully** when MediaPipe isn't installed;
the rest of the rubric can't be blocked on a large optional dependency.

---

## 7. Foley auto-placement  ✅ SHIPPED

> **Done.** `scripts/foley.py`. One hit per element placed, on the §8 `Effects.Foley` role,
> as connected audio on a **negative** lane — Final Cut stacks negative lanes below the
> storyline, so a positive lane would put the sound in the video stack.
> The hit lands at **contact**, derived from `stepclock.place_in` rather than hardcoded, so it
> follows the settle if that is ever retuned. Variation is seeded and structurally cannot
> repeat consecutively: the next index is chosen from the other files only.
> Building it found [S-018] — the settle overshoot §5.3 requires was never happening — and
> raised [S-019], where §5.3 constrains the settle's duration but not its amplitude.
> **The library does not exist yet.** Tested against synthesised clicks; drop real recordings
> into `assets/foley/` named `tap_01.wav`, `slide_01.wav` and it works unchanged.

Per §8, every graphic placement wants a real sound — cardboard tap, paper slide, marker squeak.

**Input:** the graphic plan + a recorded foley library.
**Output:** an FCPXML audio lane with a foley hit at each graphic's place-down frame, on the
`Effects.Foley` role, varied so the same tap never fires twice consecutively.

Ordinary-sounding, disproportionately effective. This is what makes graphics feel like objects.

---

## Not worth handing over

- **A web UI.** Two people use this and both are comfortable in a terminal.
- **A generative b-roll stage.** Non-negotiable, see [S-001].
- **A "smart" auto-styling system.** The whole point of `taste_principles.md` is that the
  decisions are already made. A system that re-decides them per video is the failure mode this
  project exists to prevent.
